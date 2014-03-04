/* Copyright (c) 2013 Astroman Technologies LLC
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
 *
 * vim: set ts=4 et ft=sourcepawn :
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
#include <protobuf>
#include <cURL>
#include <smjansson>
#include <zip>

#include <gp_team>
#include <gp_web>

#define GOONPUG_VERSION "1.0-beta"
#define MAX_ROUNDS 128
#define MAX_CMD_LEN 32
#define STEAMID_LEN 32
#define MAX_MAPNAME_LEN PLATFORM_MAX_PATH
#define CURL_BUFSIZE 4096

enum MatchState
{
    MS_WARMUP = 0,
    MS_MAP_VOTE,
    MS_PICK_CAPTAINS,
    MS_PICK_TEAMS,
    MS_PRE_LIVE,
    MS_LIVE,
    MS_OT,
    MS_HALFTIME,
    MS_POST_MATCH,
};
new MatchState:g_matchState = MS_WARMUP;

// This value could possibly change for certain game types (2v2/3v3 ladders
// etc)
new g_maxPlayers = 10;

// Global handles

enum MapCollection
{
    MC_MATCH = 0,
    MC_WARMUP,
};

// .<cmd> chat command array
new Handle:hDotCmds = INVALID_HANDLE;

// Map lists
new Handle:hMatchMapKeys = INVALID_HANDLE;
new Handle:hMatchMaps = INVALID_HANDLE;
new Handle:hWarmupMapKeys = INVALID_HANDLE;
new Handle:hWarmupMaps = INVALID_HANDLE;

new bool:g_playerReady[MAXPLAYERS + 1];

new Handle:hPlayerRating = INVALID_HANDLE;
new Handle:hSortedClients = INVALID_HANDLE;

new Handle:hRestrictCaptainsLimit = INVALID_HANDLE;
new String:g_capt1[MAX_NAME_LENGTH];
new String:g_capt2[MAX_NAME_LENGTH];
new g_captClients[2];
new g_period = 0;
new Handle:hTeamPickMenu = INVALID_HANDLE;
new g_whosePick = 0;

// demo stuff
new bool:g_recording = false;
new String:g_demoname[PLATFORM_MAX_PATH];

new Handle:hSaveCash = INVALID_HANDLE;
new Handle:hSaveKills = INVALID_HANDLE;
new Handle:hSaveAssists = INVALID_HANDLE;
new Handle:hSaveDeaths = INVALID_HANDLE;
new Handle:hSaveScore = INVALID_HANDLE;
new Handle:hSaveMvps = INVALID_HANDLE;

/**
 * Public plugin info
 */
public Plugin:myinfo = {
    name = "GoonPUG",
    author = "Peter \"astroman\" Rowlands",
    description = "CS:GO PUG Plugin",
    version = GOONPUG_VERSION,
    url = "http://github.com/goonpug/goonpug",
}

/**
 * Initialize GoonPUG
 */
public OnPluginStart()
{
    // Set up GoonPUG convars
    CreateConVar("sm_goonpug_version", GOONPUG_VERSION, "GoonPUG Plugin Version",
            FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_DONTRECORD);

    hRestrictCaptainsLimit = CreateConVar("gp_restrict_captains_limit", "0",
            "Restricts number of potential captains to the top N players",
            FCVAR_PLUGIN |FCVAR_SPONLY);

    // Register commands
    hDotCmds = CreateArray(MAX_CMD_LEN);
    RegDotCmd("ready", Command_Ready, "Set yourself as ready.");
    RegDotCmd("unready", Command_Unready, "Set yourself as not ready.");
    RegDotCmd("notready", Command_Unready, "Set yourself as not ready.");

    RegAdminCmd("sm_lo3", Command_Lo3, ADMFLAG_CHANGEMAP,
                "Start a live match with the current teams.");
    RegAdminCmd("sm_abortmatch", Command_AbortMatch, ADMFLAG_CHANGEMAP,
                "Abort the current match.");
    RegAdminCmd("sm_restartmatch", Command_RestartMatch, ADMFLAG_CHANGEMAP,
                "Restart the current match");
    RegAdminCmd("sm_endmatch", Command_EndMatch, ADMFLAG_CHANGEMAP,
                "End the current match.");

    // Hook commands
    AddCommandListener(Command_Jointeam, "jointeam");
    AddCommandListener(Command_Say, "say");
    AddCommandListener(Command_Say, "say2");
    AddCommandListener(Command_Say, "say_team");

    // Hook events
    //HookEvent("round_start", Event_RoundStart);
    //HookEvent("round_end", Event_RoundEnd);
    HookEvent("announce_phase_end", Event_AnnouncePhaseEnd);
    HookEvent("cs_win_panel_match", Event_CsWinPanelMatch);
    //HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_disconnect", Event_PlayerDisconnect);
    HookEvent("player_team", Event_PlayerTeam);

    hSaveCash = CreateTrie();
    hSaveKills = CreateTrie();
    hSaveAssists = CreateTrie();
    hSaveDeaths = CreateTrie();
    hSaveScore = CreateTrie();
    hSaveMvps = CreateTrie();

    ResetReadyUp();

    GpTeam_Init();
    GpWeb_Init();

    hPlayerRating = CreateTrie();
    hSortedClients = CreateArray();
}

public OnPluginEnd()
{
    if (hDotCmds != INVALID_HANDLE)
        CloseHandle(hDotCmds);
    if (hMatchMapKeys != INVALID_HANDLE)
        CloseHandle(hMatchMapKeys);
    if (hMatchMaps != INVALID_HANDLE)
        CloseHandle(hMatchMaps);
    if (hWarmupMapKeys != INVALID_HANDLE)
        CloseHandle(hWarmupMapKeys);
    if (hWarmupMaps != INVALID_HANDLE)
        CloseHandle(hWarmupMaps);
    if (hPlayerRating != INVALID_HANDLE)
        CloseHandle(hPlayerRating);
    if (hSortedClients != INVALID_HANDLE)
        CloseHandle(hSortedClients);
    if (hSaveCash != INVALID_HANDLE)
        CloseHandle(hSaveCash);
    if (hSaveKills != INVALID_HANDLE)
        CloseHandle(hSaveKills);
    if (hSaveAssists != INVALID_HANDLE)
        CloseHandle(hSaveAssists);
    if (hSaveDeaths!= INVALID_HANDLE)
        CloseHandle(hSaveDeaths);
    if (hSaveScore != INVALID_HANDLE)
        CloseHandle(hSaveScore);
    if (hSaveMvps != INVALID_HANDLE)
        CloseHandle(hSaveMvps);
    if (hRestrictCaptainsLimit != INVALID_HANDLE)
        CloseHandle(hRestrictCaptainsLimit);

    GpWeb_Fini();
    GpTeam_Fini();
}

public OnClientAuthorized(client, const String:auth[])
{
    if (IsFakeClient(client))
    {
        return;
    }

    decl String:playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));
    PrintToChatAll("\x01\x0b\x04%s connected", playerName);

    g_playerReady[client] = false;
    if (GpWeb_Enabled())
        GpWeb_FetchPlayerRating(auth);
}

ChangeMatchState(MatchState:newState)
{
    g_matchState = newState;
    switch (g_matchState)
    {
        case MS_WARMUP:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_WARMUP\"");
        }
        case MS_MAP_VOTE:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_MAP_VOTE\"");
        }
        case MS_PICK_CAPTAINS:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_PICK_CAPTAINS\"");
        }
        case MS_PICK_TEAMS:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_PICK_TEAMS\"");
        }
        case MS_PRE_LIVE:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_PRE_LIVE\"");
        }
        case MS_LIVE:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_LIVE\"");
        }
        case MS_OT:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_OT\"");
        }
        case MS_HALFTIME:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_HALFTIME\"");
        }
        case MS_POST_MATCH:
        {
            LogToGame("GoonPUG triggered \"state\" \"MS_POST_MATCH\"");
        }
    }
}

