/**
 * Goon competitive PUG plugin
 *
 * Author: astroman <peter@pmrowla.com>
 */

//#define DEBUG

#if defined DEBUG
    #define assert(%1) if (!(%1)) ThrowError("Debug Assertion Failed");
    #define assert_msg(%1, %2) if (!(%1)) ThrowError(%2);
#else
    #define assert(%1)
    #define assert_msg(%1, %2)
#endif

#pragma semicolon 1
#include <sourcemod>
#include <adt>
#include <cstrike>
#include <sdktools>
#include <sdktools_functions>

#define GOONPUG_VERSION "0.0.2"

#if defined MAXPLAYERS
#undef MAXPLAYERS
#endif

#define MAXPLAYERS 64

// Max captain nominations
#define MAX_NOMINATIONS 2

/**
 * Match states
 */
enum MatchState
{
    MS_WARMUP = 0,
    MS_MAP_VOTE,
    MS_CAPTAINS_VOTE,
    MS_PICK_TEAMS,
    MS_PRE_LIVE,
    MS_LO3,
    MS_LIVE,
    MS_POST_MATCH,
};

// Global convar handles
new Handle:g_cvar_maxPugPlayers = INVALID_HANDLE;
new Handle:g_cvar_tvEnabled = INVALID_HANDLE;

// Global menu handles
new Handle:g_pugMapList = INVALID_HANDLE;
new Handle:g_idleMapList = INVALID_HANDLE;

// Global match information
new MatchState:g_matchState = MS_WARMUP;
new String:g_matchMap[64] = "";

// Global team choosing info
new g_captains[2];
new g_whosePick = -1;
new g_ctCaptain;
new g_tCaptain;

// Team Management globals
new bool:g_lockTeams = false;
new g_playerTeam[MAXPLAYERS + 1];

// Player ready up states
new bool:g_playerReady[MAXPLAYERS + 1];

/**
 * Public plugin info
 */
public Plugin:myinfo = {
    name = "GoonPUG",
    author = "astroman <peter@pmrowla.com>",
    description = "CS:GO PUG Plugin",
    version = GOONPUG_VERSION,
    url = "http://github.com/pmrowla/goonpug",
}

/**
 * Initialize GoonPUG
 */
public OnPluginStart()
{
    // Set up GoonPUG convars
    CreateConVar("sm_gp_version", GOONPUG_VERSION, "GoonPUG Plugin Version",
                 FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_DONTRECORD);
    g_cvar_maxPugPlayers = CreateConVar("gp_max_pug_players", "10",
                                    "Maximum players allowed in a PUG",
                                    FCVAR_PLUGIN|FCVAR_REPLICATED|FCVAR_SPONLY|FCVAR_NOTIFY);
    g_cvar_tvEnabled = FindConVar("tv_enabled");

    AutoExecConfig(true, "goonpug");

    // Register commands
    RegConsoleCmd("sm_ready", Command_Ready, "Sets a client's status to ready.");
    RegConsoleCmd("sm_unready", Command_Unready, "Sets a client's status to not ready.");
    RegAdminCmd("sm_lo3", Command_Lo3, ADMFLAG_CHANGEMAP, "Starts a live match lo3");
    RegAdminCmd("sm_warmup", Command_Warmup, ADMFLAG_CHANGEMAP, "Starts a warmup");

    // Hook commands
    AddCommandListener(Command_Jointeam, "jointeam");

    // Hook events
    HookEvent("cs_intermission", Event_CsIntermission);
    HookEvent("cs_win_panel_match", Event_CsWinPanelMatch);
    HookEvent("player_death", Event_PlayerDeath);
}

bool:IsTvEnabled()
{
    if (g_cvar_tvEnabled == INVALID_HANDLE)
    {
        return false;
    }

    return GetConVarBool(g_cvar_tvEnabled);
}

public OnMapStart()
{
    ReadMapLists();
    switch (g_matchState)
    {
        case MS_WARMUP, MS_PRE_LIVE:
        {
            StartReadyUp();
        }
#if defined DEBUG
        case default:
        {
            ThrowError("OnMapStart: Invalid match state!");
        }
#endif
    }
}

