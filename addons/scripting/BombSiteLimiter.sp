#include <sourcemod>
#include <colors>
#include <sdktools>


#undef REQUIRE_PLUGIN
#undef REQUIRE_EXTENSIONS
#tryinclude <updater>  // Comment out this line to remove updater support by force.
#define REQUIRE_PLUGIN
#define REQUIRE_EXTENSIONS

#define UPDATE_URL "https://raw.githubusercontent.com/eyal282/BombSiteLimiter/master/addons/updatefile.txt"

#define PLUGIN_VERSION "1.0"

#pragma newdecls required
#pragma semicolon 1

char PropModels[][] = 
{
	"models/props_wasteland/exterior_fence001b.mdl", 
	"models/props_c17/fence01a.mdl", 
	"models/props_c17/fence02a.mdl", 
	"models/props_c17/fence03a.mdl", 
	"models/props_c17/fence01b.mdl", 
	"models/props_c17/fence02b.mdl"
};

enum struct propData
{
	int iSerial;
	char sModel[256];
	float fOrigin[3];
	float fAngles[3];
	enSite site;
}

ArrayList g_aProps; // Prop entities  ( Ent references ) in the server
ArrayList g_aPropData; // Props that need to be spawned every round.

float g_fPrecision[MAXPLAYERS + 1];

Handle g_hDB;

Handle g_fwOnSitePicked;

enum enSite
{
	SITE_ANY = -1, 
	SITE_A = 0, 
	SITE_B = 1
}

char g_sMapName[64];

enSite CurrentSite = SITE_ANY;

public Plugin myinfo = 
{
	name = "Bomb Site Limiter based on AbNeR Map Restrictions", 
	author = "abnerfs, heavy edit by Eyal282", 
	description = "Limits bombsites based on player count, fully configurable.", 
	version = PLUGIN_VERSION, 
	url = "https://github.com/abnerfs/maprestrictions"
}

public void OnMapStart()
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	
	ConnectToDatabase();
}

public void Retakes_OnRoundStart(int bomber, int iSite)
{
	CurrentSite = view_as<enSite>(iSite);
	
	DeleteAllProps();
	
	CreateProps();
}

public APLRes AskPluginLoad2(Handle myself, bool bLate, char[] Error, int ErrorLen)
{
	CreateNative("BombSiteLimiter_SetPickedSite", Native_SetPickedSite);
}

public int Native_SetPickedSite(Handle plugin, int numParams)
{
	CurrentSite = GetNativeCell(1);
	
	DeleteAllProps();
	
	CreateProps();
}