public OnMapStart()
{
    FetchMapLists();

    ClearSaves();

    if (GpWeb_Enabled())
    {
        // Refresh everyone's average rating
        for (new i = 1; i <= MaxClients; i++)
        {
            if (IsValidPlayer(i) && !IsFakeClient(i))
            {
                decl String:auth[STEAMID_LEN];
                GetClientAuthString(i, auth, sizeof(auth));
                GpWeb_FetchPlayerRating(auth);
            }
        }
    }

    switch (g_matchState)
    {
        case MS_WARMUP:
        {
            ServerCommand("exec goonpug_warmup.cfg\n");
            // Preserve ready up state across warmup map changes.
            // This prevents spot snipes when an admin changes the map
            StartReadyUp(false);
        }
        case MS_PRE_LIVE:
        {
            DoPreLive();
        }
        case MS_POST_MATCH:
        {
            ChangeMatchState(MS_WARMUP);
            ServerCommand("exec goonpug_warmup.cfg\n");
            StartReadyUp(true);
        }
    }
}

public OnMapEnd()
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            ChangeClientTeam(i, CS_TEAM_SPECTATOR);
        }
    }
}

DoPreLive()
{
    StartReadyUp(true);
    ServerCommand("mp_warmup_start\n");
    new Handle:warmup = FindConVar("mp_warmup_pausetimer");
    SetConVarInt(warmup, 1);
    SetTeamNames(g_capt1, g_capt2);
}

ClearSaves()
{
    ClearTrie(hSaveCash);
    ClearTrie(hSaveKills);
    ClearTrie(hSaveAssists);
    ClearTrie(hSaveDeaths);
    ClearTrie(hSaveScore);
    ClearTrie(hSaveMvps);
}

/**
 * Check if the specified client is a valid player
 *
 * NOTE: bots are considered to be valid players
 */
bool:IsValidPlayer(client)
{
    if (client > 0 && client <= MaxClients
        && IsClientConnected(client)
        && IsClientInGame(client))
    {
        if (IsClientSourceTV(client))
        {
                return false;
        }
        return true;
    }
    return false;
}

/**
 * Register a .<cmd> chat command
 */
RegDotCmd(const String:cmd[], ConCmd:callback, const String:description[]="", flags=0)
{
    decl String:newCmd[MAX_CMD_LEN];
    Format(newCmd, sizeof(newCmd), "sm_%s", cmd);
    RegConsoleCmd(newCmd, callback, description, flags);
    Format(newCmd, sizeof(newCmd), ".%s", cmd);
    PushArrayString(hDotCmds, newCmd);
}

/**
 * Fetch map lists
 */
FetchMapLists()
{
    if (hMatchMapKeys == INVALID_HANDLE)
        hMatchMapKeys = CreateArray(32);
    else
        ClearArray(hMatchMapKeys);

    if (hMatchMaps == INVALID_HANDLE)
        hMatchMaps = CreateTrie();

    if (hWarmupMapKeys == INVALID_HANDLE)
        hWarmupMapKeys = CreateArray(32);
    else
        ClearArray(hWarmupMapKeys);

    if (hWarmupMaps == INVALID_HANDLE)
        hWarmupMaps = CreateTrie();

    new serial = -1;
    new Handle:matchMapList = ReadMapList(INVALID_HANDLE, serial, "goonpug_match");
    if (INVALID_HANDLE == matchMapList)
        ThrowError("Could not read goonpug_match map list");

    new Handle:warmupMapList = ReadMapList(INVALID_HANDLE, serial, "goonpug_idle");
    if (INVALID_HANDLE == warmupMapList)
        ThrowError("Could not read goonpug_idle map list");

    ParseMapList(matchMapList, MC_MATCH);
    ParseMapList(warmupMapList, MC_WARMUP);

    CloseHandle(matchMapList);
    CloseHandle(warmupMapList);
}

ParseMapList(Handle:mapList, MapCollection:mc)
{
    if (INVALID_HANDLE == mapList)
        return;

    new localKey = 0;
    for (new i = 0; i < GetArraySize(mapList); i++)
    {
        decl String:mapname[MAX_MAPNAME_LEN];
        GetArrayString(mapList, i, mapname, sizeof(mapname));
        if (0 == strncmp(mapname, "workshop/", 9))
        {
            decl String:strs[3][128];
            ExplodeString(mapname, "/", strs, 3, 128);
            switch (mc)
            {
                case MC_MATCH:
                {
                    PushArrayString(hMatchMapKeys, strs[1]);
                }
                case MC_WARMUP:
                {
                    PushArrayString(hWarmupMapKeys, strs[1]);
                }
            }
            FetchMapName(strs[1], mc);
        }
        else
        {
            decl String:fileid[32];
            Format(fileid, sizeof(fileid), "GP_LOCAL_MAP%d", localKey);
            switch (mc)
            {
                case MC_MATCH:
                {
                    PushArrayString(hMatchMapKeys, fileid);
                    SetTrieString(hMatchMaps, fileid, mapname);
                }
                case MC_WARMUP:
                {
                    PushArrayString(hWarmupMapKeys, fileid);
                    SetTrieString(hWarmupMaps, fileid, mapname);
                }
            }
            localKey++;
        }
    }
}

FetchMapName(const String:fileid[], MapCollection:mc)
{
    new Handle:hCurl = curl_easy_init();
    if (hCurl == INVALID_HANDLE)
        return;

    new CURL_Default_opt[][2] = {
        {_:CURLOPT_NOSIGNAL, 1},
        {_:CURLOPT_NOPROGRESS, 1},
        {_:CURLOPT_TIMEOUT, 90},
        {_:CURLOPT_CONNECTTIMEOUT, 60},
        {_:CURLOPT_VERBOSE, 0}
    };
    curl_easy_setopt_int_array(hCurl, CURL_Default_opt, sizeof(CURL_Default_opt));

    decl String:data[128];
    Format(data, sizeof(data), "itemcount=1&publishedfileids[0]=%s", fileid);
    curl_easy_setopt_string(hCurl, CURLOPT_POSTFIELDS, data);
    new Handle:hPack = CreateDataPack();
    curl_easy_setopt_function(hCurl, CURLOPT_WRITEFUNCTION, CurlReceiveCb, hPack);
    curl_easy_setopt_string(hCurl, CURLOPT_URL,
            "http://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/");
    WritePackCell(hPack, mc);
    curl_easy_perform_thread(hCurl, FetchMapCb, hPack);
}

public FetchMapCb(Handle:hCurl, CURLcode:code, any:hPack)
{
    CloseHandle(hCurl);
    if (CURLE_OK != code)
    {
        LogError("Curl could not fetch map");
        return;
    }
    else
    {
        new endpos = GetPackPosition(hPack);
        ResetPack(hPack);
        new mc = ReadPackCell(hPack);
        decl String:receiveStr[CURL_BUFSIZE];
        strcopy(receiveStr, sizeof(receiveStr), "");
        while (GetPackPosition(hPack) < endpos)
        {
            decl String:buf[CURL_BUFSIZE];
            ReadPackString(hPack, buf, sizeof(buf));
            StrCat(receiveStr, sizeof(receiveStr), buf);
        }
        new Handle:hJson = json_load(receiveStr);
        new Handle:hResponse = json_object_get(hJson, "response");
        new Handle:hDetails = json_object_get(hResponse, "publishedfiledetails");
        new Handle:hDetail = json_array_get(hDetails, 0);
        decl String:map[MAX_MAPNAME_LEN];
        json_object_get_string(hDetail, "filename", map, sizeof(map));
        decl String:fileid[32];
        json_object_get_string(hDetail, "publishedfileid", fileid, sizeof(fileid));
        // filenames come back as "mymaps/mapname.bsp"
        ReplaceString(map, sizeof(map), "mymaps/", "");
        ReplaceString(map, sizeof(map), ".bsp", "");
        switch (mc)
        {
            case MC_MATCH:
            {
                SetTrieString(hMatchMaps, fileid, map);
            }
            case MC_WARMUP:
            {
                SetTrieString(hWarmupMaps, fileid, map);
            }
        }

        CloseHandle(hJson);
    }
    CloseHandle(hPack);
}

