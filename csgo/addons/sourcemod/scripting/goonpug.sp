/* Copyright (c) 2013 Peter Rowlands
 *
 * This file is part of GoonPUG.
 *
 * GoonPUG is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundataion, either version 3 of the License, or
 * (at your option) any later version.
 *
 * GoonPUG is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with GoonPUG.  If not, see <http://www.gnu.org/licenses/>.
 */
 /**
 * CS:GO competitive PUG plugin
 *
 * Author: Peter "astroman" Rowlands <peter@pmrowla.com>
 */

//#define DEBUG 1

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

#define GOONPUG_VERSION "0.0.4"

#define STEAMID_LEN 32

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
new Handle:g_cvar_idleDeathmatch = INVALID_HANDLE;
new Handle:g_cvar_tvEnable = INVALID_HANDLE;

// Global menu handles
new Handle:g_pugMapList = INVALID_HANDLE;
new Handle:g_idleMapList = INVALID_HANDLE;

// Global match information
new MatchState:g_matchState = MS_WARMUP;
new String:g_matchMap[64] = "";

// Global team choosing info
new g_captains[2];
new g_whosePick = -1;
new g_ctCaptain = 0;
new g_tCaptain = 0;
new Handle:g_teamPickMenu = INVALID_HANDLE;

// Team Management globals
new bool:g_lockTeams = false;
new Handle:g_playerTeamTrie = INVALID_HANDLE;
new Handle:g_playerTeamKeys = INVALID_HANDLE;
new g_ctSlots = 0;
new g_tSlots = 0;

// Player ready up states
new bool:g_playerReady[MAXPLAYERS + 1];

// Grace timer handles
new Handle:g_graceTimerTrie = INVALID_HANDLE;

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
    CreateConVar("sm_goonpug_version", GOONPUG_VERSION, "GoonPUG Plugin Version",
                 FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_DONTRECORD);
    g_cvar_maxPugPlayers = CreateConVar("gp_max_pug_players", "10",
                                    "Maximum players allowed in a PUG",
                                    FCVAR_PLUGIN|FCVAR_REPLICATED|FCVAR_SPONLY|FCVAR_NOTIFY);
    g_cvar_idleDeathmatch = CreateConVar("gp_idle_dm", "0",
                                        "Use deathmatch respawning during warmup rounds",
                                        FCVAR_PLUGIN|FCVAR_REPLICATED|FCVAR_SPONLY|FCVAR_NOTIFY);
    g_cvar_tvEnable = FindConVar("tv_enable");

    new pugPlayers = GetConVarInt(g_cvar_maxPugPlayers);
    if ((pugPlayers % 2) != 0)
    {
        SetConVarInt(g_cvar_maxPugPlayers, pugPlayers + 1);
    }

    AutoExecConfig(true, "goonpug");

    HookConVarChange(g_cvar_maxPugPlayers, ConVarChange_MaxPugPlayers);

    // Register commands
    RegConsoleCmd("sm_ready", Command_Ready, "Sets a client's status to ready.");
    RegConsoleCmd("sm_unready", Command_Unready, "Sets a client's status to not ready.");
    RegConsoleCmd("sm_forfeit", Command_Forfeit, "Initializes a forfeit vote.");
    RegConsoleCmd("sm_restart", Command_Restart, "Start a vote to restart a match.");
    RegAdminCmd("sm_lo3", Command_Lo3, ADMFLAG_CHANGEMAP, "Starts a live match lo3");
    RegAdminCmd("sm_warmup", Command_Warmup, ADMFLAG_CHANGEMAP, "Starts a warmup");
    RegAdminCmd("sm_unlockteams", Command_UnlockTeams, ADMFLAG_CHANGEMAP, "Unlocks teams");
    RegAdminCmd("sm_lockteams", Command_LockTeams, ADMFLAG_CHANGEMAP, "Locks teams");
    RegAdminCmd("sm_kickunready", Command_KickUnready, ADMFLAG_KICK, "Kicks unready players");

    // Hook commands
    AddCommandListener(Command_Jointeam, "jointeam");
    AddCommandListener(Command_Say, "say");
    AddCommandListener(Command_Say, "say2");
    AddCommandListener(Command_Say, "say_team");

    // Hook events
    HookEvent("announce_phase_end", Event_AnnouncePhaseEnd);
    HookEvent("cs_win_panel_match", Event_CsWinPanelMatch);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_disconnect", Event_PlayerDisconnect);

    g_graceTimerTrie = CreateTrie();
    g_playerTeamTrie = CreateTrie();
    g_playerTeamKeys = CreateArray(STEAMID_LEN);
}

public OnPluginEnd()
{
    if (g_playerTeamTrie != INVALID_HANDLE)
    {
        ClearTrie(g_playerTeamTrie);
        CloseHandle(g_playerTeamTrie);
    }
    if (g_graceTimerTrie != INVALID_HANDLE)
    {
        ClearTrie(g_graceTimerTrie);
        CloseHandle(g_graceTimerTrie);
    }
}