public OnMapEnd()
{
    CloseMapLists();
}

/**
 * Read map lists that we need
 *
 * This should only be done once per map
 */
ReadMapLists()
{
    new serial = -1;
    g_pugMapList = ReadMapList(INVALID_HANDLE, serial, "goonpug_match");
    if (g_pugMapList == INVALID_HANDLE)
        ThrowError("Could not read find goonpug_match maplist");

    g_idleMapList = ReadMapList(INVALID_HANDLE, serial, "goonpug_idle");
    if (g_idleMapList == INVALID_HANDLE)
        ThrowError("Could not find goonpug_idle maplist");
}

/**
 * Close map lists
 */
CloseMapLists()
{
    if (g_pugMapList != INVALID_HANDLE)
    {
        CloseHandle(g_pugMapList);
        g_pugMapList = INVALID_HANDLE;
    }
    if (g_idleMapList != INVALID_HANDLE)
    {
        CloseHandle(g_idleMapList);
        g_idleMapList = INVALID_HANDLE;
    }
}

/**
 * Check if the specified client is a valid player
 */
bool:IsValidPlayer(client)
{
    if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
    {
        if (IsFakeClient(client))
        {
            // client is a bot
            decl String:name[64];
            GetClientName(client, name, sizeof(name));
            if (StrEqual(name, "GOTV"))
            {
                // All bots that aren't GOTV should count as players
                return false;
            }
        }
        return true;
    }
    return false;
}

/**
 * Change the match state
 */
ChangeMatchState(MatchState:newState)
{
    g_matchState = newState;
}

ChangeCvar(const String:name[], const String:value[])
{
    new Handle:cvar = FindConVar(name);
    SetConVarString(cvar, value);
}

/**
 * Reset ready up statuses
 */
ResetReadyUp()
{
    for (new i = 0; i <= MaxClients; i++)
    {
        g_playerReady[i] = false;
    }
}

/**
 * Check if the match is in a state where players need to ready up
 */
bool:NeedReadyUp()
{
    if (g_matchState == MS_WARMUP || g_matchState == MS_PRE_LIVE)
    {
        return true;
    }

    return false;
}

/**
 * Returns a menu for a map vote
 */
Handle:BuildMapVoteMenu()
{
    assert(mapList != INVALID_HANDLE)

    new Handle:menu = CreateMenu(Menu_MapVote);
    SetMenuTitle(menu, "Vote for the map to play");
    for (new i = 0; i < GetArraySize(g_pugMapList); i++)
    {
        decl String:mapname[64];
        GetArrayString(g_pugMapList, i, mapname, sizeof(mapname));
        if (IsMapValid(mapname))
        {
            AddMenuItem(menu, mapname, mapname);
        }
    }
    SetMenuExitButton(menu, false);

    return menu;
}

/**
 * Handler for a map vote menu
 */
public Menu_MapVote(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_End:
        {
            CloseHandle(menu);
            StartMatchInfoText();
            ChooseCaptains();
        }
        case MenuAction_VoteEnd:
        {
            new String:mapname[64];
            GetMenuItem(menu, param1, mapname, sizeof(mapname));
            SetMatchMap(mapname);
        }
        case MenuAction_VoteCancel:
        {
            new len = GetArraySize(g_pugMapList);
            decl String:mapname[64];
            GetArrayString(g_pugMapList, GetRandomInt(0, len - 1),
                           mapname, sizeof(mapname));
            PrintToChatAll("[GP] Vote cancelled, using random map.");
            SetMatchMap(mapname);
        }
    }
}

/**
 * Sets the global match map
 */
SetMatchMap(const String:mapname[])
{
    PrintToChatAll("[GP] Map will be: %s.", mapname);
    Format(g_matchMap, sizeof(g_matchMap), "%s", mapname);
}

/**
 * Selects a PUG map via player vote
 */