public CurlReceiveCb(Handle:hCurl, const String:buffer[], const bytes, const nmemb, any:hPack)
{
    decl String:buf[CURL_BUFSIZE];
    strcopy(buf, sizeof(buf), buffer);
    WritePackString(hPack, buf);
    return bytes * nmemb;
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
 * Starts a ready up stage
 */
StartReadyUp(bool:reset=true)
{
    if (reset)
    {
        ResetReadyUp();
    }
    CreateTimer(1.0, Timer_ReadyUp, _, TIMER_REPEAT);
}

/**
 * Check if the match is in a state where players need to ready up
 */
bool:NeedReadyUp()
{
    switch (g_matchState)
    {
        case MS_LIVE, MS_POST_MATCH, MS_OT:
        {
            return false;
        }
    }

    return true;
}

/**
 * Checks the ready up status periodically and displays it
 */
public Action:Timer_ReadyUp(Handle:timer)
{
    if (!NeedReadyUp())
    {
        return Plugin_Stop;
    }

    new neededCount = g_maxPlayers;
    if (g_matchState == MS_HALFTIME)
    {
        neededCount = CountActivePlayers(GP_TEAM_1) + CountActivePlayers(GP_TEAM_2);
    }

    new readyCount = CountReady();
    if (readyCount == neededCount)
    {
        OnAllReady();
        return Plugin_Stop;
    }

    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            decl String:msg[1024];
            Format(msg, sizeof(msg), "Ready: %d/%d - ", readyCount, neededCount);

            if (g_playerReady[i])
                StrCat(msg, sizeof(msg), "You are ready\n");
            else
                StrCat(msg, sizeof(msg), "Say .ready to ready up\n");
            new bool:first = true;
            for (new j = 1; j <= MaxClients; j++)
            {
                if (IsValidPlayer(j) && !IsFakeClient(j))
                {
                    decl String:name[MAX_NAME_LENGTH];
                    GetClientName(j, name, sizeof(name));
                    if (!g_playerReady[j] && GetClientTeam(j) != CS_TEAM_SPECTATOR)
                    {
                        if (first)
                        {
                            StrCat(msg, sizeof(msg), "Not Ready: ");
                            first = false;
                        }
                        else
                            StrCat(msg, sizeof(msg), ", ");
                        StrCat(msg, sizeof(msg), name);
                    }
                }
            }

            new Handle:pb = StartMessageOne("KeyHintText", i);
            PbAddString(pb, "hints", msg);
            EndMessage();
        }
    }

    return Plugin_Continue;
}

CountReady()
{
    new playerCount = 0;

    for (new i = 1; i < MaxClients; i++)
    {
        if (IsValidPlayer(i))
        {
            if (g_playerReady[i])
            {
                playerCount++;
            }
        }
    }

    return playerCount;
}

/**
 * Hooks the say command
 */
public Action:Command_Say(client, const String:command[], argc)
{
    decl String:param[MAX_CMD_LEN];
    GetCmdArg(1, param, sizeof(param));
    StripQuotes(param);
    if (-1 != FindStringInArray(hDotCmds, param))
    {
        ReplaceString(param, sizeof(param), ".", "sm_");
        FakeClientCommandEx(client, param);
        return Plugin_Handled;
    }
    else
    {
        return Plugin_Continue;
    }
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
    else if (CountReady() < g_maxPlayers)
    {
        switch (g_matchState)
        {
            case MS_PRE_LIVE:
            {
                decl String:auth[STEAMID_LEN];
                GetClientAuthString(client, auth, sizeof(auth));

                new GpTeam:assignedTeam = GP_TEAM_NONE;
                new index = FindStringInArray(hTeam1, auth);
                if (index >= 0)
                {
                    assignedTeam = GP_TEAM_1;
                }
                else
                {
                    index = FindStringInArray(hTeam2, auth);
                    if (index >= 0)
                    {
                        assignedTeam = GP_TEAM_2;
                    }
                }

                if (assignedTeam == GP_TEAM_NONE)
                {
                    PrintToChat(client, "[GP] You are not assigned to a team and cannot ready up right now.");
                    return Plugin_Handled;
                }
            }
            case MS_HALFTIME:
            {
                new team = GetClientTeam(client);
                if (CS_TEAM_CT != team && CS_TEAM_T != team)
                {
                    PrintToChat(client, "[GP] You cannot ready up right now.");
                    return Plugin_Handled;
                }
            }
        }

        decl String:name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        g_playerReady[client] = true;
        PrintToChatAll("[GP] %s is now ready.", name);
    }
    else
    {
        PrintToChat(client, "[GP] Maximum number of players already readied up.");
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
        switch (g_matchState)
        {
            case MS_PICK_CAPTAINS, MS_PICK_TEAMS:
            {
                PrintToChat(client, "[GP] You cannot unready right now as it would break team picking.");
            }
            default:
            {
                decl String:name[MAX_NAME_LENGTH];
                GetClientName(client, name, sizeof(name));
                g_playerReady[client] = false;
                PrintToChatAll("[GP] %s is no longer ready.", name);
            }
        }
    }

    return Plugin_Handled;
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

    decl String:auth[STEAMID_LEN];
    GetClientAuthString(client, auth, sizeof(auth));
    decl String:playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));
    decl String:reason[MAX_NAME_LENGTH];
    GetEventString(event, "reason", reason, sizeof(reason));

    PrintToChatAll("\x01\x0b\x04%s disconnected: %s", playerName, reason);

    switch (g_matchState)
    {
        case MS_PICK_CAPTAINS, MS_PICK_TEAMS:
        {
            if (g_playerReady[client])
            {
                ChangeMatchState(MS_PICK_CAPTAINS);
                PrintToChatAll("[GP] Will restart picking teams when we have enough players...");
                StartReadyUp(false);
            }
        }
        // Previously there was stuff about slot handling here. If a slot is
        // open a player can just join.
    }

    g_playerReady[client] = false;

    new cash = GetEntProp(client, Prop_Send, "m_iAccount");
    SetTrieValue(hSaveCash, auth, cash);

    new kills = GetClientFrags(client);
    SetTrieValue(hSaveKills, auth, kills);

    new assists = CS_GetClientAssists(client);
    SetTrieValue(hSaveAssists, auth, assists);

    new deaths = GetClientDeaths(client);
    SetTrieValue(hSaveDeaths, auth, deaths);

    new score = CS_GetClientContributionScore(client);
    SetTrieValue(hSaveScore, auth, score);

    new mvps = CS_GetMVPCount(client);
    SetTrieValue(hSaveMvps, auth, mvps);

    return Plugin_Continue;
}