public ConVarChange_MaxPugPlayers(Handle:cvar, const String:oldValue[], const String:newValue[])
{
    new val = StringToInt(newValue);
    if ((val % 2) != 0)
    {
        SetConVarInt(cvar, val);
    }
}

public OnClientAuthorized(client, const String:auth[])
{
    if (IsFakeClient(client))
    {
        return;
    }

    decl String:playerName[64];
    GetClientName(client, playerName, sizeof(playerName));
    PrintToChatAll("\x01\x0b\x04%s connected", playerName);

    decl Handle:timer;
    if (GetTrieValue(g_graceTimerTrie, auth, timer))
    {
        KillTimer(timer);
    }
}

bool:IsTvEnabled()
{
    if (g_cvar_tvEnable == INVALID_HANDLE)
    {
        return false;
    }

    return GetConVarBool(g_cvar_tvEnable);
}

public OnMapStart()
{
    ReadMapLists();
    switch (g_matchState)
    {
        case MS_WARMUP:
        {
            UnlockAndClearTeams();
            StartReadyUp();
        }
        case MS_PRE_LIVE:
        {
            StartReadyUp();
        }
#if defined DEBUG
        default:
        {
            ThrowError("OnMapStart: Invalid match state!");
        }
#endif
    }
}

public OnMapEnd()
{
    ClearTrie(g_graceTimerTrie);
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
    if (client > 0 && client <= MaxClients
        && IsClientConnected(client)
        && IsClientInGame(client))
    {
        if (IsFakeClient(client) && IsClientSourceTV(client))
        {
                return false;
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
    assert(g_pugMapList != INVALID_HANDLE)

    new Handle:menu = CreateMenu(Menu_MapVote);
    SetMenuTitle(menu, "Vote for the map to play");
    new Handle:maplist = CloneArray(g_pugMapList);
    for (new i = GetArraySize(g_pugMapList); i > 0; i--)
    {
        decl String:mapname[64];
        new index = GetRandomInt(0, i - 1);
        GetArrayString(maplist, index, mapname, sizeof(mapname));
        if (IsMapValid(mapname))
        {
            AddMenuItem(menu, mapname, mapname);
        }
        RemoveFromArray(maplist, index);
    }
    CloseHandle(maplist);
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
            if (param1 == MenuEnd_VotingCancelled && param2 != VoteCancel_NoVotes)
            {
                RestartWarmup();
            }
            else
            {
                StartMatchInfoText();
                ChooseCaptains();
            }
        }
        case MenuAction_VoteEnd:
        {
            decl winningVotes, totalVotes;
            decl String:mapname[64];
            GetMenuVoteInfo(param2, winningVotes, totalVotes);
            new Float:percentage = (winningVotes / totalVotes) * 100.0;
            GetMenuItem(menu, param1, mapname, sizeof(mapname));
            PrintToChatAll("[GP] %s won with %0.f%% of the vote.",
                mapname, percentage);
            SetMatchMap(mapname);
        }
        case MenuAction_VoteCancel:
        {
            if (param1 == VoteCancel_NoVotes)
            {
                new len = GetArraySize(g_pugMapList);
                decl String:mapname[64];
                GetArrayString(g_pugMapList, GetRandomInt(0, len - 1),
                               mapname, sizeof(mapname));
                PrintToChatAll("[GP] No votes received, using random map: %s.",
                               mapname);
                SetMatchMap(mapname);
            }
        }
    }
}

/**
 * Sets the global match map
 */
SetMatchMap(const String:mapname[])
{
    Format(g_matchMap, sizeof(g_matchMap), "%s", mapname);
}

/**
 * Selects a PUG map via player vote
 */