ChooseMatchMap()
{
    ChangeMatchState(MS_MAP_VOTE);
    new Handle:menu = BuildMapVoteMenu();
    if (IsVoteInProgress())
        CancelVote();
    VoteMenuToAll(menu, 30);
}

/**
 * Returns a client ID that matches the specified name.
 *
 * @param exact true if only exact matches are acceptable
 *
 * @retval -1 No matching client found
 * @retval -2 If more than one possible match was found
 */
FindClientByName(const String:name[], bool:exact=false)
{
    new client = -1;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i))
        {
            decl String:clientName[64];
            GetClientName(i, clientName, sizeof(clientName));
            if (exact && StrEqual(clientName, name))
            {
                return i;
            }
            else
            {
                if (StrContains(clientName, name, false) != -1)
                {
                    if (client != -1)
                    {
                        // Multiple matches
                        return -2;
                    }
                    client = i;
                }
            }
        }
    }

    return client;
}

/**
 * Returns a menu for a map vote
 */
Handle:BuildCaptainsVoteMenu()
{
    new Handle:menu = CreateMenu(Menu_CaptainsVote);
    SetMenuTitle(menu, "Vote for a team captain");
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i))
        {
            decl String:name[64];
            GetClientName(i, name, sizeof(name));
            AddMenuItem(menu, name, name);
        }
    }
    SetMenuExitButton(menu, false);
    SetVoteResultCallback(menu, VoteHandler_CaptainsVote);

    return menu;
}

/**
 * Handler for a map vote menu
 */
public Menu_CaptainsVote(Handle:menu, MenuAction:action, param1, param2)
{
    if (action == MenuAction_End)
    {
        CloseHandle(menu);
        ChooseFirstPick();
    }
}

/**
 * Handler for captain voting results
 *
 * TODO split this into multiple functions
 */