public void OnPluginEnd()
{
	DeleteAllProps();
}
public void OnPluginStart()
{
	AutoExecConfig(true, "bomb_site_limiter");
	
	g_fwOnSitePicked = CreateGlobalForward("BombSiteLimiter_OnSitePicked", ET_Event, Param_CellByRef);
	g_aProps = new ArrayList();
	g_aPropData = new ArrayList(sizeof(propData));
	
	HookEvent("round_start", EventRoundStart);
	RegAdminCmd("refreshprops", CmdReloadProps, ADMFLAG_ROOT);
	RegAdminCmd("sm_sitelimiter", Command_SiteLimiter, ADMFLAG_ROOT);
	RegAdminCmd("sm_bombsitelimiter", Command_SiteLimiter, ADMFLAG_ROOT);
	RegAdminCmd("sm_bomblimiter", Command_SiteLimiter, ADMFLAG_ROOT);
	CreateConVar("bomb_site_limiter_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_REPLICATED);
	
	#if defined _updater_included
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
	#endif
}


public void OnLibraryAdded(const char[] name)
{
	#if defined _updater_included
	if (StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
	#endif
}

public void ConnectToDatabase()
{
	SQL_TConnect(SQLCB_Connected, "bombsite_limiter");
}


public void SQLCB_Connected(Handle db, Handle hndl, const char[] sError, int data)
{
	if (hndl == null)
		SetFailState("Could not connect to database bombsite_limiter in databases.cfg at following error:\n%s", sError);
	
	g_hDB = hndl;
	
	SQL_TQuery(g_hDB, SQLCB_Error, "CREATE TABLE IF NOT EXISTS SiteLimiter_Props (iSerial INT PRIMARY KEY AUTO_INCREMENT NOT NULL, sMapName VARCHAR(64) NOT NULL, sModel VARCHAR(256) NOT NULL, sOrigin VARCHAR(64) NOT NULL, sAngles VARCHAR(64) NOT NULL, iSite INT(3) NOT NULL)", DBPrio_High);
	
	ReloadProps();
}

public void SQLCB_Error(Handle db, Handle hndl, const char[] sError, int data)
{
	if (hndl == null)
		ThrowError(sError);
}

public Action CmdReloadProps(int client, int args) {
	ReloadProps();
}

public Action Command_SiteLimiter(int client, int args)
{
	Handle hMenu = CreateMenu(SiteLimiterMenu_Handler);
	
	
	char TempFormat[64];
	Format(TempFormat, sizeof(TempFormat), "Create Site A Blockade");
	AddMenuItem(hMenu, "", TempFormat);
	
	Format(TempFormat, sizeof(TempFormat), "Create Site B Blockade");
	AddMenuItem(hMenu, "", TempFormat);
	
	Format(TempFormat, sizeof(TempFormat), "Edit Aimed Blockade");
	AddMenuItem(hMenu, "", TempFormat);
	
	Format(TempFormat, sizeof(TempFormat), "Load Site A Blockades");
	AddMenuItem(hMenu, "", TempFormat);
	
	Format(TempFormat, sizeof(TempFormat), "Load Site B Blockades");
	AddMenuItem(hMenu, "", TempFormat);
	
	AddMenuItem(hMenu, "", "Fix Angles to 15 degrees");
	
	SetMenuTitle(hMenu, "Create blockades\n ATTENTION! This menu will interrupt the game!!!\n Creating a site blockade will create a blockade blocking the other site.");
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
	
	return Plugin_Handled;
}


public int SiteLimiterMenu_Handler(Handle hMenu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
		CloseHandle(hMenu);
	
	else if (action == MenuAction_Select)
	{
		switch (item)
		{
			case 0, 1:
			{
				SetupCreateBlockade(client, item == 0 ? SITE_A : SITE_B);
			}
			
			case 2:
			{
				Command_SiteLimiter(client, 0);
				
				int target = GetClientAimTarget(client, false);
				
				if (target == -1)
					PrintToChat(client, "You are not aiming at anything");
				
				else if (FindEntRefInArray(g_aProps, target) == -1)
					PrintToChat(client, "You are not aiming at a blockade");
				
				else
				{
					g_fPrecision[client] = 5.0;
					EditBlockade(client, target, 0);
				}
			}
			
			case 3, 4:
			{
				DeleteAllProps();
				CurrentSite = item == 3 ? SITE_A : SITE_B;
				
				CreateProps();
				
				Command_SiteLimiter(client, 0);
			}
			
			case 5:
			{
				float fAngles[3];
				
				GetClientEyeAngles(client, fAngles);
				
				GetRoundedAngles(fAngles);
				
				TeleportEntity(client, NULL_VECTOR, fAngles);
				
				Command_SiteLimiter(client, 0);
			}
		}
	}
}


void SetupCreateBlockade(int client, enSite site)
{
	float fOrigin[3], fAngles[3];
	
	GetEntPropVector(client, Prop_Data, "m_vecOrigin", fOrigin);
	GetClientEyeAngles(client, fAngles);
	
	Handle DP = CreateDataPack();
	
	WritePackFloat(DP, fOrigin[0]);
	WritePackFloat(DP, fOrigin[1]);
	WritePackFloat(DP, fOrigin[2]);
	
	WritePackFloat(DP, fAngles[0]);
	WritePackFloat(DP, fAngles[1]);
	WritePackFloat(DP, fAngles[2]);
	
	WritePackCell(DP, site);
	
	Handle hMenu = CreateMenu(SiteLimiterModelMenu_Handler);
	
	char szInfo[64];
	IntToString(view_as<int>(DP), szInfo, sizeof(szInfo));
	
	for (int i = 0; i < sizeof(PropModels); i++)
	{
		AddMenuItem(hMenu, szInfo, PropModels[i]);
	}
	
	SetMenuTitle(hMenu, "Create blockades\n Your position and look angles were saved.\n You should move before choosing a model.");
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}


public int SiteLimiterModelMenu_Handler(Handle hMenu, MenuAction action, int client, int item)
{
	char szInfo[64];
	
	if (action == MenuAction_End)
	{
		GetMenuItem(hMenu, 0, szInfo, sizeof(szInfo));
		
		Handle DP = view_as<Handle>(StringToInt(szInfo));
		
		CloseHandle(DP);
		
		CloseHandle(hMenu);
	}
	else if (action == MenuAction_Select)
	{
		char sModel[256];
		
		GetMenuItem(hMenu, item, szInfo, sizeof(szInfo), _, sModel, sizeof(sModel));
		
		Handle DP = view_as<Handle>(StringToInt(szInfo));
		
		WritePackString(DP, sModel);
		
		Handle DP2 = CloneHandle(DP); // Allows us to free the handle twice, once after CreateBlockade, once on MenuActionEnd
		
		CreateBlockade(client, DP2);
	}
}
void CreateBlockade(int client, Handle DP)
{
	float fOrigin[3], fAngles[3];
	char sQuery[256], sOrigin[64], sAngles[64], sModel[256];
	
	ResetPack(DP);
	
	fOrigin[0] = ReadPackFloat(DP);
	fOrigin[1] = ReadPackFloat(DP);
	fOrigin[2] = ReadPackFloat(DP);
	
	fAngles[0] = ReadPackFloat(DP);
	fAngles[1] = ReadPackFloat(DP);
	fAngles[2] = ReadPackFloat(DP);
	
	enSite site = ReadPackCell(DP);
	
	ReadPackString(DP, sModel, sizeof(sModel));
	
	CloseHandle(DP);
	
	FormatEx(sOrigin, sizeof(sOrigin), "%.4f %.4f %.4f", fOrigin[0], fOrigin[1], fOrigin[2]);
	FormatEx(sAngles, sizeof(sAngles), "%.4f %.4f %.4f", fAngles[0], fAngles[1], fAngles[2]);
	
	SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "INSERT INTO SiteLimiter_Props (sMapName, sModel, sOrigin, sAngles, iSite) VALUES ('%s', '%s', '%s', '%s', %i)", g_sMapName, sModel, sOrigin, sAngles, site);
	
	SQL_TQuery(g_hDB, SQLCB_BlockadeCreated, sQuery, GetClientUserId(client));
}

public void SQLCB_BlockadeCreated(Handle db, Handle hndl, const char[] sError, int iUserId)
{
	int client = GetClientOfUserId(iUserId);
	
	if (hndl == null)
		ThrowError(sError);
	
	else if (client != 0)
		PrintToChat(client, "Blockade created!");
	
	ReloadProps();
	
}




///



void EditBlockade(int client, int target, int menuPos)
{
	SetEntityRenderColor(target, 255, 0, 0);
	
	float fOrigin[3], fAngles[3];
	
	GetEntPropVector(target, Prop_Data, "m_vecOrigin", fOrigin);
	GetEntPropVector(target, Prop_Data, "m_angRotation", fAngles);
	
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, EntIndexToEntRef(target));
	
	Handle hMenu = CreateMenu(SiteLimiterEditMenu_Handler);
	
	char szFormat[256];
	char szInfo[64];
	IntToString(view_as<int>(DP), szInfo, sizeof(szInfo));
	
	AddMenuItem(hMenu, szInfo, "Delete Blockade");
	AddMenuItem(hMenu, szInfo, "Duplicate Blockade\n ");
	
	AddMenuItem(hMenu, szInfo, "Move Left");
	AddMenuItem(hMenu, szInfo, "Move Right");
	AddMenuItem(hMenu, szInfo, "Move Forward");
	AddMenuItem(hMenu, szInfo, "Move Backward");
	AddMenuItem(hMenu, szInfo, "Move Up");
	
	AddMenuItem(hMenu, szInfo, "Move Down\n ");
	
	FormatEx(szFormat, sizeof(szFormat), "Multiplier: %.0f units\n ", g_fPrecision[client]);
	AddMenuItem(hMenu, szInfo, szFormat);
	
	AddMenuItem(hMenu, szInfo, "Rotate 15 Degrees Left");
	AddMenuItem(hMenu, szInfo, "Rotate 15 Degrees Right\n ");
	
	AddMenuItem(hMenu, szInfo, "Save Changes");
	
	SetMenuTitle(hMenu, "Edit blockades\n Choose what to do with the target blockade:");
	DisplayMenuAtItem(hMenu, client, menuPos, MENU_TIME_FOREVER);
}