public Action:Event_PlayerTeam(
    Handle:event,
    const String:name[],
    bool:dontBroadcast)
{
    new userid = GetEventInt(event, "userid");
    new client = GetClientOfUserId(userid);
    new oldteam = GetEventInt(event, "oldteam");
    new team = GetEventInt(event, "team");

    if (client < 1 || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    // Sanity check this because of auto-join timer stupidity
    if (oldteam == CS_TEAM_NONE)
    {
        FakeClientCommandEx(client, "jointeam \"%d\"", team);
    }

    return Plugin_Continue;
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
        //case MS_MAPVOTE: // Do nothing
        case MS_PICK_CAPTAINS:
        {
            ChooseCaptains();
        }
        case MS_PRE_LIVE:
        {
            StartLiveMatch();
        }
        case MS_HALFTIME:
        {
            new Handle:pause = FindConVar("mp_halftime_pausetimer");
            SetConVarInt(pause, 0);
            new Handle:time = FindConVar("mp_halftime_duration");
            new timeval = GetConVarInt(time);
            PrintToChatAll("[GP] All players ready, resuming match in %d seconds.", timeval);
            ChangeMatchState(MS_LIVE);
            g_period++;
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
 * Returns a menu for a map vote
 */
Handle:BuildMapVoteMenu()
{
    if (GetArraySize(hMatchMapKeys) == 0)
    {
        LogError("Empty match map list");
        return INVALID_HANDLE;
    }

    new Handle:menu = CreateMenu(Menu_MapVote);
    SetMenuTitle(menu, "Vote for the map to play");
    new Handle:maplist = CloneArray(hMatchMapKeys);
    for (new i = GetArraySize(hMatchMapKeys); i > 0; i--)
    {
        decl String:fileid[32];
        new index = GetURandomInt() % i;
        GetArrayString(maplist, index, fileid, sizeof(fileid));
        decl String:mapname[MAX_MAPNAME_LEN];
        GetTrieString(hMatchMaps, fileid, mapname, sizeof(mapname));
        AddMenuItem(menu, fileid, mapname);
        RemoveFromArray(maplist, index);
    }
    CloseHandle(maplist);
    SetMenuExitButton(menu, false);
    SetVoteResultCallback(menu, VoteHandler_MapVote);

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
        case MenuAction_VoteCancel:
        {
            if (param2 == VoteCancel_NoVotes)
            {
                new i = GetURandomInt() % GetMenuItemCount(menu);
                decl String:mapname[MAX_MAPNAME_LEN];
                decl String:fileid[32];
                GetMenuItem(menu, i, fileid, sizeof(fileid), _, mapname, sizeof(mapname));

                PrintToChatAll("[GP] No votes received, using random map: %s.",
                                mapname);

                decl String:map[MAX_MAPNAME_LEN];
                FormatMapName(map, sizeof(map), fileid, mapname);
                GPSetNextMap(map);
                ChooseCaptains();
            }
        }
    }
}

public VoteHandler_MapVote(Handle:menu, num_votes, num_clients, const client_info[][2], num_items, const item_info[][2])
{
    new Float:winningvotes = float(item_info[0][VOTEINFO_ITEM_VOTES]);
    new Float:required = float(num_votes) * 0.5;
    
    if (winningvotes < required)
    {
        /* runoff map vote */
        new Handle:newmenu = CreateMenu(Menu_MapVote);
        SetMenuTitle(newmenu, "Runoff map vote");
        SetMenuExitButton(menu, false);
        SetVoteResultCallback(newmenu, VoteHandler_MapVote);

        decl String:mapname[MAX_MAPNAME_LEN];
        decl String:fileid[32];
        GetMenuItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], fileid, sizeof(fileid), _, mapname, sizeof(mapname));
        AddMenuItem(newmenu, fileid, mapname);
        GetMenuItem(menu, item_info[1][VOTEINFO_ITEM_INDEX], fileid, sizeof(fileid), _, mapname, sizeof(mapname));
        AddMenuItem(newmenu, fileid, mapname);

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

        VoteMenu(newmenu, clients, clientCount, 30);
    }
    else
    {
        decl String:mapname[MAX_MAPNAME_LEN];
        decl String:fileid[32];
        GetMenuItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], fileid, sizeof(fileid), _, mapname, sizeof(mapname));
        PrintToChatAll("[GP] %s won with %0.f%% of the vote", mapname, (winningvotes / float(num_votes) * 100.0));

        decl String:map[MAX_MAPNAME_LEN];
        FormatMapName(map, sizeof(map), fileid, mapname);
        GPSetNextMap(map);
        ChooseCaptains();
    }
}

FormatMapName(String:map[], size, const String:fileid[], const String:mapname[])
{
    if (0 == strncmp(fileid, "GP_LOCAL_MAP", 12))
    {
        Format(map, size, "%s", mapname);
    }
    else
    {
        Format(map, size, "workshop/%s/%s", fileid, mapname);
    }
}

/**
 * Sets the next map
 *
 * Note that we don't use SM's SetNextMap because it will fail if the server
 * has not downloaded the specified workshop map yet
 */
GPSetNextMap(const String:map[])
{
    new Handle:nextmap = FindConVar("sm_nextmap");
    SetConVarString(nextmap, map, false, true);
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
    decl String:msg[256];
    decl String:mapname[MAX_MAPNAME_LEN];
    decl String:strs[3][MAX_MAPNAME_LEN];

    switch (g_matchState)
    {
        case MS_PICK_CAPTAINS:
        {
            GetNextMap(mapname, sizeof(mapname));
            new numStrs = ExplodeString(mapname, "/", strs, 3, 256);
            Format(msg, sizeof(msg), "Map: %s\n", strs[numStrs - 1]);
        }
        case MS_PICK_TEAMS:
        {
            GetNextMap(mapname, sizeof(mapname));
            new numStrs = ExplodeString(mapname, "/", strs, 3, 256);
            Format(msg, sizeof(msg), "Map: %s\nTeam %s vs Team %s", strs[numStrs - 1], g_capt1, g_capt2);
        }
        default:
        {
            // End of timer
            return Plugin_Stop;
        }
    }

    new Handle:pb = StartMessageAll("KeyHintText");
    PbAddString(pb, "hints", msg);
    EndMessage();

    return Plugin_Continue;
}

ChooseCaptains()
{
    ChangeMatchState(MS_PICK_CAPTAINS);
    StartMatchInfoText();

    SortPlayersByRating();

    new Handle:menu = CreateMenu(Menu_CaptainsVote);
    SetMenuTitle(menu, "Vote for captains");

    new count = 0;
    new i = 0;
    new maxCaptains = GetConVarInt(hRestrictCaptainsLimit);
    if (maxCaptains < 2 || !GpWeb_Enabled())
        maxCaptains = 10;

    // Get up to 4 highest rating players
    while (count < maxCaptains && i < GetArraySize(hSortedClients))
    {
        new client = GetArrayCell(hSortedClients, i);
        if (g_playerReady[client])
        {
            decl String:auth[STEAMID_LEN];
            GetClientAuthString(client, auth, sizeof(auth));
            decl String:name[MAX_NAME_LENGTH];
            GetClientName(client, name, sizeof(name));
            decl String:display[MAX_NAME_LENGTH * 2];
            if (GpWeb_Enabled())
            {
                decl Float:rating;
                GetTrieValue(hPlayerRating, auth, rating);
                Format(display, sizeof(display), "(%.2f) %s", rating, name);
            }
            else
            {
                Format(display, sizeof(display), "%s", name);
            }
            AddMenuItem(menu, name, display);
            count++;
        }
        i++;
    }
    // TODO implement random option
    //AddMenuItem(menu, "", "Scramble teams");

    if (count < 2)
    {
        PrintToChatAll("[GP] Not enough valid captains. Scrambling teams.");
        // TODO: If count < 2, just scramble teams
        CloseHandle(menu);
        return;
    }
    else if (count == 2)
    {
        PrintToChatAll("[GP] Only 2 possible choices for captains. Skipping vote.");
        GetMenuItem(menu, 0, g_capt1, sizeof(g_capt1));
        GetMenuItem(menu, 1, g_capt2, sizeof(g_capt2));
        CloseHandle(menu);
        DetermineFirstPick();
        return;
    }

    PrintToChatAll("[GP] Now voting for team captains.");
    PrintToChatAll("[GP] Top two vote getters will be selected.");

    SetMenuExitButton(menu, false);
    SetVoteResultCallback(menu, VoteHandler_CaptainsVote);

    new clientCount = 0;
    new clients[MAXPLAYERS + 1];

    for (i = 1; i <= MaxClients; i++)
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

SortPlayersByRating()
{
    ClearArray(hSortedClients);
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            PushArrayCell(hSortedClients, i);
        }
    }
    if (GpWeb_Enabled())
        SortADTArrayCustom(hSortedClients, RatingSortDescending);
}

public RatingSortDescending(index1, index2, Handle:array, Handle:hndl)
{
    if (!GpWeb_Enabled())
        return 0;

    decl String:auth1[STEAMID_LEN];
    GetClientAuthString(GetArrayCell(array, index1), auth1, sizeof(auth1));
    decl String:auth2[STEAMID_LEN];
    GetClientAuthString(GetArrayCell(array, index2), auth2, sizeof(auth2));

    decl Float:rating1;
    if (!GetTrieValue(hPlayerRating, auth1, rating1))
        rating1 = 0.0;
    decl Float:rating2;
    if (!GetTrieValue(hPlayerRating, auth2, rating2))
        rating2 = 0.0;

    if (rating1 > rating2)
        return -1;
    else if (rating1 == rating2)
        return 0;
    else
        return 1;
}

/**
 * Handler for captain voting results
 */
