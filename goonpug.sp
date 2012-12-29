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

#define GOONPUG_VERSION "0.0.1"

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
    MS_NOMINATE_CAPTAINS,
    MS_PICK_TEAMS,
    MS_PRE_LIVE,
    MS_LIVE,
    MS_POST_MATCH,
};

// Global convar handles
new Handle:g_cvar_maxPugPlayers;
new Handle:g_cvar_tvEnabled;

// Global menu handles
new Handle:g_pugMapList = INVALID_HANDLE;
new Handle:g_idleMapList = INVALID_HANDLE;

// Global match information
new MatchState:g_matchState = MS_WARMUP;
new String:g_matchMap[64] = "";
new Handle:g_matchInfoTimer = INVALID_HANDLE;

// Global team choosing info
new Handle:g_nominateTimer = INVALID_HANDLE;
// Player specific nominations
new g_playerNominations[MAXPLAYERS + 1][2];
// Nomination count for each player
new g_nominations[MAXPLAYERS + 1];
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

    // Load global convars
    g_cvar_tvEnabled = FindConVar("tv_enable");

    // Register commands
    RegConsoleCmd("sm_ready", Command_Ready, "Sets a client's status to ready.");
    RegConsoleCmd("sm_unready", Command_Unready, "Sets a client's status to not ready.");
    RegConsoleCmd("sm_captain", Command_Captain, "Nominates a player to be a captain.");
}

public OnMapStart()
{
    ReadMapLists();
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
    g_pugMapList = ReadMapList(INVALID_HANDLE, serial, "pug_match");
    if (g_pugMapList == INVALID_HANDLE)
        ThrowError("Could not read find pug_match maplist");

    g_idleMapList = ReadMapList(INVALID_HANDLE, serial, "pug_idle");
    if (g_idleMapList == INVALID_HANDLE)
        ThrowError("Could not find pug_idle maplist");
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

    if (NeedReadyUp())
    {
        ResetReadyUp();
    }
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
    ChangeCvar("mp_freezetime", "3");
    ChangeCvar("mp_buytime", "999");

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
    VoteMenuToAll(menu, 15);
}

/**
 * A timer that prints instructions for captain nominations
 */