public VoteHandler_CaptainsVote(Handle:menu,
                               numVotes,
                               numClients,
                               const clientInfo[][2],
                               numItems,
                               const itemInfo[][2])
{
    new firstPlaceVotes = 0;
    new secondPlaceVotes = -1;
    new Handle:firstPlaceWinners = CreateArray();
    new Handle:secondPlaceWinners = INVALID_HANDLE;

    for (new i = 0; i < numItems; i++)
    {
        if (itemInfo[i][VOTEINFO_ITEM_VOTES] > firstPlaceVotes)
        {
            if (secondPlaceWinners != INVALID_HANDLE)
            {
                CloseHandle(secondPlaceWinners);
            }
            secondPlaceWinners = CloneArray(firstPlaceWinners);
            secondPlaceVotes = firstPlaceVotes;

            firstPlaceVotes = itemInfo[i][VOTEINFO_ITEM_VOTES];
            ClearArray(firstPlaceWinners);
            PushArrayCell(firstPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
        }
        else if (itemInfo[i][VOTEINFO_ITEM_VOTES] == firstPlaceVotes)
        {
            PushArrayCell(firstPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
        }
        else if (itemInfo[i][VOTEINFO_ITEM_VOTES] == secondPlaceVotes)
        {
            PushArrayCell(secondPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
        }
    }

    new firstPlaceTotal = GetArraySize(firstPlaceWinners);
    assert(firstPlaceTotal > 0)

    new captainIndex[2];

    captainIndex[0] = GetArrayCell(firstPlaceWinners, 0);

    if (firstPlaceTotal > 2)
    {
        new rand1 = GetRandomInt(0, firstPlaceTotal - 1);
        decl rand2;
        do
        {
            rand2 = GetRandomInt(0, firstPlaceTotal - 1);
        } while (rand2 == rand1);

        captainIndex[0] = GetArrayCell(firstPlaceWinners, rand1);
        captainIndex[1] = GetArrayCell(firstPlaceWinners, rand2);
    }
    else if (firstPlaceTotal == 2)
    {
        captainIndex[1] = GetArrayCell(firstPlaceWinners, 1);
    }
    else if (GetArraySize(secondPlaceWinners) > 0)
    {
        new rand = GetRandomInt(0, GetArraySize(secondPlaceWinners) - 1);
        captainIndex[1] = GetArrayCell(secondPlaceWinners, rand);
    }
    else
    {
        do {
            captainIndex[1] = GetRandomInt(1, MaxClients - 1);
        } while (!IsValidPlayer(captainIndex[1]) && (FindValueInArray(firstPlaceWinners, captainIndex[1]);
    }

    for (new i = 0; i < 2; i++)
    {
        decl String:name[64];
        GetMenuItem(menu, captainIndex[i], name, sizeof(name));
        g_captains[i] = FindClientByName(name, true);
        PrintToChatAll("[GP] %s will be a captain.", name);
    }

    CloseHandle(firstPlaceWinners);
    if (secondPlaceWinners != INVALID_HANDLE)
    {
        CloseHandle(secondPlaceWinners);
    }
}

/**
 * Selects teams via captains
 */
ChooseCaptains()
{
    ChangeMatchState(MS_CAPTAINS_VOTE);
    PrintToChatAll("[GP] Now voting for team captains.");
    PrintToChatAll("[GP] Top two vote getters will be selected.");
    new Handle:menu = BuildCaptainsVoteMenu();
    if (IsVoteInProgress())
        CancelVote();
    VoteMenuToAll(menu, 30);
}

/**
 * Determines which captain picks first.
 *
 * The other captain then chooses which side (s)he wants first.
 */
ChooseFirstPick()
{
    g_whosePick = GetRandomInt(0, 1);
    decl String:name[64];
    GetClientName(g_captains[g_whosePick], name, sizeof(name));
    PrintToChatAll("[GP] %s will pick first.", name);

    new Handle:menu = BuildSideMenu();
    DisplayMenu(menu, g_captains[g_whosePick ^ 1], 0);
}

/**
 * Builds a menu for picking sides
 */
Handle:BuildSideMenu()
{
    new Handle:menu = CreateMenu(Menu_Sides);
    SetMenuTitle(menu, "Which side do you want first?");
    AddMenuItem(menu, "CT", "CT");
    AddMenuItem(menu, "T", "T");
    SetMenuExitButton(menu, false);
    return menu;
}

/**
 * Menu handler for picking a side
 */
public Menu_Sides(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            decl String:info[8];
            GetMenuItem(menu, param2, info, sizeof(info));
            if (StrEqual(info, "CT"))
            {
                g_ctCaptain = param1;
            }
            else
            {
                g_tCaptain = param1;
            }
            decl String:name[64];
            GetClientName(param1, name, sizeof(name));
            PrintToChatAll("[GP] %s will take %s side first.", name, info);
            PickTeams();
        }
        case MenuAction_End:
        {
            CloseHandle(menu);
        }
    }
}

/**
 * Lock team status for all players
 */
LockAndClearTeams()
{
    g_lockTeams = true;

    // Reset player teams
    for (new i = 1; i <= MaxClients; i++)
    {
        g_playerTeam[i] = CS_TEAM_NONE;
    }
}

/**
 * Actual picking of teams
 */
PickTeams()
{
    ChangeMatchState(MS_PICK_TEAMS);
    LockAndClearTeams();
    ForceAllSpec();
    ForcePlayerTeam(g_ctCaptain, CS_TEAM_CT);
    ForcePlayerTeam(g_tCaptain, CS_TEAM_T);
    CreateTimer(1.0, Timer_PickTeams, _, TIMER_REPEAT);
}

/**
 * Runs until teams have been picked.
 */
public Action:Timer_PickTeams(Handle:timer)
{
    static Handle:pickMenu = INVALID_HANDLE;

    // If invalid we can start the next pick.
    if (pickMenu != INVALID_HANDLE)
        return Plugin_Continue;

    new neededCount = GetConVarInt(g_cvar_maxPugPlayers);

    if (GetTeamClientCount(CS_TEAM_CT) + GetTeamClientCount(CS_TEAM_T) == neededCount)
    {
        PrintToChatAll("[GP] Done picking teams.");

        decl String:curmap[64];
        GetCurrentMap(curmap, sizeof(curmap));
        if (!StrEqual(curmap, g_matchMap))
        {
            SetNextMap(g_matchMap);
            PrintToChatAll("[GP] Changing map to %s in 10 seconds...", g_matchMap);
            CreateTimer(10.0, Timer_MatchMap);
        }
        else
        {
            StartLiveMatch();
        }
        return Plugin_Stop;
    }
    else
    {
        decl String:captainName[64];
        GetClientName(g_captains[g_whosePick], captainName, sizeof(captainName));
        PrintToChatAll("[GP] %s's pick...", captainName);
        pickMenu = BuildPickMenu();
        DisplayMenu(pickMenu, g_captains[g_whosePick], 0);
    }
    return Plugin_Continue;
}

/**
 * Builds a menu with a list of pickable players
 */
Handle:BuildPickMenu()
{
    new Handle:menu = CreateMenu(Menu_PickPlayer);
    new Handle:pickable = CreateArray();
    decl i;

    for (i = 1; i <= MaxClients; i++)
    {
        if (GetClientTeam(i) == CS_TEAM_SPECTATOR && IsValidPlayer(i))
        {
            PushArrayCell(pickable, i);
        }
    }

    for (i = 0; i < GetArraySize(pickable); i++)
    {
        decl String:name[64];
        GetClientName(GetArrayCell(pickable, i), name, sizeof(name));
        AddMenuItem(menu, name, name);
    }

    SetMenuTitle(menu, "Choose a player:");
    SetMenuExitButton(menu, false);

    CloseHandle(pickable);
    return menu;
}

/**
 * Menu handler for picking a player
 */
public Menu_PickPlayer(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            assert(param1 == g_captains[g_whosePick])

            decl String:pickName[64];
            GetMenuItem(menu, param2, pickName, sizeof(pickName));
            new pick = FindClientByName(pickName, true);
            decl String:captainName[64];
            GetClientName(param1, captainName, sizeof(captainName));
            PrintToChatAll("[GP] %s picks %s.");
            ForcePlayerTeam(pick, GetClientTeam(param1));
            g_whosePick ^= 1;
        }
        case MenuAction_End:
        {
            CloseHandle(menu);
            menu = INVALID_HANDLE;
        }
    }
}

/**
 * Force a player to join the specified team
 */
ForcePlayerTeam(client, team)
{
    assert(g_lockTeams == true)

    g_playerTeam[client] = team;
    if (IsValidPlayer(client))
    {
        ChangeClientTeam(client, team);
    }
}

/**
 * Force all players into spectator team
 */
ForceAllSpec()
{
    for (new i = 1; i <= MaxClients; i++)
    {
        ForcePlayerTeam(i, CS_TEAM_SPECTATOR);
    }
}

/**
 * Starts a timer to update a box with match information
 */
StartMatchInfoText()
{
    CreateTimer(1.0, Timer_MatchInfo, _, TIMER_REPEAT);
}

/**
 * Prints a continually updated hinttext box with info about an upcoming match
 */
public Action:Timer_MatchInfo(Handle:timer)
{
    switch (g_matchState)
    {
        case MS_CAPTAINS_VOTE:
        {
            PrintHintTextToAll("Match Info:\nMap: %s",
                               g_matchMap);
        }
        case MS_PICK_TEAMS:
        {
            decl String:ctName[64];
            decl String:tName[64];
            GetClientName(g_ctCaptain, ctName, sizeof(ctName));
            GetClientName(g_tCaptain, tName, sizeof(tName));
            PrintHintTextToAll("Match Info:\nMap: %s\n%s (CT) vs %s (T)",
                               g_matchMap, ctName, tName);
        }
        default:
        {
            // State was changed somewhere else
            return Plugin_Stop;
        }
    }

    return Plugin_Continue;
}

StartServerDemo()
{
    if (IsTvEnabled())
    {
        ServerCommand("tv_stoprecord\n");
        new time = GetTime();
        decl String:timestamp[128];
        FormatTime(timestamp, sizeof(timestamp), NULL_STRING, time);
        decl String:map[64];
        GetCurrentMap(map, sizeof(map));
        ServerCommand("tv_record %s_%s\n", timestamp, map);
    }
}

StopServerDemo()
{
    if (IsTvEnabled())
    {
        ServerCommand("exec tv_stoprecord\n");
    }
}

/**
 * Start the match
 *
 * Does a lo3
 */
StartLiveMatch()
{
    StartServerDemo();
    ChangeMatchState(MS_LO3);
    ServerCommand("exec goonpug_match.cfg\n");
    PrintToChatAll("Live on 3...");
    ServerCommand("mp_restartgame 1\n");
    CreateTimer(3.0, Timer_Lo3First);
}

public Action:Timer_Lo3First(Handle:timer)
{
    PrintToChatAll("Live on 2...");
    ServerCommand("mp_restartgame 1\n");
    CreateTimer(3.0, Timer_Lo3Second);
}

public Action:Timer_Lo3Second(Handle:timer)
{
    PrintToChatAll("Live after next restart...");
    ServerCommand("mp_restartgame 5\n");
    CreateTimer(5.5, Timer_Lo3Third);
}

public Action:Timer_Lo3Third(Handle:timer)
{
    ChangeMatchState(MS_LIVE);
    PrintCenterTextAll("Match is live!");
}

/**
 * Call the appropriate match state function
 *
 * This function should be called when all PUG players have
 * readied up.
 */
OnAllReady()
{
    switch (g_matchState)
    {
        case MS_WARMUP:
        {
            ChooseMatchMap();
        }
        case MS_PRE_LIVE:
        {
            StartLiveMatch();
        }
#if defined DEBUG
        case default:
        {
            ThrowError("OnAllReady: Invalid match state!");
        }
#endif
    }
}

/**
 * Changes the map to the match map
 */
public Action:Timer_MatchMap(Handle:timer)
{
    ChangeMatchState(MS_PRE_LIVE);
    decl String:map[64];
    GetNextMap(map, sizeof(map));
    ForceChangeLevel(map, "Changing to match map");
}

/**
 * Starts a ready up stage
 *
 * TODO: kick a player if not ready after a certain amount of time
 */
StartReadyUp()
{
    StopServerDemo();
    ServerCommand("exec goonpug_warmup.cfg\n");
    ResetReadyUp();
    CreateTimer(1.0, Timer_ReadyUp, _, TIMER_REPEAT);
}

/**
 * Checks the ready up status periodically
 */
public Action:Timer_ReadyUp(Handle:timer)
{
    static count = 0;
    static neededCount = -1;

    // If the state was changed manually kill the ready up timer
    // This can happen if an admin forces a lo3
    if (!NeedReadyUp())
    {
        return Plugin_Stop;
    }

    count++;
    neededCount = CheckAllReady();
    if(neededCount == 0)
    {
        OnAllReady();
        return Plugin_Stop;
    }

    if ((count % 10) == 0)
    {
        for (new i = 1; i <= MaxClients; i++)
        {
            if (IsValidPlayer(i) && !g_playerReady[i])
            {
                PrintHintText(i, "Use /ready to ready up.");
            }
        }
    }
    if ((count % 30) == 0)
    {
        PrintToChatAll("[GP] Still need %d players to ready up...", neededCount);
    }

    return Plugin_Continue;
}

/**
 * Check if all players are readied up
 *
 * @return Number of players needed to ready up
 */
CheckAllReady()
{
    new playerCount = 0;

    for (new i = 1; i < MaxClients; i++)
    {
        if (IsValidPlayer(i) && g_playerReady[i])
        {
            playerCount++;
        }
    }

    new neededCount = GetConVarInt(g_cvar_maxPugPlayers);
    return (neededCount - playerCount);
}

/**
 * Post match stuff
 */
PostMatch()
{
    StopServerDemo();
    ChangeMatchState(MS_POST_MATCH);

    // Set the nextmap to a warmup map
    decl String:map[64];
    GetArrayString(g_idleMapList, GetRandomInt(0, GetArraySize(g_idleMapList) - 1), map, sizeof(map));
    SetNextMap(map);
    PrintToChatAll("[GP] Switching to idle phase in 20 seconds...");
    CreateTimer(20.0, Timer_IdleMap);
}

/**
 * Changes to the idle phase
 */
public Action:Timer_IdleMap(Handle:timer)
{
    decl String:map[64];
    GetNextMap(map, sizeof(map));
    ChangeMatchState(MS_WARMUP);
    ForceChangeLevel(map, "Changing to idle map");
}

/**
 * Forces the start of a warmup stage
 */
public Action:Command_Warmup(client, args)
{
    ChangeMatchState(MS_WARMUP);
    StartReadyUp();
    return Plugin_Handled;
}

/**
 * Executes a lo3 and starts a match
 */
public Action:Command_Lo3(client, args)
{
    StartLiveMatch();
    return Plugin_Handled;
}

/**
 * Sets a player's ready up state to ready
 */
public Action:Command_Ready(client, args)
{
    if (!NeedReadyUp())
    {
        PrintToChat(client, "[GP] You don't need to ready up right now.");
    }

    if (g_playerReady[client])
    {
        PrintToChat(client, "[GP] You are already ready.");
    }
    else
    {
        decl String:name[64];
        GetClientName(client, name, sizeof(name));
        g_playerReady[client] = true;
        PrintToChatAll("[GP] %s is now ready.", name);
    }

    return Plugin_Handled;
}

/**
 * Sets a player's ready up state to not ready
 */
public Action:Command_Unready(client, args)
{
    if (!NeedReadyUp())
    {
        PrintToChat(client, "[GP] You don't need to ready up right now.");
    }

    if (!g_playerReady[client])
    {
        PrintToChat(client, "[GP] You are already not ready.");
    }
    else
    {
        decl String:name[64];
        GetClientName(client, name, sizeof(name));
        g_playerReady[client] = false;
        PrintToChatAll("[GP] %s is no longer ready.", name);
    }

    return Plugin_Handled;
}

/**
 * Forces players to join a specific team if teams are locked
 */
public Action:Command_Jointeam(client, const String:command[], argc)
{
    if (!g_lockTeams || !IsValidPlayer(client))
        return Plugin_Continue;

    new String:param[16];
    GetCmdArg(1, param, sizeof(param));
    StripQuotes(param);
    new team = StringToInt(param);

    if (team == CS_TEAM_SPECTATOR)
    {
        return Plugin_Continue;
    }
    else
    {
        ChangeClientTeam(client, g_playerTeam[client]);
        return Plugin_Handled;
    }
}

/**
 * Updates our locked teams at halftime
 */
public Action:Event_CsIntermission(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (g_lockTeams)
    {
        for (new i = 1; i <= MAXPLAYERS; i++)
        {
            if (g_playerTeam[i] == CS_TEAM_CT)
            {
                g_playerTeam[i] = CS_TEAM_T;
            }
            else if (g_playerTeam[i] == CS_TEAM_T)
            {
                g_playerTeam[i] = CS_TEAM_CT;
            }
        }
    }

    return Plugin_Continue;
}

/**
 * Run at the conclusion of a match
 */
public Action:Event_CsWinPanelMatch(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (g_matchState == MS_LIVE)
    {
        PostMatch();
    }
    return Plugin_Continue;
}

/**
 * If we are in a ready up phase just respawn everyone constantly
 */
public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (NeedReadyUp())
    {
        new userid = GetEventInt(event, "userid");
        new client = GetClientOfUserId(userid);
        CreateTimer(2.5, Timer_RespawnPlayer, client);
    }
    return Plugin_Continue;
}

/**
 * Respawns the specified player
 */
public Action:Timer_RespawnPlayer(Handle:timer, any:client)
{
    if (IsValidPlayer(client) && !IsPlayerAlive(client))
    {
        CS_RespawnPlayer(client);
    }
}