public VoteHandler_CaptainsVote(Handle:menu, num_votes, num_clients, const client_info[][2], num_items, const item_info[][2])
{
    GetMenuItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], g_capt1, sizeof(g_capt1));
    GetMenuItem(menu, item_info[1][VOTEINFO_ITEM_INDEX], g_capt2, sizeof(g_capt2));

    PrintToChatAll("[GP] %s will be a captain (%d votes).", g_capt1, item_info[0][VOTEINFO_ITEM_VOTES]);
    PrintToChatAll("[GP] %s will be a captain (%d votes).", g_capt2, item_info[1][VOTEINFO_ITEM_VOTES]);
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
            DetermineFirstPick();
        }
    }
}

DetermineFirstPick()
{
    new capt1 = FindClientByName(g_capt1, true);
    new capt2 = FindClientByName(g_capt2, true);

    g_captClients[0] = capt1;
    g_captClients[1] = capt2;
    LogAction(g_captClients[0], -1, "\"%L\" triggered \"GP Captain\"", g_captClients[0]);
    LogAction(g_captClients[1], -1, "\"%L\" triggered \"GP Captain\"", g_captClients[1]);

    if (GpWeb_Enabled())
    {
        decl Float:capt1rating;
        if (capt1 < 0)
        {
            LogError("Got invalid client for captain: %s", g_capt1);
            capt1rating = 0.0;
        }
        else
        {
            decl String:auth1[STEAMID_LEN];
            GetClientAuthString(capt1, auth1, sizeof(auth1));
            if (!GetTrieValue(hPlayerRating, auth1, capt1rating))
            {
                capt1rating = 0.0;
            }
        }

        decl Float:capt2rating;
        if (capt2 < 0)
        {
            LogError("Got invalid client for captain: %s", g_capt2);
            capt2rating = 0.0;
        }
        else
        {
            decl String:auth2[STEAMID_LEN];
            GetClientAuthString(capt2, auth2, sizeof(auth2));
            if (!GetTrieValue(hPlayerRating, auth2, capt2rating))
            {
                capt2rating = 0.0;
            }
        }

        PrintToChatAll("[GP] %s's GP Skill: %.2f", g_capt1, capt1rating);
        PrintToChatAll("[GP] %s's GP Skill: %.2f", g_capt2, capt2rating);

        if (capt1rating > capt2rating)
        {
            SwapCaptains();
        }
        else if (capt1rating == capt2rating)
        {
            new rand = GetURandomInt() % 2;
            if (rand == 1)
            {
                SwapCaptains();
            }
        }
    }
    else
    {
        new rand = GetURandomInt() % 2;
        if (rand == 1)
        {
            SwapCaptains();
        }
    }

    PrintToChatAll("[GP] %s will pick first. %s will pick sides", g_capt1, g_capt2);
    g_whosePick = 0;

    ChooseSides();
}

ChooseSides()
{
    new Handle:menu = CreateMenu(Menu_Sides);
    SetMenuTitle(menu, "Which side do you want first?");
    AddMenuItem(menu, "CT", "CT");
    AddMenuItem(menu, "T", "T");
    SetMenuExitButton(menu, false);
    DisplayMenu(menu, g_captClients[1], 0);
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
                SwapCaptains();
                g_whosePick = 1;
            }
            decl String:name[MAX_NAME_LENGTH];
            GetClientName(param1, name, sizeof(name));
            PrintToChatAll("[GP] %s will take %s side first.", name, info);
            LogAction(param1, -1, "\"%L\" chose side \"%s\"", param1, info);
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

/**
 * This function exists to keep captain 1 and 2 in line with valve cvars.
 * Team 1 is CT first, team 2 is T first.
 */
SwapCaptains()
{
    decl String:tmpname[MAX_NAME_LENGTH];
    strcopy(tmpname, sizeof(tmpname), g_capt1);
    strcopy(g_capt1, sizeof(g_capt1), g_capt2);
    strcopy(g_capt2, sizeof(g_capt2), tmpname);
    new tmp = g_captClients[0];
    g_captClients[0] = g_captClients[1];
    g_captClients[1] = tmp;
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
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            decl String:clientName[MAX_NAME_LENGTH];
            GetClientName(i, clientName, sizeof(clientName));
            if (exact)
            {
                if (StrEqual(clientName, name))
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
 * Returns a client ID that matches the specified steam ID
 *
 * @param exact true if only exact matches are acceptable
 *
 * @retval -1 No matching client found
 */
FindClientByAuthString(const String:auth[])
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            decl String:clientAuth[STEAMID_LEN];
            GetClientAuthString(i, clientAuth, sizeof(clientAuth));
            if (StrEqual(clientAuth, auth))
            {
                return i;
            }
        }
    }

    return -1;
}

/**
 * Actual picking of teams
 */
PickTeams()
{
    ChangeMatchState(MS_PICK_TEAMS);
    g_period = 0;
    ClearTeams();
    SetTeamNames(g_capt1, g_capt2);
    GpTeam_ForceAllSpec();
    GpTeam_AssignPlayerTeam(g_captClients[0], GP_TEAM_1);
    GpTeam_AssignPlayerTeam(g_captClients[1], GP_TEAM_2);

    ClearArray(hSortedClients);
    for (new i = 1; i <= MaxClients; i++)
    {
        if (!IsValidPlayer(i) || IsFakeClient(i))
            continue;

        if (i == g_captClients[0] || i == g_captClients[1])
            continue;

        if (g_playerReady[i])
        {
            PushArrayCell(hSortedClients, i);
        }
    }

    SortADTArrayCustom(hSortedClients, RatingSortDescending);

    if (hTeamPickMenu != INVALID_HANDLE)
    {
        CloseHandle(hTeamPickMenu);
        hTeamPickMenu = INVALID_HANDLE;
    }
    CreateTimer(1.0, Timer_PickTeams, _, TIMER_REPEAT);
}

SetTeamNames(const String:team1[], const String:team2[])
{
    new Handle:teamname = FindConVar("mp_teamname_1");
    SetConVarString(teamname, team1);
    teamname = FindConVar("mp_teamname_2");
    SetConVarString(teamname, team2);
}

ClearTeams()
{
    SetTeamNames("", "");
    ClearArray(hTeam1);
    ClearArray(hTeam2);
}


GPChangeClientTeam(client, GpTeam:team)
{
    new period = g_period;
    if (period == 0)
        period = 1;

    if (team == GP_TEAM_1)
    {
        // Team 1 is CT in odd halfs, T in even
        if (period % 2)
        {
            ChangeClientTeam(client, CS_TEAM_CT);
        }
        else
        {
            ChangeClientTeam(client, CS_TEAM_T);
        }
    }
    else if (team == GP_TEAM_2)
    {
        // Team 2 is T in odd halfs, CT in even
        if (period % 2)
        {
            ChangeClientTeam(client, CS_TEAM_T);
        }
        else
        {
            ChangeClientTeam(client, CS_TEAM_CT);
        }
    }
    else
    {
        ChangeClientTeam(client, CS_TEAM_SPECTATOR);
    }
}

public Action:Timer_PickTeams(Handle:timer)
{
    static pickNum = 1;
    static pickCount = 1;
    // If state was reset abort
    if (g_matchState != MS_PICK_TEAMS)
    {
        LogError("Got invalid state in Timer_PickTeams: %d", g_matchState);
        return Plugin_Stop;
    }

    // If invalid we can start the next pick.
    if (hTeamPickMenu != INVALID_HANDLE)
        return Plugin_Continue;

    if ((GetArraySize(hTeam1) + GetArraySize(hTeam2)) == g_maxPlayers)
    {
        PrintToChatAll("[GP] Done picking teams.");

        decl String:curmap[MAX_MAPNAME_LEN];
        GetCurrentMap(curmap, sizeof(curmap));
        decl String:nextmap[MAX_MAPNAME_LEN];
        GetNextMap(nextmap, sizeof(nextmap));
        ChangeMatchState(MS_PRE_LIVE);
        if (!StrEqual(nextmap, curmap))
        {
            PrintToChatAll("[GP] Changing map to %s in 10 seconds...", nextmap);
            CreateTimer(10.0, Timer_ChangeMap);
        }
        else
        {
            ServerCommand("exec goonpug_prelive.cfg\n");
            StartReadyUp(true);
        }
        return Plugin_Stop;
    }

    if (pickCount == 2)
    {
        g_whosePick ^= 1;
        pickCount = 0;
    }

    if (g_whosePick == 0)
    {
        PrintToChatAll("[GP] %s's pick...", g_capt1);
    }
    else
    {
        PrintToChatAll("[GP] %s's pick...", g_capt2);
    }
    hTeamPickMenu = BuildPickMenu(pickNum);
    DisplayMenu(hTeamPickMenu, g_captClients[g_whosePick], 0);
    pickCount++;
    pickNum++;

    return Plugin_Continue;
}