public int SiteLimiterEditMenu_Handler(Handle hMenu, MenuAction action, int client, int item)
{
	char szInfo[64];
	
	if (action == MenuAction_End)
	{
		GetMenuItem(hMenu, 0, szInfo, sizeof(szInfo));
		
		Handle DP = view_as<Handle>(StringToInt(szInfo));
		
		ResetPack(DP);
		
		int target = EntRefToEntIndex(ReadPackCell(DP));
		
		CloseHandle(DP);
		
		CloseHandle(hMenu);
		
		if (target != INVALID_ENT_REFERENCE)
			SetEntityRenderColor(target);
	}
	else if (action == MenuAction_Select)
	{
		GetMenuItem(hMenu, item, szInfo, sizeof(szInfo));
		
		Handle DP = view_as<Handle>(StringToInt(szInfo));
		
		char sQuery[256];
		
		ResetPack(DP);
		
		int target = EntRefToEntIndex(ReadPackCell(DP));
		
		if (target == INVALID_ENT_REFERENCE)
		{
			PrintToChat(client, "Blockade was not found!");
			return;
		}
		
		float fOrigin[3], fAngles[3];
		
		int iSerial;
		char iName[64];
		
		GetEntPropString(target, Prop_Data, "m_iName", iName, sizeof(iName));
		
		ReplaceStringEx(iName, sizeof(iName), "Serial: ", "");
		
		iSerial = StringToInt(iName);
		
		GetEntPropVector(target, Prop_Data, "m_vecOrigin", fOrigin);
		GetEntPropVector(target, Prop_Data, "m_angRotation", fAngles);
		
		int menuPos = GetMenuSelectionPosition();
		
		switch (item)
		{
			case 0:
			{
				SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "DELETE FROM SiteLimiter_Props WHERE iSerial = %i", iSerial);
				
				SQL_TQuery(g_hDB, SQLCB_BlockadeDeleted, sQuery, GetClientUserId(client));
				
				AcceptEntityInput(target, "Kill");
				
				Command_SiteLimiter(client, 0);
			}
			
			case 1:
			{
				char sModel[256], sOrigin[64], sAngles[64];
				
				GetEntPropString(target, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
				
				FormatEx(sOrigin, sizeof(sOrigin), "%.4f %.4f %.4f", fOrigin[0], fOrigin[1], fOrigin[2]);
				FormatEx(sAngles, sizeof(sAngles), "%.4f %.4f %.4f", fAngles[0], fAngles[1], fAngles[2]);
				
				SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "INSERT INTO SiteLimiter_Props (sMapName, sModel, sOrigin, sAngles, iSite) VALUES ('%s', '%s', '%s', '%s', %i)", g_sMapName, sModel, sOrigin, sAngles, CurrentSite);
				
				SQL_TQuery(g_hDB, SQLCB_BlockadeCreated, sQuery, GetClientUserId(client));
				
			}
			
			case 2:
			{
				fOrigin[0] += g_fPrecision[client];
				
				TeleportEntity(target, fOrigin);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 3:
			{
				fOrigin[0] -= g_fPrecision[client];
				
				TeleportEntity(target, fOrigin);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 4:
			{
				fOrigin[1] += g_fPrecision[client];
				
				TeleportEntity(target, fOrigin);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 5:
			{
				fOrigin[1] -= g_fPrecision[client];
				
				TeleportEntity(target, fOrigin);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 6:
			{
				fOrigin[2] += g_fPrecision[client];
				
				TeleportEntity(target, fOrigin);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 7:
			{
				fOrigin[2] -= g_fPrecision[client];
				
				TeleportEntity(target, fOrigin);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 8:
			{
				if(g_fPrecision[client] == 1.0)
					g_fPrecision[client] = 5.0;
					
				else if(g_fPrecision[client] >= 50.0)
					g_fPrecision[client] = 1.0;
					
				else
					g_fPrecision[client] += 5.0;
					
				EditBlockade(client, target, menuPos);
			}
			case 9:
			{
				fAngles[1] += 15.0;
				
				TeleportEntity(target, NULL_VECTOR, fAngles);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			case 10:
			{
				fAngles[1] -= 15.0;
				
				TeleportEntity(target, NULL_VECTOR, fAngles);
				
				CancelMenu(hMenu);
				EditBlockade(client, target, menuPos);
			}
			
			case 11:
			{
				char sOrigin[64], sAngles[64];
				
				FormatEx(sOrigin, sizeof(sOrigin), "%.4f %.4f %.4f", fOrigin[0], fOrigin[1], fOrigin[2]);
				FormatEx(sAngles, sizeof(sAngles), "%.4f %.4f %.4f", fAngles[0], fAngles[1], fAngles[2]);
				
				SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "UPDATE SiteLimiter_Props SET sOrigin = '%s', sAngles = '%s' WHERE iSerial = %i", sOrigin, sAngles, iSerial);
				
				SQL_TQuery(g_hDB, SQLCB_BlockadeEdited, sQuery, GetClientUserId(client));
				
				Command_SiteLimiter(client, 0);
				
				SetEntityRenderColor(target);
			}
		}
	}
}

public void SQLCB_BlockadeDeleted(Handle db, Handle hndl, const char[] sError, int iUserId)
{
	int client = GetClientOfUserId(iUserId);
	
	if (hndl == null)
		ThrowError(sError);
	
	else if (client != 0)
		PrintToChat(client, "Blockade deleted!");
	
	ReloadProps();
	
}

public void SQLCB_BlockadeEdited(Handle db, Handle hndl, const char[] sError, int iUserId)
{
	int client = GetClientOfUserId(iUserId);
	
	if (hndl == null)
		ThrowError(sError);
	
	else if (client != 0)
		PrintToChat(client, "Blockade edited!");
	
	ReloadProps();
	
}

/*
void CreateBlockade(int client, Handle DP)
{
	float fOrigin[3], fAngles[3];
	char sQuery[256], sOrigin[64], sAngles[64], sModel[256];
	
	ResetPack(DP);
	
	fOrigin[0] = ReadPackFloat(DP);
	fOrigin[1] = ReadPackFloat(DP);
	fOrigin[2] = ReadPackFloat(DP);
	
	fAngles[0] = ReadPackFloat(DP);
	fAngles[1] = ReadPackFloat(DP);
	fAngles[2] = ReadPackFloat(DP);
	
	enSite site = ReadPackCell(DP);
	
	ReadPackString(DP, sModel, sizeof(sModel));
	
	CloseHandle(DP);
	
	Format(sOrigin, sizeof(sOrigin), "%.4f %.4f %.4f", fOrigin[0], fOrigin[1], fOrigin[2]);
	Format(sAngles, sizeof(sAngles), "%.4f %.4f %.4f", fAngles[0], fAngles[1], fAngles[2]);
	
	SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "INSERT INTO SiteLimiter_Props (sMapName, sModel, sOrigin, sAngles, iSite) VALUES ('%s', '%s', '%s', '%s', %i)", g_sMapName, sModel, sOrigin, sAngles, site)
	
	SQL_TQuery(g_hDB, SQLCB_BlockadeCreated, sQuery, GetClientUserId(client));
}

public void SQLCB_BlockadeCreated(Handle db, Handle hndl, const char[] sError, int iUserId)
{
	int client = GetClientOfUserId(iUserId);
	
	if(hndl == null)
		ThrowError(sError);
	
	else if(client != 0)
		PrintToChat(client, "Blockade created!");
		
	ReloadProps();
	
}
*/
/*
void SetupDeleteChickenSpawnMenu(int client)
{
	char sQuery[256];
	SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "SELECT * FROM UsefulCommands_Chickens WHERE ChickenMap = '%s' ORDER BY ChickenCreateDate DESC", g_sMapName);
	SQL_TQuery(g_hDB, SQLCB_DeleteChickenSpawnMenu, sQuery, GetClientUserId(client));
}
public void SQLCB_DeleteChickenSpawnMenu(Handle db, Handle hndl, const char[] sError, int data)
{
	if(hndl == null)
		ThrowError(sError);
	
	int client = GetClientOfUserId(data);
	
	if(client == 0)
		return;
	
	else if(SQL_GetRowCount(hndl) == 0)
	{
		UC_PrintToChat(client, "%s%t", UCTag, "Command Chicken No Spawners");
		return;
	}
	
	Handle hMenu = CreateMenu(DeleteChickenSpawnMenu_Handler);
	
	while(SQL_FetchRow(hndl))
	{
		char sOrigin[50];
		SQL_FetchString(hndl, 0, sOrigin, sizeof(sOrigin));
		
		AddMenuItem(hMenu, "", sOrigin);
	}
	
	SetMenuTitle(hMenu, "%t", "Menu Chicken Delete Info");
	
	SetMenuExitBackButton(hMenu, true);
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}


public int DeleteChickenSpawnMenu_Handler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_DrawItem)
	{
		return ITEMDRAW_DEFAULT;
	}
	else if(action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		Command_Chicken(client, 0);
		return ITEMDRAW_DEFAULT;
	}
	if(action == MenuAction_End)
		CloseHandle(hMenu);
		
	else if(action == MenuAction_Select)
	{	
		char sOrigin[50], sIgnore[1];
		int iIgnore;
		
		GetMenuItem(hMenu, item, sIgnore, sizeof(sIgnore), iIgnore, sOrigin, sizeof(sOrigin));
		
		CreateConfirmDeleteMenu(client, sOrigin);
	}
	
	return ITEMDRAW_DEFAULT;
}

void CreateConfirmDeleteMenu(int client, char[] sOrigin)
{
	Handle hMenu = CreateMenu(ConfirmDeleteChickenSpawnMenu_Handler);
	
	char TempFormat[128];
	
	Format(TempFormat, sizeof(TempFormat), "%t", "Menu Yes");
	AddMenuItem(hMenu, sOrigin, TempFormat);

	Format(TempFormat, sizeof(TempFormat), "%t", "Menu No");
	AddMenuItem(hMenu, sOrigin, TempFormat);
	
	SetMenuTitle(hMenu, "%t", "Menu Chicken Delete Confirm", sOrigin);

	SetMenuExitBackButton(hMenu, true);
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
	
	if(UCEdit[client])
	{	
		float Origin[3];
		GetStringVector(sOrigin, Origin);
		TeleportEntity(client, Origin, NULL_VECTOR, NULL_VECTOR);
	}
}
public int ConfirmDeleteChickenSpawnMenu_Handler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_DrawItem)
	{
		return ITEMDRAW_DEFAULT;
	}
	else if(action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		SetupDeleteChickenSpawnMenu(client);
		return ITEMDRAW_DEFAULT;
	}
	if(action == MenuAction_End)
		CloseHandle(hMenu);
		
	else if(action == MenuAction_Select)
	{
		if(item == 0)
		{
			char sOrigin[50], sIgnore[1];
			int iIgnore;
			GetMenuItem(hMenu, item, sOrigin, sizeof(sOrigin), iIgnore, sIgnore, sizeof(sIgnore));
			
			char sQuery[256];
			SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM UsefulCommands_Chickens WHERE ChickenOrigin = '%s' AND ChickenMap = '%s'", sOrigin, MapName);
			SQL_TQuery(dbLocal, SQLCB_ChickenSpawnDeleted, sQuery, GetClientUserId(client));
		}
		else
			SetupDeleteChickenSpawnMenu(client);
	}
	
	return ITEMDRAW_DEFAULT;
}


public void SQLCB_ChickenSpawnDeleted(Handle db, Handle hndl, const char[] sError, int data)
{
	if(hndl == null)
		ThrowError(sError);
		
	int client = GetClientOfUserId(data);
	
	if(client != 0)
		UC_PrintToChat(client, "%s%t", UCTag, "Command Chicken Deleted");
		
	LoadChickenSpawns();
}

*/

public Action EventRoundStart(Handle ev, char[] name, bool db)
{
	
	CurrentSite = GetRandomInt(0, 1) == 1 ? SITE_A : SITE_B;
	
	Call_StartForward(g_fwOnSitePicked);
	
	Call_PushCellRef(CurrentSite);
	
	Action result;
	
	Call_Finish(result);
	
	if (result != Plugin_Continue && result != Plugin_Changed)
		return Plugin_Continue;
	
	if (CurrentSite != SITE_ANY)
		CreateProps();
	
	return Plugin_Continue;
}

void ReloadProps()
{
	char sQuery[256];
	SQL_FormatQuery(g_hDB, sQuery, sizeof(sQuery), "SELECT * FROM SiteLimiter_Props WHERE sMapName = '%s'", g_sMapName);
	SQL_TQuery(g_hDB, SQLCB_LoadProps, sQuery);
}
public void SQLCB_LoadProps(Handle db, Handle hndl, const char[] sError, int data)
{
	if (hndl == null)
		ThrowError(sError);
	
	g_aPropData.Clear();
	
	while (SQL_FetchRow(hndl))
	{
		char sOrigin[64], sAngles[64];
		
		propData prop;
		
		prop.iSerial = SQL_FetchInt(hndl, 0);
		SQL_FetchString(hndl, 2, prop.sModel, sizeof(propData::sModel));
		SQL_FetchString(hndl, 3, sOrigin, sizeof(sOrigin));
		SQL_FetchString(hndl, 4, sAngles, sizeof(sAngles));
		
		StringToVector(sOrigin, prop.fOrigin);
		StringToVector(sAngles, prop.fAngles);
		
		prop.site = view_as<enSite>(SQL_FetchInt(hndl, 5));
		
		g_aPropData.PushArray(prop);
		
		if (!PrecacheModel(prop.sModel))
			SetFailState("[AbNeR MapRestrictions] - Error precaching model '%s'", prop.sModel);
	}
	
	DeleteAllProps();
	
	CreateProps();
}


void DeleteAllProps() {
	
	for (int i = 0; i < g_aProps.Length; i++)
	{
		int Ent = EntRefToEntIndex(g_aProps.Get(i));
		
		if (Ent != INVALID_ENT_REFERENCE)
			AcceptEntityInput(Ent, "kill");
	}
	
	g_aProps.Clear();
}

void CreateProps()
{
	int iSize = g_aPropData.Length;
	
	char sModel[256];
	float fOrigin[3];
	float fAngles[3];
	enSite site;
	
	propData prop;
	
	for (int i = 0; i < iSize; i++)
	{
		g_aPropData.GetArray(i, prop);
		
		sModel = prop.sModel;
		fOrigin = prop.fOrigin;
		fAngles = prop.fAngles;
		site = prop.site;
		
		if (site != CurrentSite)
			continue;
		
		int Ent = CreateEntityByName("prop_physics_override");
		
		DispatchKeyValue(Ent, "physdamagescale", "0.0");
		DispatchKeyValue(Ent, "model", sModel);
		
		DispatchSpawn(Ent);
		SetEntityMoveType(Ent, MOVETYPE_NONE);
		
		char iName[64];
		FormatEx(iName, sizeof(iName), "Serial: %i", prop.iSerial);
		SetEntPropString(Ent, Prop_Data, "m_iName", iName);
		
		TeleportEntity(Ent, fOrigin, fAngles, NULL_VECTOR);
		
		g_aProps.Push(EntIndexToEntRef(Ent));
	}
}

stock void StringToVector(const char[] input, float buffer[3])
{
	char format[64];
	FormatEx(format, sizeof(format), input);
	
	ReplaceString(format, sizeof(format), ",", " ");
	
	ReplaceString(format, sizeof(format), "  ", " "); // This in total turns ", " into " "
	
	char xyz[3][11];
	ExplodeString(format, " ", xyz, sizeof(xyz), sizeof(xyz[]), false);
	
	buffer[0] = StringToFloat(xyz[0]);
	buffer[1] = StringToFloat(xyz[1]);
	buffer[2] = StringToFloat(xyz[2]);
}

stock void GetRoundedAngles(float fAngles[3], bool bIgnoreRoll = true)
{
	int size = 3;
	
	if (bIgnoreRoll)
		size = 2;
	
	for (int i = 0; i < size; i++)
	{
		if (FloatFraction(fAngles[i] / 15.0) > 0.5)
			fAngles[i] = fAngles[i] + ((1.0 - FloatFraction(fAngles[i] / 15.0)) * 15.0);
		
		else
			fAngles[i] = fAngles[i] - ((FloatFraction(fAngles[i] / 15.0)) * 15.0);
	}
}

stock int FindEntRefInArray(ArrayList Array, int entity)
{
	if (entity == -1)
		return -1;
	
	int size = Array.Length;
	
	int ent2;
	
	for (int i = 0; i < size; i++)
	{
		ent2 = EntRefToEntIndex(Array.Get(i));
		
		if (entity == ent2)
			return i;
	}
	
	return -1;
} 