ChooseMatchMap()
{
    ChangeMatchState(MS_MAP_VOTE);
    new Handle:menu = BuildMapVoteMenu();
    new clientCount = 0;
    new clients[MAXPLAYERS + 1];

    for (new i = 1; i <= MaxClients; i++)
    {
        if (g_playerReady[i])
        {
            clients[clientCount] = i;
            clientCount++;
        }
    }

    if (IsVoteInProgress())
        CancelVote();
    VoteMenu(menu, clients, clientCount, 30);
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
        if (IsValidPlayer(i) && g_playerReady[i])
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
        if (param1 != MenuEnd_Cancelled)
        {
            ChooseFirstPick();
        }
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
    new Handle:firstPlaceWinners = CreateArray();

    for (new i = 0; i < numItems; i++)
    {
        if (itemInfo[i][VOTEINFO_ITEM_VOTES] > firstPlaceVotes)
        {
            firstPlaceVotes = itemInfo[i][VOTEINFO_ITEM_VOTES];
            ClearArray(firstPlaceWinners);
            PushArrayCell(firstPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
        }
        else if (itemInfo[i][VOTEINFO_ITEM_VOTES] == firstPlaceVotes)
        {
            // This item is in a tie with the current first place
            PushArrayCell(firstPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
        }
    }

    PrintToChatAll("[GP] Vote Results:");
    new firstPlaceTotal = GetArraySize(firstPlaceWinners);
    for (new i = 0; i < firstPlaceTotal; i++)
    {
        decl String:name[64];
        GetMenuItem(menu, GetArrayCell(firstPlaceWinners, i), name, sizeof(name));
        if (firstPlaceTotal == 1)
        {
            PrintToChatAll("[GP] 1st place: %s received %d votes.", name, firstPlaceVotes);
        }
        else
        {
            PrintToChatAll("[GP] 1st place (tie): %s received %d votes.", name, firstPlaceVotes);
        }
    }

    assert (firstPlaceTotal > 0)
    new captainIndex[2];
    if (firstPlaceTotal > 1)
    {
        // If there is a tie for first, pick 2 randomly
        new rand1 = GetRandomInt(0, firstPlaceTotal - 1);
        decl rand2;
        do
        {
            rand2 = GetRandomInt(0, firstPlaceTotal - 1);
        } while (rand2 == rand1);

        captainIndex[0] = GetArrayCell(firstPlaceWinners, rand1);
        captainIndex[1] = GetArrayCell(firstPlaceWinners, rand2);
    }
    else
    {
        captainIndex[0] = GetArrayCell(firstPlaceWinners, 0);

        new Handle:secondPlaceWinners = CreateArray();
        new secondPlaceVotes = 0;
        for (new i = 0; i < numItems; i++)
        {
            if (itemInfo[i][VOTEINFO_ITEM_VOTES] == firstPlaceVotes)
            {
                continue;
            }
            else if (itemInfo[i][VOTEINFO_ITEM_VOTES] > secondPlaceVotes)
            {
                secondPlaceVotes = itemInfo[i][VOTEINFO_ITEM_VOTES];
                ClearArray(secondPlaceWinners);
                PushArrayCell(secondPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
            }
            else if (itemInfo[i][VOTEINFO_ITEM_VOTES] == secondPlaceVotes)
            {
                // This item is in a tie with the current first place
                PushArrayCell(secondPlaceWinners, itemInfo[i][VOTEINFO_ITEM_INDEX]);
            }
        }

        new secondPlaceTotal = GetArraySize(secondPlaceWinners);
        for (new i = 0; i < secondPlaceTotal; i++)
        {
            decl String:name[64];
            GetMenuItem(menu, GetArrayCell(secondPlaceWinners, i), name, sizeof(name));
            if (secondPlaceTotal == 1)
            {
                PrintToChatAll("[GP] 2nd place: %s received %d votes.", name, secondPlaceVotes);
            }
            else
            {
                PrintToChatAll("[GP] 2nd place (tie): %s received %d votes.", name, secondPlaceVotes);
            }
        }

        captainIndex[1] = GetArrayCell(secondPlaceWinners, GetRandomInt(0, GetArraySize(secondPlaceWinners) - 1));
        CloseHandle(secondPlaceWinners);
    }

    CloseHandle(firstPlaceWinners);

    for (new i = 0; i < 2; i++)
    {
        decl String:name[64];
        GetMenuItem(menu, captainIndex[i], name, sizeof(name));
        g_captains[i] = FindClientByName(name, true);
        assert(g_captains[i] > 0)
        PrintToChatAll("[GP] %s will be a captain.", name);
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
    new clientCount = 0;
    new clients[MAXPLAYERS + 1];

    for (new i = 1; i <= MaxClients; i++)
    {
        if (g_playerReady[i])
        {
            clients[clientCount] = i;
            clientCount++;
        }
    }

    if (IsVoteInProgress())
        CancelVote();
    VoteMenu(menu, clients, clientCount, 30);
}

/**
 * Determines which captain picks first.
 *
 * The other captain then chooses which side (s)he wants first.
 */
ChooseFirstPick()
{
    assert(g_captains[0] > 0)
    assert(g_captains[1] > 0)

    if (g_matchState != MS_CAPTAINS_VOTE)
        return;

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
                if (g_captains[0] == g_ctCaptain)
                {
                    g_tCaptain = g_captains[1];
                }
                else
                {
                    g_tCaptain = g_captains[0];
                }
            }
            else
            {
                g_tCaptain = param1;
                if (g_captains[0] == g_tCaptain)
                {
                    g_ctCaptain = g_captains[1];
                }
                else
                {
                    g_ctCaptain = g_captains[0];
                }
            }
            decl String:name[64];
            GetClientName(param1, name, sizeof(name));
            PrintToChatAll("[GP] %s will take %s side first.", name, info);
        }
        case MenuAction_End:
        {
            CloseHandle(menu);
            if (param1 != MenuEnd_Cancelled)
            {
                PickTeams();
            }
        }
    }
}

ClearTeams()
{
    ClearTrie(g_playerTeamTrie);
    ClearArray(g_playerTeamKeys);
}

/**
 * Lock team status for all players
 */
LockAndClearTeams()
{
    g_lockTeams = true;
    ClearTeams();
    new slots = GetConVarInt(g_cvar_maxPugPlayers) / 2;
    g_ctSlots = slots;
    g_tSlots = slots;
}

/**
 * Lock current team status for all players
 */
LockCurrentTeams()
{
    g_lockTeams = true;
    g_ctSlots = 0;
    g_tSlots = 0;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            new team = GetClientTeam(i);
            decl String:steamId[STEAMID_LEN];
            GetClientAuthString(i, steamId, sizeof(steamId));
            if (team != CS_TEAM_T || team != CS_TEAM_CT)
            {
                team = CS_TEAM_SPECTATOR;
            }
            SetTrieValue(g_playerTeamTrie, steamId, team);
            if (FindStringInArray(g_playerTeamKeys, steamId) < 0)
            {
                PushArrayString(g_playerTeamKeys, steamId);
            }
        }
    }
}