/**
 * Builds a menu with a list of pickable players
 */
Handle:BuildPickMenu(pickNum)
{
    new Handle:menu = CreateMenu(Menu_PickPlayer);
    if (GetArraySize(hSortedClients) != g_maxPlayers - 2 - (pickNum + 1))
    {
        LogError("Invalid pick array size. Captains = %d, %d", g_captClients[0], g_captClients[1]);
        LogError("Dumping pick list:");
        for (new i = 0; i < GetArraySize(hSortedClients); i++)
        {
            new client = GetArrayCell(hSortedClients, i);
            LogError("  %d: client %d, ready: %d", i, client, g_playerReady[client]);
        }
    }
    for (new i = 0; i < GetArraySize(hSortedClients); i++)
    {
        new client = GetArrayCell(hSortedClients, i);
        decl String:name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        decl String:display[MAX_NAME_LENGTH];
        if (GpWeb_Enabled())
        {
            decl String:auth[STEAMID_LEN];
            GetClientAuthString(client, auth, sizeof(auth));
            decl Float:rating;
            if (!GetTrieValue(hPlayerRating, auth, rating))
                rating = 0.0;
            Format(display, sizeof(display), "(%.2f) %s", rating, name);
        }
        else
        {
            Format(display, sizeof(display), "%s", name);
        }
        AddMenuItem(menu, name, display);
    }

    SetMenuTitle(menu, "Choose a player (GP Skill in parentheses)");
    SetMenuExitButton(menu, false);
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
            decl String:pickName[MAX_NAME_LENGTH];
            GetMenuItem(menu, param2, pickName, sizeof(pickName));
            new pick = FindClientByName(pickName, true);

            if (g_whosePick == 0)
            {
                PrintToChatAll("[GP] %s picks %s.", g_capt1, pickName);
                LogAction(g_captClients[0], pick, "\"%L\" picked \"%L\"", g_captClients[0], pick);
                GpTeam_AssignPlayerTeam(pick, GP_TEAM_1);
            }
            else
            {
                PrintToChatAll("[GP] %s picks %s.", g_capt2, pickName);
                LogAction(g_captClients[1], pick, "\"%L\" picked \"%L\"", g_captClients[1], pick);
                GpTeam_AssignPlayerTeam(pick, GP_TEAM_2);
            }

            new index = FindValueInArray(hSortedClients, pick);
            if (index >= 0)
                RemoveFromArray(hSortedClients, index);
        }
        case MenuAction_End:
        {
            CloseHandle(menu);
            hTeamPickMenu = INVALID_HANDLE;
        }
    }
}

/**
 * Forces players to join a specific team if teams are locked
 */
public Action:Command_Jointeam(client, const String:command[], argc)
{
    if (!IsValidPlayer(client) || IsFakeClient(client))
        return Plugin_Continue;

    decl String:param[16];
    GetCmdArg(1, param, sizeof(param));
    StripQuotes(param);
    new team = StringToInt(param);

    decl String:auth[STEAMID_LEN];
    GetClientAuthString(client, auth, sizeof(auth));

    // Always let players move to spec
    if (team == CS_TEAM_SPECTATOR)
    {
        return Plugin_Continue;
    }
    else if (team != CS_TEAM_NONE)
    {
        decl cash;
        if (GetTrieValue(hSaveCash, auth, cash))
        {
            SetEntProp(client, Prop_Send, "m_iAccount", cash);
            RemoveFromTrie(hSaveCash, auth);
        }

        decl kills;
        if (GetTrieValue(hSaveKills, auth, kills))
        {
            SetEntProp(client, Prop_Data, "m_iFrags", kills);
            RemoveFromTrie(hSaveKills, auth);
        }

        decl assists;
        if (GetTrieValue(hSaveAssists, auth, assists))
        {
            CS_SetClientAssists(client, assists);
            RemoveFromTrie(hSaveAssists, auth);
        }

        decl deaths;
        if (GetTrieValue(hSaveDeaths, auth, deaths))
        {
            SetEntProp(client, Prop_Data, "m_iDeaths", deaths);
            RemoveFromTrie(hSaveDeaths, auth);
        }

        decl score;
        if (GetTrieValue(hSaveScore, auth, score))
        {
            CS_SetClientContributionScore(client, score);
            RemoveFromTrie(hSaveScore, auth);
        }

        decl mvps;
        if (GetTrieValue(hSaveMvps, auth, mvps))
        {
            CS_SetMVPCount(client, mvps);
            RemoveFromTrie(hSaveMvps, auth);
        }
    }

    switch (g_matchState)
    {
        case MS_PICK_TEAMS:
        {
            new GpTeam:assignedTeam = GP_TEAM_NONE;
            new index = FindStringInArray(hTeam1, auth);
            if (index >= 0)
            {
                assignedTeam = GP_TEAM_1;
            }
            else
            {
                index = FindStringInArray(hTeam2, auth);
                if (index >= 0)
                {
                    assignedTeam = GP_TEAM_2;
                }
            }
            if (assignedTeam == GP_TEAM_NONE)
            {
                PrintToChat(client, "[GP] You cannot join a team until you are picked");
            }
            GPChangeClientTeam(client, assignedTeam);

            return Plugin_Handled;
        }
        case MS_PRE_LIVE, MS_LIVE, MS_HALFTIME, MS_OT:
        {
            new period = g_period;
            if (period == 0)
                period = 1;
            new GpTeam:assignedTeam = GP_TEAM_NONE;
            new index = FindStringInArray(hTeam1, auth);
            if (index >= 0)
            {
                assignedTeam = GP_TEAM_1;
            }
            else
            {
                index = FindStringInArray(hTeam2, auth);
                if (index >= 0)
                {
                    assignedTeam = GP_TEAM_2;
                }
            }

            if (assignedTeam != GP_TEAM_NONE) // already assigned to a team
            {
                if (!TryJoinTeam(client, assignedTeam))
                {
                    PrintToChat(client, "[GP] You are assigned to a team but it is currently full.");
                    PrintToChat(client, "[GP] A substitute player must leave the game or join the spectators before you can rejoin.");
                    ChangeClientTeam(client, CS_TEAM_SPECTATOR);
                }
            }
            else
            {
                if (team == CS_TEAM_CT)
                {
                    if (period % 2)
                    {
                        // Team 1 is CT in odd halfs, T in even
                        if (TryJoinTeam(client, GP_TEAM_1))
                            assignedTeam = GP_TEAM_1;
                    }
                    else
                    {
                        if (TryJoinTeam(client, GP_TEAM_2))
                            assignedTeam = GP_TEAM_2;
                    }
                }
                else    // team == CS_TEAM_T
                {
                    if (period % 2)
                    {
                        // Team 2 is T in odd halfs, CT in even
                        if (TryJoinTeam(client, GP_TEAM_2))
                            assignedTeam = GP_TEAM_2;
                    }
                    else
                    {
                        if (TryJoinTeam(client, GP_TEAM_1))
                            assignedTeam = GP_TEAM_1;
                    }
                }

                if (assignedTeam == GP_TEAM_NONE)
                {
                    if (team == CS_TEAM_CT)
                        PrintToChat(client, "[GP] The CT team is current full.");
                    else if (team == CS_TEAM_T)
                        PrintToChat(client, "[GP] The T team is current full.");
                    else
                        PrintToChat(client, "[GP] You cannot auto-assign right now.");
                    GPChangeClientTeam(client, assignedTeam);
                }
            }

            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

CountActivePlayers(GpTeam:team)
{
    new period = g_period;
    if (period == 0)
        period = 1;

    new csTeam = CS_TEAM_SPECTATOR;
    if (team == GP_TEAM_1)
    {
        if (period % 2)
            csTeam = CS_TEAM_CT;
        else
            csTeam = CS_TEAM_T;
    }
    else if (team == GP_TEAM_2)
    {
        if (period % 2)
            csTeam = CS_TEAM_T;
        else
            csTeam = CS_TEAM_CT;
    }
    else
        return 0;

    new count = 0;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i) && GetClientTeam(i) == csTeam)
            count++;
    }

    return count;
}