public Action:Timer_NominateCaptains(Handle:timer)
{
    static count = 0;

    if (count == 0)
    {
        PrintToChatAll("[GP] Now accepting nominations for team captains.");
    }

    count++;
    if (count >= 6)
    {
        CloseHandle(g_nominateTimer);
        g_nominateTimer = INVALID_HANDLE;

        ChooseCaptains();
        return Plugin_Stop;
    }

    PrintToChatAll("[GP] %d seconds remaining to nominate captains.", 60 - (count * 10));
    PrintToChatAll("[GP] Use /captain [playername] to nominate a player.");
    PrintToChatAll("[GP] You may nominate up to 2 captains");

    return Plugin_Continue;
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
        decl String:clientName[64];
        GetClientName(i, clientName, sizeof(clientName));
        if (exact && StrEqual(clientName, name))
        {
            return i;
        }
        else
        {
            if (StrContains(clientName, name, false))
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

    return client;
}

/**
 * Nominates a captain
 */
public Action:Command_Captain(client, args)
{
    if (g_matchState != MS_NOMINATE_CAPTAINS)
    {
        PrintToChat(client, "[GP] You can't nominate captains right now.");
        return Plugin_Handled;
    }

    decl captain;
    decl String:captainName[64];

    if (GetCmdArgs() == 0)
    {
        captain = client;
        GetClientName(captain, captainName, sizeof(captainName));
    }
    else
    {
        GetCmdArg(1, captainName, sizeof(captainName));
        captain = FindClientByName(captainName);
        if (captain < 0)
        {
            PrintToChat(client, "[GP] No such player.");
            return Plugin_Handled;
        }
    }

    if (captain == g_captains[0] || captain == g_captains[1])
    {
        PrintToChat(client, "[GP] Player is already a captain.");
        return Plugin_Handled;
    }

    new nominateIndex = -1;
    for (new i = 0; i < MAX_NOMINATIONS; i++)
    {
        if (nominateIndex == -1 && g_playerNominations[client][i] == 0)
        {
            nominateIndex = i;
        }
        else if (g_playerNominations[client][i] == client)
        {
            PrintToChat(client, "[GP] You already nominated that player.");
            return Plugin_Handled;
        }
    }

    if (nominateIndex != -1)
    {
        g_playerNominations[client][nominateIndex] = captain;
        UpdateNominations(captain);
    }
    else
    {
        PrintToChat(client, "[GP] You have already nominated the maximum number of captains.");
    }

    return Plugin_Handled;
}

/**
 * Updates the nominated count for the specified player
 */
UpdateNominations(client)
{
    decl String:name[64];
    GetClientName(client, name, sizeof(name));

    g_nominations[client]++;

    PrintToChatAll("[GP] %s now has %d captain votes.", name, g_nominations[client]);
    new playerCount = GetConVarInt(g_cvar_maxPugPlayers);
    if (g_nominations[client] >= (playerCount / 2))
    {
        SelectCaptain(client);
    }
}

/**
 * Chooses captains based on nominations
 *
 * This will be run if 2 players don't receive the required
 * votes within 60 seconds.
 */
ChooseCaptains()
{
    for (;;)
    {
        new Handle:tiedPlayers = CreateArray();
        new maxVotes = 0;

        //Get a list of players tied for the max number of votes
        for (new i = 1; i <= MaxClients; i++)
        {
            if (g_captains[0] == i || g_captains[1] == i)
                continue;

            if (g_nominations[i] > maxVotes)
            {
                ClearArray(tiedPlayers);
                maxVotes = g_nominations[i];
                PushArrayCell(tiedPlayers, i);
            }
            else if (g_nominations[i] == maxVotes)
            {
                PushArrayCell(tiedPlayers, i);
            }
        }

        // Select a random player
        new captain = GetArrayCell(tiedPlayers,
                                   GetRandomInt(0, GetArraySize(tiedPlayers)));
        CloseHandle(tiedPlayers);
        if (SelectCaptain(captain) == Plugin_Handled)
            return;
    }
}

/**
 * Selects the specified player as a captain
 *
 * @retval Plugin_Continue if we should continue
 * @retval Plugin_Handled if all captains are selected
 */
Action:SelectCaptain(client)
{
    assert(g_captains[0] == 0 || g_captains[1] == 0)

    decl String:name[64];
    GetClientName(client, name, sizeof(name));

    PrintToChatAll("[GP] %s will be a captain.", name);

    if (g_captains[0] == 0)
    {
        g_captains[0] = client;
        return Plugin_Continue;
    }
    else
    {
        g_captains[1] = client;
        ChooseTeams();
        return Plugin_Handled;
    }
}

/**
 * Reset all captain nomination globals;
 */
ResetPlayerNominations()
{
    g_captains[0] = 0;
    g_captains[1] = 0;

    for (new i = 0; i <= MaxClients; i++)
    {
        g_nominations[i] = 0;

        for (new j = 0; j < MAX_NOMINATIONS; j++)
        {
            g_playerNominations[i][j] = 0;
        }
    }
}

/**
 * Selects teams via captains
 */
NominateCaptains()
{
    ChangeMatchState(MS_NOMINATE_CAPTAINS);
    ResetPlayerNominations();
    g_nominateTimer = CreateTimer(10.0, Timer_NominateCaptains, _, TIMER_REPEAT);
}

/**
 * Starts a timer to update a box with match information
 */


/**
 * Pick teams
 */
ChooseTeams()
{
    ChangeMatchState(MS_PICK_TEAMS);
    // Stop taking nominations
    if (g_nominateTimer != INVALID_HANDLE)
    {
        CloseHandle(g_nominateTimer);
        g_nominateTimer = INVALID_HANDLE;
    }

    ChooseFirstPick();
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
    PrintToChatAll("[GP] %s will pick first.");

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
        PrintToChatAll("[GP] Changing to match map in 10 seconds.");
        return Plugin_Stop;
    }
    else
    {
        decl String:captainName[64];
        GetClientName(g_captains[g_whosePick], captainName, sizeof(captainName));
        PrintToChatAll("[GP] %s's pick...");
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
 * Set up a the match
 */
StartMatchSetup()
{
    ChooseMatchMap();
    StartMatchInfoText();
    NominateCaptains();
}

StartMatchInfoText()
{
    g_matchInfoTimer = CreateTimer(1.0, Timer_MatchInfo, _, TIMER_REPEAT);
}

/**
 * Prints a continually updated hinttext box with info about an upcoming match
 */
public Action:Timer_MatchInfo(Handle:timer)
{
    switch (g_matchState)
    {
        case MS_NOMINATE_CAPTAINS:
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
    }

    return Plugin_Continue;
}

/**
 * Start the match
 */
StartLiveMatch()
{
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
            StartMatchSetup();
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
 * Check if all players are readied up
 *
 * @retval true if all are ready
 * @retval false if all are not ready
 */
CheckAllReady()
{
    new playerCount = 0;
    new bool:allReady = true;

    for (new i = 1; i < MaxClients; i++)
    {
        if (IsValidPlayer(i))
        {
            playerCount++;
            if (!g_playerReady[i])
            {
                allReady = false;
            }
        }
    }

    if (allReady)
    {
        // Make sure we have enough players
        new neededCount = GetConVarInt(g_cvar_maxPugPlayers);

        if (playerCount < neededCount)
        {
            allReady = false;
        }

        PrintToChatAll("[GP] Still waiting on %d players to join...",
                       neededCount - playerCount);
    }

    return allReady;
}

/**
 * Sets a player's ready up state to ready
 */
public Action:Command_Ready(client, args)
{
    if (!NeedReadyUp())
    {
        PrintToChat(client, "[GP] You don't need to ready up right now.");
        return Plugin_Handled;
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

        if (CheckAllReady())
        {
            OnAllReady();
        }
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
        return Plugin_Handled;
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

        // Call this check to print the waiting for count
        CheckAllReady();
    }

    return Plugin_Handled;
}