/**
 * Unlock team status for all players
 */
UnlockAndClearTeams()
{
    g_lockTeams = false;
    ClearTeams();
}

/**
 * Actual picking of teams
 */
PickTeams()
{
    if (g_matchState != MS_CAPTAINS_VOTE)
        return;

    ChangeMatchState(MS_PICK_TEAMS);
    LockAndClearTeams();
    ForceAllSpec();
    ForcePlayerTeam(g_ctCaptain, CS_TEAM_CT);
    g_ctSlots--;
    ForcePlayerTeam(g_tCaptain, CS_TEAM_T);
    g_tSlots--;
    if (g_teamPickMenu != INVALID_HANDLE)
    {
        CloseHandle(g_teamPickMenu);
        g_teamPickMenu = INVALID_HANDLE;
    }
    CreateTimer(1.0, Timer_PickTeams, _, TIMER_REPEAT);
}

/**
 * Runs until teams have been picked.
 */
public Action:Timer_PickTeams(Handle:timer)
{
    // If state was reset abort
    if (g_matchState != MS_PICK_TEAMS)
        return Plugin_Stop;

    // If invalid we can start the next pick.
    if (g_teamPickMenu != INVALID_HANDLE)
        return Plugin_Continue;

    if (g_ctSlots == 0 && g_tSlots == 0)
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
        g_teamPickMenu = BuildPickMenu();
        DisplayMenu(g_teamPickMenu, g_captains[g_whosePick], 0);
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
        if (IsValidPlayer(i) && GetClientTeam(i) == CS_TEAM_SPECTATOR
            && g_playerReady[i])
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
            new team = GetClientTeam(param1);
            decl String:captainName[64];
            GetClientName(param1, captainName, sizeof(captainName));
            PrintToChatAll("[GP] %s picks %s.", captainName, pickName);
            ForcePlayerTeam(pick, team);
            if (team == CS_TEAM_CT)
            {
                g_ctSlots--;
            }
            else
            {
                g_tSlots--;
            }
            g_whosePick ^= 1;
        }
        case MenuAction_End:
        {
            CloseHandle(menu);
            g_teamPickMenu = INVALID_HANDLE;
        }
    }
}

/**
 * Force a player to join the specified team
 */
ForcePlayerTeam(client, team)
{
    if (IsValidPlayer(client))
    {
        decl String:steamId[STEAMID_LEN];
        GetClientAuthString(client, steamId, sizeof(steamId));

        if (team == CS_TEAM_NONE)
        {
            team = CS_TEAM_SPECTATOR;
        }

        new index = FindStringInArray(g_playerTeamKeys, steamId);
        if (index < 0)
        {
            PushArrayString(g_playerTeamKeys, steamId);
        }
        SetTrieValue(g_playerTeamTrie, steamId, team);

        ChangeClientTeam(client, team);
    }
}
/**
 * Force all players into spectator team
 */
ForceAllSpec()
{
    ClearTeams();
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i))
        {
            ForcePlayerTeam(i, CS_TEAM_SPECTATOR);
        }
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
 * Prints a continually updated center text box with info about an upcoming
 */