bool:TryJoinTeam(client, GpTeam:team)
{
    new count = CountActivePlayers(team);
    PrintToServer("[GP] Got %d/%d active players for GP team %d", count, g_maxPlayers / 2, team);
    if (count < (g_maxPlayers / 2))
    {
        GPChangeClientTeam(client, team);
        return true;
    }
    return false;
}

public Action:Timer_ChangeMap(Handle:timer)
{
    decl String:map[MAX_MAPNAME_LEN];
    GetNextMap(map, sizeof(map));
    ForceChangeLevel(map, "Changing level");
    return Plugin_Stop;
}

StartLiveMatch()
{
    LogToGame("GoonPUG triggered \"Start_Match\"");
    StartServerDemo();
    ChangeMatchState(MS_LIVE);
    g_period = 1;
    ServerCommand("mp_warmup_end\n");
    ServerCommand("exec goonpug_pug.cfg\n");
    PrintToChatAll("[GP] Live after restart!!!");
    ServerCommand("mp_restartgame 10\n");
    CreateTimer(11.0, Timer_Lo3);
}

public Action:Timer_Lo3(Handle:timer)
{
    ServerCommand("mp_warmup_end\n");
    new Handle:pb = StartMessageAll("KeyHintText");
    PbAddString(pb, "hints", "LIVE! LIVE! LIVE!");
    EndMessage();
    return Plugin_Stop;
}

StartServerDemo()
{
    if (g_recording)
        StopServerDemo(false);
    new time = GetTime();
    decl String:timestamp[128];
    FormatTime(timestamp, sizeof(timestamp), "%F_%H.%M", time);
    decl String:map[256];
    GetCurrentMap(map, sizeof(map));
    /* Strip workshop prefixes */
    decl String:strs[3][256];
    new numStrs = ExplodeString(map, "/", strs, 3, 256);
    Format(g_demoname, sizeof(g_demoname), "%s_%s", timestamp, strs[numStrs - 1]);
    ServerCommand("tv_record %s.dem\n", g_demoname);
    LogToGame("Recording server demo: %s_%s.dem",  timestamp, strs[numStrs - 1]);
    g_recording = true;
}

StopServerDemo(bool:save=true)
{
    ServerCommand("tv_stoprecord\n");
    new Handle:hPack = CreateDataPack();
    WritePackCell(hPack, save);
    WritePackString(hPack, g_demoname);
    // Need to wait here for tv_stoprecord to finish
    CreateTimer(5.0, Timer_CompressDemo, hPack);
    g_recording = false;
}

public Action:Timer_CompressDemo(Handle:timer, Handle:pack)
{
    ResetPack(pack);
    new bool:save = ReadPackCell(pack);
    decl String:demoname[PLATFORM_MAX_PATH];
    ReadPackString(pack, demoname, sizeof(demoname));

    decl String:demo[PLATFORM_MAX_PATH];
    Format(demo, sizeof(demo), "%s.dem", demoname);
    if (save)
    {
        decl String:zip[PLATFORM_MAX_PATH];
        Format(zip, sizeof(zip), "%s.zip", demoname);
        new Handle:hZip = Zip_Open(zip, ZIP_APPEND_STATUS_CREATE);
        if (INVALID_HANDLE != hZip)
        {
            if (!Zip_AddFile(hZip, demo))
            {
                LogError("Could not compress demo file %s", demo, zip);
                CloseHandle(hZip);
                DeleteFile(zip);
            }
            else
            {
                CloseHandle(hZip);
                LogToGame("Wrote compressed demo %s", zip);
                DeleteFile(demo);
                UploadDemo(zip);
            }
        }
        else
        {   
            LogError("Could not open %s for writing", zip);
        }
    }
    else
    {
        DeleteFile(demo);
    }
}

UploadDemo(const String:filename[])
{
    new Handle:netPublicAdr = FindConVar("net_public_adr");
    decl String:ip[16];
    GetConVarString(netPublicAdr, ip, sizeof(ip));

    new Handle:hCurl = curl_easy_init();
    if (hCurl == INVALID_HANDLE)
        return;

    new CURL_Default_opt[][2] = {
        {_:CURLOPT_NOSIGNAL, 1},
        {_:CURLOPT_NOPROGRESS, 1},
        {_:CURLOPT_TIMEOUT, 90},
        {_:CURLOPT_CONNECTTIMEOUT, 60},
        {_:CURLOPT_VERBOSE, 0}
    };
    curl_easy_setopt_int_array(hCurl, CURL_Default_opt, sizeof(CURL_Default_opt));
    new Handle:hPack = CreateDataPack();
    curl_easy_setopt_function(hCurl, CURLOPT_WRITEFUNCTION, CurlReceiveCb, hPack);

    // TODO: Use web server to manage different api keys for each server we
    // know about
    new Handle:hForm = curl_httppost();
    decl String:key[PLATFORM_MAX_PATH];
    if (strlen(ip) > 0)
        Format(key, sizeof(key), "uploads/gotv/%s/%s", ip, filename);
    else
        Format(key, sizeof(key), "uploads/gotv/unknown/%s", filename);
    curl_formadd(hForm, CURLFORM_COPYNAME, "key", CURLFORM_COPYCONTENTS, key, CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "acl", CURLFORM_COPYCONTENTS, "public-read", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "AWSAccessKeyId", CURLFORM_COPYCONTENTS,
                 "AKIAIS5ZO5F5TODWJ6ZQ", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "Policy", CURLFORM_COPYCONTENTS,
                 "ewogICAgImV4cGlyYXRpb24iOiAiMjAxNC0wMS0wMVQwMDowMDowMFoiLAogICAgImNvbmRpdGlvbnMiOiBbCiAgICAgICAgeyJidWNrZXQiOiAiZ29vbnB1Zy1kZW1vcyJ9LAogICAgICAgIFsic3RhcnRzLXdpdGgiLCAiJGtleSIsICJ1cGxvYWRzLyJdLAogICAgICAgIHsiYWNsIjogInB1YmxpYy1yZWFkIn0sCiAgICAgICAgeyJDb250ZW50LVR5cGUiOiAiYXBwbGljYXRpb24vemlwIn0KICAgIF0KfQ==", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "signature", CURLFORM_COPYCONTENTS, "nh4qMbsylhC3xb+z2ybQ/Yzh4Ks=", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "Content-Type", CURLFORM_COPYCONTENTS, "application/zip", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "file", CURLFORM_FILE, filename, CURLFORM_END);
    curl_easy_setopt_handle(hCurl, CURLOPT_HTTPPOST, hForm);
    curl_easy_setopt_string(hCurl, CURLOPT_URL, "http://goonpug-demos.s3.amazonaws.com");
    PrintToServer("[GP] Uploading %s to S3...", filename);
    LogMessage("[GP] Uploading %s to S3...", filename);
    WritePackCell(hPack, hForm);
    WritePackString(hPack, filename);
    curl_easy_perform_thread(hCurl, UploadDemoCb, hPack);
}