public Action:Timer_MatchInfo(Handle:timer)
{
    switch (g_matchState)
    {
        case MS_MAP_VOTE:
        {
            // Do nothing
        }
        case MS_CAPTAINS_VOTE:
        {
            PrintCenterTextAll("Match Info:\nMap: %s",
                               g_matchMap);
        }
        case MS_PICK_TEAMS:
        {
            decl String:ctName[64];
            decl String:tName[64];
            GetClientName(g_ctCaptain, ctName, sizeof(ctName));
            GetClientName(g_tCaptain, tName, sizeof(tName));
            PrintCenterTextAll("Match Info:\nMap: %s\n%s (CT) vs %s (T)",
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
        ServerCommand("tv_stoprecord\n");
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
    if (g_matchState != MS_LO3)
        return Plugin_Stop;

    PrintToChatAll("Live on 2...");
    ServerCommand("mp_restartgame 1\n");
    CreateTimer(3.0, Timer_Lo3Second);
    return Plugin_Stop;
}

public Action:Timer_Lo3Second(Handle:timer)
{
    if (g_matchState != MS_LO3)
        return Plugin_Stop;

    PrintToChatAll("Live after next restart...");
    ServerCommand("mp_restartgame 5\n");
    CreateTimer(6.0, Timer_Lo3Third);
    return Plugin_Stop;
}

public Action:Timer_Lo3Third(Handle:timer)
{
    if (g_matchState != MS_LO3)
        return Plugin_Stop;

    ChangeMatchState(MS_LIVE);
    LogToGame("GoonPUG triggered \"Start_Match\"");
    PrintCenterTextAll("LIVE! LIVE! LIVE!");
    return Plugin_Stop;
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
        default:
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
    if (g_matchState != MS_PICK_TEAMS)
        return Plugin_Stop;

    ChangeMatchState(MS_PRE_LIVE);
    decl String:map[64];
    GetNextMap(map, sizeof(map));
    ForceChangeLevel(map, "Changing to match map");

    return Plugin_Stop;
}

/**
 * Starts a ready up stage
 *
 * TODO: kick a player if not ready after a certain amount of time
 */
StartReadyUp(bool:reset=true)
{
    StopServerDemo();
    ServerCommand("exec goonpug_warmup.cfg\n");
    if (reset)
    {
        ResetReadyUp();
    }
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

    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !g_playerReady[i])
        {
            PrintCenterText(i, "Use /ready to ready up.");
        }
    }

    if ((count % 30) == 0)
    {
        PrintToChatAll("[GP] Still need %d players to ready up...", neededCount);
    }
    if ((count % 60) == 0)
    {
        PrintToChatAll("[GP] The following players are still not ready:");
        decl String:msg[192];
        Format(msg, sizeof(msg), "[GP] ");
        for (new i = 1; i <= MaxClients; i++)
        {
            if (IsValidPlayer(i) && !g_playerReady[i])
            {
                decl String:name[64];
                GetClientName(i, name, sizeof(name));
                new len = strlen(name);
                if ((len + strlen(msg)) > (sizeof(msg) - 1))
                {
                    PrintToChatAll(msg);
                    Format(msg, sizeof(msg), "[GP] ");
                }
                StrCat(msg, sizeof(msg), name);
                StrCat(msg, sizeof(msg), " ");
            }
        }
        PrintToChatAll(msg);
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
    LogToGame("GoonPUG triggered \"End_Match\"");

    // Set the nextmap to a warmup map
    decl String:map[64];
    GetArrayString(g_idleMapList, GetRandomInt(0, GetArraySize(g_idleMapList) - 1), map, sizeof(map));
    SetNextMap(map);
    PrintToChatAll("[GP] Switching to idle phase in 15 seconds...");
    CreateTimer(15.0, Timer_IdleMap);
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
 * Restart the warmup stage
 */
RestartWarmup(bool:reset=true)
{
    LogToGame("GoonPUG triggered \"Start_Warmup\"");
    UnlockAndClearTeams();
    ChangeMatchState(MS_WARMUP);
    StartReadyUp(reset);
}

/**
 * Forces the start of a warmup stage
 */
public Action:Command_Warmup(client, args)
{
    RestartWarmup();
    return Plugin_Handled;
}

/**
 * Executes a lo3 and starts a match
 */
public Action:Command_Lo3(client, args)
{
    LockCurrentTeams();
    StartLiveMatch();
    return Plugin_Handled;
}

/**
 * Unlocks teams
 */
public Action:Command_UnlockTeams(client, args)
{
    if (g_lockTeams)
    {
        g_lockTeams = false;
        PrintToChatAll("[GP] Teams are now unlocked.");
    }
    else
    {
        PrintToChat(client, "[GP] Teams are already unlocked.");
    }
}

/**
 * Locks teams
 */
public Action:Command_LockTeams(client, args)
{
    if (!g_lockTeams)
    {
        LockCurrentTeams();
        PrintToChatAll("[GP] Teams are now locked.");
    }
    else
    {
        PrintToChat(client, "[GP] Teams are already locked.");
    }
}

/**
 * Sets a player's ready up state to ready
 */
public Action:Command_Ready(client, args)
{
    switch (g_matchState)
    {
        case MS_WARMUP:
        {
            if (g_playerReady[client])
            {
                PrintToChat(client, "[GP] You are already ready.");
            }
            else if (CheckAllReady() > 0)
            {
                decl String:name[64];
                GetClientName(client, name, sizeof(name));
                g_playerReady[client] = true;
                PrintToChatAll("[GP] %s is now ready.", name);
            }
            else
            {
                PrintToChat(client, "[GP] Maximum number of players already readied up.");
            }
        }
        case MS_PRE_LIVE:
        {
            // Only want players in the match to ready up
            decl String:steamId[STEAMID_LEN];
            GetClientAuthString(client, steamId, sizeof(steamId));

            decl team;
            if (!GetTrieValue(g_playerTeamTrie, steamId, team))
            {
                // I don't think it's possible to get here, but just in case
                PrintToChat(client, "[GP] You can't ready up right now.");
            }
            else if (team != CS_TEAM_T && team != CS_TEAM_CT)
            {
                // Don't let non-assigned players ready up
                PrintToChat(client, "[GP] You can't ready up right now.");
            }
            else if (g_playerReady[client])
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
        }
        default:
        {
            PrintToChat(client, "[GP] You don't need to ready up right now.");
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
 * Initiates forfeit vote
 */
public Action:Command_Forfeit(client, args)
{
    if (g_matchState != MS_LIVE)
    {
        PrintToChat(client, "[GP] You can't do that right now.");
        return Plugin_Handled;
    }

    //get the team of client who initiated vote
    new team = GetClientTeam(client);
    if (team != CS_TEAM_T && team != CS_TEAM_CT)
    {
        PrintToChat(client, "[GP] You must be participating the match to start a restart vote.");
        return Plugin_Handled;
    }

    if (IsVoteInProgress())
    {
        PrintToChat(client, "[GP] You can't forfeit while another vote is in progress.");
        return Plugin_Handled;
    }

    //alert everyone that a forfeit vote is taking place
    decl String:name[64];
    GetClientName(client, name, sizeof(name));
    g_playerReady[client] = false;
    PrintToChatAll("[GP] %s wants to forfeit.", name);

    //build the forfeit vote menu
    new Handle:menu = CreateMenu(Menu_ForfeitVote);
    SetVoteResultCallback(menu, VoteHandler_ForfeitVote);
    SetMenuTitle(menu, "Forfeit?");
    AddMenuItem(menu, "yes", "Yes");
    AddMenuItem(menu, "no", "No");
    SetMenuExitButton(menu, false);

    new clientCount = 0;
    new clients[MAXPLAYERS + 1];

    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && GetClientTeam(i) == team)
        {
            clients[clientCount] = i;
            clientCount++;
        }
    }

    VoteMenu(menu, clients, clientCount, 30);

    return Plugin_Handled;
}

/**
 *Kicks one "random" unready player
 **/
public Action:Command_KickUnready(client, args)
{
    if (!NeedReadyUp())
    {
        PrintToChat(client, "[GP] Nobody still needs to ready up");
        return Plugin_Handled;
    }
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !g_playerReady[i])
        {
            decl String:name[64];
            GetClientName(i, name, sizeof(name));
            KickClient(i, "You have been kicked by an admin for being unready.");
            PrintToChatAll("[GP] %s has been kicked for being unready",
                           name);
            return Plugin_Handled;
        }
    }
    //This should only happen if no kickable players were found
    PrintToChat(client, "[GP] No valid unready players were found.");
    return Plugin_Handled;
}

public Menu_ForfeitVote(Handle:menu, MenuAction:action, param1, param2){
    if (action == MenuAction_End)
    {
        CloseHandle(menu);
    }
}

public VoteHandler_ForfeitVote(Handle:menu, num_votes, num_clients, const client_info[][2], num_items, const item_info[][2])
{
    decl String:vote[64];
    GetMenuItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], vote, sizeof(vote));

    //check to see that no one voted no, then end the match
    if(item_info[0][VOTEINFO_ITEM_VOTES] == num_clients && StrEqual(vote, "yes"))
    {
        PrintToChatAll("[GP] Team has unanimously agreed to forfeit");
        //TODO throw the appropriate events to end a match here
        PostMatch();
    }
    else
    {
        PrintToChatAll("[GP] Forfeit vote failed.");
    }
}

/**
 * Initiates restart vote
 */
public Action:Command_Restart(client, args)
{
    if (g_matchState != MS_LIVE)
    {
        PrintToChat(client, "[GP] You can't do that right now.");
        return Plugin_Handled;
    }

    new team = GetClientTeam(client);
    if (team != CS_TEAM_T && team != CS_TEAM_CT)
    {
        PrintToChat(client, "[GP] You must be participating the match to start a restart vote.");
        return Plugin_Handled;
    }

    if (IsVoteInProgress())
    {
        PrintToChat(client, "[GP] You can't start a restart vote while another vote is in progress.");
        return Plugin_Handled;
    }

    decl String:name[64];
    GetClientName(client, name, sizeof(name));
    g_playerReady[client] = false;
    PrintToChatAll("[GP] %s wants to restart the match.", name);

    //build the forfeit vote menu
    new Handle:menu = CreateMenu(Menu_RestartVote);
    SetVoteResultCallback(menu, VoteHandler_RestartVote);
    SetMenuTitle(menu, "Restart match?");
    AddMenuItem(menu, "yes", "Yes");
    AddMenuItem(menu, "no", "No");
    SetMenuExitButton(menu, false);

    new clientCount = 0;
    new clients[MAXPLAYERS + 1];
    for (new i = 1; i <= MaxClients; i++)
    {
        team = GetClientTeam(i);
        if (IsValidPlayer(i) && (team == CS_TEAM_CT || team == CS_TEAM_T))
        {
            clients[clientCount] = i;
            clientCount++;
        }
    }

    VoteMenu(menu, clients, clientCount, 30);

    return Plugin_Handled;
}