public UploadDemoCb(Handle:hCurl, CURLcode:code, any:hPack)
{
    new endpos = GetPackPosition(hPack);
    ResetPack(hPack);
    new Handle:hForm = ReadPackCell(hPack);
    CloseHandle(hForm);

    if (CURLE_OK != code) {
        LogError("Curl could not upload demo (%i)", code);
        CloseHandle(hPack);
        CloseHandle(hCurl);
        return;
    }

    decl httpcode;
    curl_easy_getinfo_int(hCurl, CURLINFO_RESPONSE_CODE, httpcode);
    if (httpcode != 204)
    {
        LogError("Got unexpected response from AWS: %d", httpcode);
    }
    CloseHandle(hCurl);

    decl String:filename[PLATFORM_MAX_PATH];
    ReadPackString(hPack, filename, sizeof(filename));
    DeleteFile(filename);

    decl String:receiveStr[CURL_BUFSIZE];
    strcopy(receiveStr, sizeof(receiveStr), "");
    while (GetPackPosition(hPack) < endpos)
    {
        decl String:buf[CURL_BUFSIZE];
        ReadPackString(hPack, buf, sizeof(buf));
        StrCat(receiveStr, sizeof(receiveStr), buf);
    }
    LogMessage("Upload demo returned: %s", receiveStr);

    CloseHandle(hPack);
}

public Action:Event_AnnouncePhaseEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (g_period == 1)
    {
        PrintToChatAll("[GP] Halftime. Will resume match when all players are ready.");
        ChangeMatchState(MS_HALFTIME);
        StartReadyUp(true);
    }
    else if ((g_period % 2) == 0 && (GetTeamScore(CS_TEAM_CT) == GetTeamScore(CS_TEAM_T)))
    {
        StartOvertimeVote();
    }
    else
    {
        new Handle:pause = FindConVar("mp_halftime_pausetimer");
        SetConVarInt(pause, 0);
    }

    return Plugin_Continue;
}

public Action:Event_CsWinPanelMatch(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (g_matchState == MS_LIVE || g_matchState == MS_OT)
    {
        PostMatch();
    }
    return Plugin_Continue;
}

PostMatch(bool:abort=false)
{
    ChangeMatchState(MS_POST_MATCH);
    if (abort)
    {
        StopServerDemo(false);
        LogToGame("GoonPUG triggered \"Abort_Match\"");
    }
    else
    {
        StopServerDemo();
        LogToGame("GoonPUG triggered \"End_Match\"");
    }

    // Set the nextmap to a warmup map
    if (GetArraySize(hWarmupMapKeys) > 0)
    {
        new rand = GetURandomInt() % GetArraySize(hWarmupMapKeys);
        decl String:fileid[32];
        GetArrayString(hWarmupMapKeys, rand, fileid, sizeof(fileid));
        decl String:mapname[MAX_MAPNAME_LEN];
        GetTrieString(hWarmupMaps, fileid, mapname, sizeof(mapname));
        decl String:map[MAX_MAPNAME_LEN];
        FormatMapName(map, sizeof(map), fileid, mapname);
        GPSetNextMap(map);
        new Handle:hDelay = FindConVar("tv_delay");
        new Float:delay = float(GetConVarInt(hDelay));
        PrintToChatAll("[GP] Will switch to warmup map when GOTV broadcast completes (%0.f seconds)", delay);
        CreateTimer(delay, Timer_ChangeMap);
    }
    else
    {
        PrintToChatAll("[GP] Skipping warmup map change.");
        ChangeMatchState(MS_WARMUP);
        ServerCommand("exec goonpug_warmup.cfg\n");
        StartReadyUp(true);
    }
}

StartOvertimeVote()
{
    new Handle:menu = CreateMenu(Menu_OvertimeVote);
    SetMenuTitle(menu, "Continue match?");
    AddMenuItem(menu, "Yes", "Yes (Play OT)");
    AddMenuItem(menu, "No", "No (End match in tie)");
    SetMenuExitButton(menu, false);
    SetVoteResultCallback(menu, VoteHandler_OvertimeVote);

    new clientCount = 0;
    new clients[MAXPLAYERS + 1];

    for (new i = 0; i < GetArraySize(hTeam1); i++)
    {
        decl String:auth[STEAMID_LEN];
        GetArrayString(hTeam1, i, auth, sizeof(auth));
        new client = FindClientByAuthString(auth);
        if (client > 0 && (GetClientTeam(client) == CS_TEAM_CT || GetClientTeam(client) == CS_TEAM_T))
        {
            clients[clientCount] = client;
            clientCount++;
        }
    }

    for (new i = 0; i < GetArraySize(hTeam2); i++)
    {
        decl String:auth[STEAMID_LEN];
        GetArrayString(hTeam2, i, auth, sizeof(auth));
        new client = FindClientByAuthString(auth);
        if (client > 0 && (GetClientTeam(client) == CS_TEAM_CT || GetClientTeam(client) == CS_TEAM_T))
        {
            clients[clientCount] = client;
            clientCount++;
        }
    }

    VoteMenu(menu, clients, clientCount, 30);
}

public Menu_OvertimeVote(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_End:
        {
            CloseHandle(menu);
        }
    }
}

public VoteHandler_OvertimeVote(Handle:menu, num_votes, num_clients, const client_info[][2], num_items, const item_info[][2])
{
    new Float:winningvotes = float(item_info[0][VOTEINFO_ITEM_VOTES]);
    new Float:required = float(num_votes) * 0.5;
    decl String:result[8];
    GetMenuItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], result, sizeof(result));
    
    if (StrEqual(result, "Yes") && winningvotes > required)
    {
        PrintToChatAll("[GP] Vote to play OT wins (%0.f%%).", (winningvotes / float(num_votes) * 100.0));
        ChangeMatchState(MS_OT);
        new Handle:pause = FindConVar("mp_halftime_pausetimer");
        SetConVarInt(pause, 0);
        new Handle:time = FindConVar("mp_halftime_duration");
        new timeval = GetConVarInt(time);
        PrintToChatAll("[GP] Starting OT in in %d seconds.", timeval);
        g_period++;
    }
    else
    {
        PrintToChatAll("[GP] Vote to play OT fails.");
        PrintToChatAll("[GP] Match ended.");
        PostMatch();
    }
}

public Action:Command_Lo3(client, args)
{
    LockCurrentTeams();
    StartLiveMatch();

    return Plugin_Handled;
}

LockCurrentTeams()
{
    ClearTeams();

    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            decl String:auth[STEAMID_LEN];
            GetClientAuthString(i, auth, sizeof(auth));
            switch (GetClientTeam(i))
            {
                case CS_TEAM_CT:
                {
                    GpTeam_AssignPlayerTeam(i, GP_TEAM_1, false);
                }
                case CS_TEAM_T:
                {
                    GpTeam_AssignPlayerTeam(i, GP_TEAM_2, false);
                }
                default:
                {
                    GpTeam_AssignPlayerTeam(i, GP_TEAM_NONE, false);
                }
            }
        }
    }
}

public Action:Command_AbortMatch(client, args)
{
    switch (g_matchState)
    {
        case MS_PRE_LIVE, MS_LIVE, MS_HALFTIME, MS_OT:
        {
            PrintToChatAll("[GP] Aborting current match.");
            PostMatch(true);
        }
        default:
        {
            PrintToChatAll("[GP] You can't do that right now.");
        }
    }

    return Plugin_Handled;
}

public Action:Command_RestartMatch(client, args)
{
    switch (g_matchState)
    {
        case MS_LIVE, MS_HALFTIME, MS_OT:
        {
            PrintToChatAll("[GP] Restarting current match.");
            LogToGame("GoonPUG triggered \"Restart_Match\"");
            if (g_period % 2 == 0)
            {
                SwapSides();
            }
            StartLiveMatch();
        }
        default:
        {
            PrintToChatAll("[GP] You can't do that right now.");
        }
    }

    return Plugin_Handled;
}

public Action:Command_EndMatch(client, args)
{
    switch (g_matchState)
    {
        case MS_LIVE, MS_HALFTIME, MS_OT:
        {
            PrintToChatAll("[GP] Ending current match.");
            PostMatch();
        }
        default:
        {
            PrintToChatAll("[GP] You can't do that right now.");
        }
    }

    return Plugin_Handled;
}

SwapSides()
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            switch (GetClientTeam(i))
            {
                case CS_TEAM_CT:
                {
                    ChangeClientTeam(i, CS_TEAM_T);
                }
                case CS_TEAM_T:
                {
                    ChangeClientTeam(i, CS_TEAM_CT);
                }
            }
        }
    }
}