/**
 * Hooks the say command
 */
public Action:Command_Say(client, const String:command[], argc)
{
    decl String:param[32];
    GetCmdArg(1, param, sizeof(param));
    StripQuotes(param);
    if (StrEqual(param, ".ready"))
    {
        return Command_Ready(client, 0);
    }
    else
    {
        return Plugin_Continue;
    }
}

public Menu_RestartVote(Handle:menu, MenuAction:action, param1, param2){
    if (action == MenuAction_End)
    {
        CloseHandle(menu);
    }
}

public VoteHandler_RestartVote(Handle:menu, num_votes, num_clients, const client_info[][2], num_items, const item_info[][2])
{
    decl String:vote[64];
    GetMenuItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], vote, sizeof(vote));

    // check to see that no one voted no, then end the match
    if(item_info[0][VOTEINFO_ITEM_VOTES] == num_clients && StrEqual(vote, "yes"))
    {
        PrintToChatAll("[GP] Restart vote passed. Restarting match...");
        LogToGame("GoonPUG triggered \"Abandon_Match\"");
        StartLiveMatch();
    }
    else
    {
        PrintToChatAll("[GP] Restart vote failed.");
    }
}

/**
 * Forces players to join a specific team if teams are locked
 */
public Action:Command_Jointeam(client, const String:command[], argc)
{
    if (!IsValidPlayer(client))
        return Plugin_Continue;

    decl String:param[16];
    GetCmdArg(1, param, sizeof(param));
    StripQuotes(param);
    new team = StringToInt(param);

    if (g_lockTeams)
    {
        decl String:steamId[STEAMID_LEN];
        GetClientAuthString(client, steamId, sizeof(steamId));

        decl assignedTeam;
        if (GetTrieValue(g_playerTeamTrie, steamId, assignedTeam))
        {
            // player is assigned to a match team
            if (assignedTeam == CS_TEAM_CT)
            {
                PrintToChat(client, "[GP] You are assigned to the CT team.");
                ChangeClientTeam(client, CS_TEAM_CT);
            }
            else if (assignedTeam == CS_TEAM_T)
            {
                PrintToChat(client, "[GP] You are assigned to the T team.");
                ChangeClientTeam(client, CS_TEAM_T);
            }
            else if (g_matchState == MS_PICK_TEAMS)
            {
                PrintToChat(client, "[GP] You must stay spec until you are picked for a team.");
                ChangeClientTeam(client, CS_TEAM_SPECTATOR);
            }
            else
            {
                // player is not assigned to a match team, see if they are allowed
                // to join the requested team
                if (team == CS_TEAM_CT && g_ctSlots > 0)
                {
                    g_ctSlots--;
                    ForcePlayerTeam(client, CS_TEAM_CT);
                }
                else if (team == CS_TEAM_T && g_tSlots > 0)
                {
                    g_tSlots--;
                    ForcePlayerTeam(client, CS_TEAM_T);
                }
                else
                {
                    PrintToChat(client, "[GP] Teams are full right now.");
                    ForcePlayerTeam(client, CS_TEAM_SPECTATOR);
                }
            }
            return Plugin_Handled;
        }
        else
        {
            // we haven't seen this player yet. temporarily assign them to spectate
            // then try again
            SetTrieValue(g_playerTeamTrie, steamId, CS_TEAM_SPECTATOR);
            PushArrayString(g_playerTeamKeys, steamId);
            return Command_Jointeam(client, command, argc);
        }
    }
    else
    {
        return Plugin_Continue;
    }
}

/**
 * Updates our locked teams at halftime
 */
public Action:Event_AnnouncePhaseEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
    for (new i = 0; i < GetArraySize(g_playerTeamKeys); i++)
    {
        decl String:steamId[STEAMID_LEN];
        GetArrayString(g_playerTeamKeys, i, steamId, sizeof(steamId));
        decl team;
        GetTrieValue(g_playerTeamTrie, steamId, team);
        if (team == CS_TEAM_CT)
        {
            SetTrieValue(g_playerTeamTrie, steamId, CS_TEAM_T);
        }
        else if (team == CS_TEAM_T)
        {
            SetTrieValue(g_playerTeamTrie, steamId, CS_TEAM_CT);
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
    new dm = GetConVarInt(g_cvar_idleDeathmatch);
    if (NeedReadyUp() && dm != 0)
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

public Action:Timer_GraceTimer(Handle:timer, Handle:pack)
{
    static count = 0;
    decl String:playerName[64];
    decl String:steamId[STEAMID_LEN];

    ResetPack(pack);
    ReadPackString(pack, playerName, sizeof(playerName));
    ReadPackString(pack, steamId, sizeof(steamId));

    count++;
    if (count < 3)
    {
        PrintToChatAll("\x01\x0b\x02[GP]: %s has %d minutes to reconnect.",
                       playerName, (3 - count));
        return Plugin_Continue;
    }
    else
    {
        PrintToChatAll("\x01\x0b\x02[GP]: %s has abandoned the match.", playerName);

        new index = FindStringInArray(g_playerTeamKeys, steamId);
        if (index >= 0)
        {
            decl team;
            GetTrieValue(g_playerTeamTrie, steamId, team);
            if (team == CS_TEAM_CT)
            {
                g_ctSlots++;
                PrintToChatAll("[GP]: The CT team now has an open slot. A spectator may join the CT team.");
            }
            else if (team == CS_TEAM_T)
            {
                g_tSlots++;
                PrintToChatAll("[GP]: The T team now has an open slot. A spectator may join the T team.");
            }
        }
        return Plugin_Stop;
    }
}

/**
 * Start a 3 minute reconnect grace timer for the given player
 */
StartGraceTimer(const String:playerName[], const String:steamId[])
{
    PrintToChatAll("\x01\x0b\x02[GP]: %s has 3 minutes to reconnect.",
                   playerName);
    new Handle:pack;
    new Handle:timer = CreateDataTimer(60.0, Timer_GraceTimer, pack, TIMER_REPEAT | TIMER_DATA_HNDL_CLOSE | TIMER_FLAG_NO_MAPCHANGE);
    WritePackString(pack, playerName);
    WritePackString(pack, steamId);
    SetTrieValue(g_graceTimerTrie, steamId, timer);
}

/**
 * Handle player disconnections
 */
public Action:Event_PlayerDisconnect(
    Handle:event,
    const String:name[],
    bool:dontBroadcast)
{
    new userid = GetEventInt(event, "userid");
    new client = GetClientOfUserId(userid);

    if (client < 1 || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    decl String:steamId[STEAMID_LEN];
    GetClientAuthString(client, steamId, sizeof(steamId));
    decl String:playerName[64];
    GetClientName(client, playerName, sizeof(playerName));
    decl String:reason[64];
    GetEventString(event, "reason", reason, sizeof(reason));

    PrintToChatAll("\x01\x0b\x04%s disconnected: %s", playerName, reason);

    switch (g_matchState)
    {
        case MS_MAP_VOTE, MS_CAPTAINS_VOTE, MS_PICK_TEAMS:
        {
            /*
             * if a readied player drops in these states, just go back to
             * warmup and start over
             */
            if (g_playerReady[client])
            {
                PrintToChatAll("[GP]: Restarting warmup...");
                if (IsVoteInProgress())
                    CancelVote();
                RestartWarmup();
                g_playerReady[client] = false;
            }
        }
        case MS_PRE_LIVE, MS_LO3:
        {
            /*
             * If the player was involved in the match, start a reconnect grace
             * timer. After which, hold a vote to forfeit, play man down, or
             * allow any replacement player from spec to fill in.
             */
            g_playerReady[client] = false;
            decl team;
            if (GetTrieValue(g_playerTeamTrie, steamId, team)
                && (team == CS_TEAM_CT || team == CS_TEAM_T))
            {
                StartGraceTimer(playerName, steamId);
            }
        }
        case MS_LIVE:
        {
            /*
             * Start a reconnect grace timer. After which, hold a vote to
             * forfeit, play man down, or allow any replacement player from
             * spec to fill in.
             */
            decl team;
            if (GetTrieValue(g_playerTeamTrie, steamId, team)
                && (team == CS_TEAM_CT || team == CS_TEAM_T))
            {
                StartGraceTimer(playerName, steamId);
            }
        }
        default:
        {
            g_playerReady[client] = false;
        }
    }

    return Plugin_Continue;
}
