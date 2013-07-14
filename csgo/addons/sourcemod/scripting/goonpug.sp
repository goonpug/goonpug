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

#define GOONPUG_VERSION "1.0.0-RC1"
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
new Handle:hMatchMapCollection = INVALID_HANDLE;
new Handle:hWarmupMapCollection = INVALID_HANDLE;

// .<cmd> chat command array
new Handle:hDotCmds = INVALID_HANDLE;

// Map lists
new Handle:hMatchMapKeys = INVALID_HANDLE;
new Handle:hMatchMaps = INVALID_HANDLE;
new Handle:hWarmupMapKeys = INVALID_HANDLE;
new Handle:hWarmupMaps = INVALID_HANDLE;

new bool:g_playerReady[MAXPLAYERS + 1];

new Handle:hPlayerRws = INVALID_HANDLE;
new Handle:hSortedClients = INVALID_HANDLE;

new String:g_capt1[64];
new String:g_capt2[64];
new g_captClients[2];
new g_firstPick = 0;
new g_period = 0;
new Handle:hTeamPickMenu = INVALID_HANDLE;
new g_whosePick = 0;

#define CS_TEAM_CT_FIRST 1
#define CS_TEAM_T_FIRST 2
enum GpTeam
{
    GP_TEAM_NONE = 0,
    GP_TEAM_1 = CS_TEAM_CT_FIRST,
    GP_TEAM_2 = CS_TEAM_T_FIRST,
};

// demo stuff
new bool:g_recording = false;
new String:g_demoname[PLATFORM_MAX_PATH];

new Handle:hTeam1 = INVALID_HANDLE;
new Handle:hTeam2 = INVALID_HANDLE;
new Handle:hSaveCash = INVALID_HANDLE;
new Handle:hSaveKills = INVALID_HANDLE;
new Handle:hSaveAssists = INVALID_HANDLE;
new Handle:hSaveDeaths = INVALID_HANDLE;
new Handle:hSaveScore = INVALID_HANDLE;

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
    hMatchMapCollection = CreateConVar("gp_match_map_collection", "141468891",
            "Match map workshop collection ID", FCVAR_PLUGIN | FCVAR_SPONLY);
    hWarmupMapCollection = CreateConVar("gp_warmup_map_collection", "141469710",
            "Warmup map workshop collection ID", FCVAR_PLUGIN | FCVAR_SPONLY);

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

    hPlayerRws = CreateTrie();
    hSortedClients = CreateArray();

    hTeam1 = CreateArray(STEAMID_LEN);
    hTeam2 = CreateArray(STEAMID_LEN);
    hSaveCash = CreateTrie();
    hSaveKills = CreateTrie();
    hSaveAssists = CreateTrie();
    hSaveDeaths = CreateTrie();
    hSaveScore = CreateTrie();

    ResetReadyUp();
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
    if (hPlayerRws != INVALID_HANDLE)
        CloseHandle(hPlayerRws);
    if (hSortedClients != INVALID_HANDLE)
        CloseHandle(hSortedClients);
    if (hTeam1 != INVALID_HANDLE)
        CloseHandle(hTeam1);
    if (hTeam2 != INVALID_HANDLE)
        CloseHandle(hTeam2 );
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

    FetchPlayerRws(auth);

    decl cash;
    if (GetTrieValue(hSaveCash, auth, cash))
    {
        SetEntProp(client, Prop_Send, "m_iAccount", cash);
    }

    decl kills;
    if (GetTrieValue(hSaveKills, auth, kills))
    {
        SetEntProp(client, Prop_Send, "m_iKills", kills);
    }

    decl assists;
    if (GetTrieValue(hSaveAssists, auth, assists))
    {
        new assists_offset = FindDataMapOffs(client, "m_iKills") + 4;
        SetEntData(client, assists_offset, assists);
    }

    decl deaths;
    if (GetTrieValue(hSaveDeaths, auth, deaths))
    {
        SetEntProp(client, Prop_Send, "m_iDeaths", deaths);
    }
}

FetchPlayerRws(const String:auth[])
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

    new Handle:headers = curl_slist();
    curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt_handle(hCurl, CURLOPT_HTTPHEADER, headers);
    new Handle:hPack = CreateDataPack();
    curl_easy_setopt_function(hCurl, CURLOPT_WRITEFUNCTION, CurlReceiveCb, hPack);
    decl String:url[256];
    Format(url, sizeof(url), "http://goonpug.com/api/player?q={\"auth_id\":\"%s\"}", auth);
    curl_easy_setopt_string(hCurl, CURLOPT_URL, url);
    curl_easy_perform_thread(hCurl, FetchRwsCb, hPack);
    CloseHandle(headers);
}

public FetchRwsCb(Handle:hCurl, CURLcode:code, any:hPack)
{
    CloseHandle(hCurl);
    if (CURLE_OK != code) {
        LogError("Curl could not fetch player info (%i)", code);
        return;
    }
    else
    {
        new endpos = GetPackPosition(hPack);
        ResetPack(hPack);
        decl String:receiveStr[CURL_BUFSIZE];
        strcopy(receiveStr, sizeof(receiveStr), "");
        while (GetPackPosition(hPack) < endpos)
        {
            decl String:buf[CURL_BUFSIZE];
            ReadPackString(hPack, buf, sizeof(buf));
            StrCat(receiveStr, sizeof(receiveStr), buf);
        }
        new Handle:hJson = json_load(receiveStr);
        if (hJson == INVALID_HANDLE)
            LogError("Got invalid RWS json object");
        else
        {
            new numResults = json_object_get_int(hJson, "num_results");
            if (numResults > 0)
            {
                new Handle:hObjects = json_object_get(hJson, "objects");
                new Handle:hPlayer = json_array_get(hObjects, 0);

                decl String:auth[STEAMID_LEN];
                json_object_get_string(hPlayer, "auth_id", auth, sizeof(auth));
                new Float:rws = json_object_get_float(hPlayer, "average_rws");
                SetTrieValue(hPlayerRws, auth, rws);
                PrintToServer("Got RWS for player %s: %f", auth, rws);
            }
            CloseHandle(hJson);
        }
    }
    CloseHandle(hPack);
}

public OnMapStart()
{
    FetchMapCollections();

    ClearSaves();

    // Refresh everyone's average RWS
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            decl String:auth[STEAMID_LEN];
            GetClientAuthString(i, auth, sizeof(auth));
            FetchPlayerRws(auth);
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
            g_matchState = MS_WARMUP;
            ServerCommand("exec goonpug_warmup.cfg\n");
            StartReadyUp(true);
        }
    }
}

public OnMapEnd()
{
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
FetchMapCollections()
{
    // Read our steam web API key
    new Handle:hFile = OpenFile("webapi_authkey.txt", "r");
    if (hFile == INVALID_HANDLE)
    {
        LogError("Could not open file webapi_authkey.txt");
        return;
    }

    decl String:apikey[33];
    ReadFileLine(hFile, apikey, sizeof(apikey));
    TrimString(apikey);
    CloseHandle(hFile);

    if (hMatchMapKeys == INVALID_HANDLE)
        hMatchMapKeys = CreateArray(32);

    if (hMatchMaps == INVALID_HANDLE)
        hMatchMaps = CreateTrie();

    if (hWarmupMapKeys == INVALID_HANDLE)
        hWarmupMapKeys = CreateArray(32);

    if (hWarmupMaps == INVALID_HANDLE)
        hWarmupMaps = CreateTrie();

    // GetConVarInt doesn't work properly here for some reason
    decl String:collection[16];
    GetConVarString(hMatchMapCollection, collection, sizeof(collection));
    FetchMapCollection(collection, apikey, MC_MATCH);
    GetConVarString(hWarmupMapCollection, collection, sizeof(collection));
    FetchMapCollection(collection, apikey, MC_WARMUP);
}

FetchMapCollection(const String:collection[], const String:apikey[], MapCollection:mc)
{
    new Handle:hCurl = curl_easy_init();
    if (hCurl == INVALID_HANDLE)
        return;

    PrintToServer("[GP] Fetching workshop map collection %s", collection);

    new CURL_Default_opt[][2] = {
        {_:CURLOPT_NOSIGNAL, 1},
        {_:CURLOPT_NOPROGRESS, 1},
        {_:CURLOPT_TIMEOUT, 30},
        {_:CURLOPT_CONNECTTIMEOUT, 30},
        {_:CURLOPT_VERBOSE, 0}
    };
    curl_easy_setopt_int_array(hCurl, CURL_Default_opt, sizeof(CURL_Default_opt));

    decl String:data[128];
    Format(data, sizeof(data), "key=%s&collectioncount=1&publishedfileids[0]=%s",
            apikey, collection);
    curl_easy_setopt_string(hCurl, CURLOPT_POSTFIELDS, data);
    new Handle:hPack = CreateDataPack();
    curl_easy_setopt_function(hCurl, CURLOPT_WRITEFUNCTION, CurlReceiveCb, hPack);
    curl_easy_setopt_string(hCurl, CURLOPT_URL,
            "http://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/");
    WritePackCell(hPack, mc);
    curl_easy_perform_thread(hCurl, FetchMapCollectionCb, hPack);
}

public FetchMapCollectionCb(Handle:hCurl, CURLcode:code, any:hPack)
{
    CloseHandle(hCurl);
    if (CURLE_OK != code)
    {
        LogError("Curl could not fetch map collectiond");
        return;
    }
    else
    {
        PrintToServer("Got collection info.");
        new endpos = GetPackPosition(hPack);
        ResetPack(hPack);
        decl Handle:hKeys;
        decl Handle:hMaps;
        new MapCollection:mc = ReadPackCell(hPack);
        switch (mc)
        {
            case MC_MATCH:
            {
                hKeys = hMatchMapKeys;
                hMaps = hMatchMaps;
            }
            case MC_WARMUP:
            {
                hKeys = hWarmupMapKeys;
                hMaps = hWarmupMaps;
            }
            default:
            {
                return;
            }
        }
        // We clear the keys array here to handle deleted maps. If the map
        // remains in the actual trie we don't really care since we only
        // iterate over the trie using the keys array.
        ClearArray(hKeys);
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
        new Handle:hDetails = json_object_get(hResponse, "collectiondetails");
        new Handle:hDetail = json_array_get(hDetails, 0);
        new Handle:hChildren = json_object_get(hDetail, "children");

        for (new i = 0; i < json_array_size(hChildren); i++)
        {
            new Handle:hChild = json_array_get(hChildren, i);
            new type = json_object_get_int(hChild, "filetype");
            if (type == 0)
            {
                decl String:fileid[16];
                json_object_get_string(hChild, "publishedfileid", fileid, sizeof(fileid));
                decl String:map[MAX_MAPNAME_LEN];
                if (!GetTrieString(hMaps, fileid, map, sizeof(map)))
                {
                    PrintToServer("Fetching map info for map %s", fileid);
                    FetchMapName(fileid, mc);
                }
                PushArrayString(hKeys, fileid);
            }
        }
        CloseHandle(hJson);
    }
    CloseHandle(hPack);
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

    new readyCount = CountReady();
    if (readyCount == g_maxPlayers)
    {
        OnAllReady();
        return Plugin_Stop;
    }

    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            decl String:msg[1024];
            Format(msg, sizeof(msg), "Ready: %d/%d - ", readyCount, g_maxPlayers);

            if (g_playerReady[i])
                StrCat(msg, sizeof(msg), "You are ready\n");
            else
                StrCat(msg, sizeof(msg), "Say .ready to ready up\n");
            new bool:first = true;
            for (new j = 1; j <= MaxClients; j++)
            {
                if (IsValidPlayer(j) && !IsFakeClient(j))
                {
                    decl String:name[64];
                    GetClientName(j, name, sizeof(name));
                    if (!g_playerReady[j])
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
            case MS_PRE_LIVE, MS_HALFTIME:
            {
                decl String:steamId[STEAMID_LEN];
                GetClientAuthString(client, steamId, sizeof(steamId));

                new GpTeam:assignedTeam = GP_TEAM_NONE;
                new index = FindStringInArray(hTeam1, steamId);
                if (index >= 0)
                {
                    assignedTeam = GP_TEAM_1;
                }
                else
                {
                    index = FindStringInArray(hTeam2, steamId);
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
        }

        decl String:name[64];
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
        decl String:name[64];
        GetClientName(client, name, sizeof(name));
        g_playerReady[client] = false;
        PrintToChatAll("[GP] %s is no longer ready.", name);
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

    decl String:steamId[STEAMID_LEN];
    GetClientAuthString(client, steamId, sizeof(steamId));
    decl String:playerName[64];
    GetClientName(client, playerName, sizeof(playerName));
    decl String:reason[64];
    GetEventString(event, "reason", reason, sizeof(reason));

    PrintToChatAll("\x01\x0b\x04%s disconnected: %s", playerName, reason);

    switch (g_matchState)
    {
        case MS_PICK_CAPTAINS, MS_PICK_TEAMS:
        {
            g_matchState = MS_PICK_CAPTAINS;

            if (g_playerReady[client])
            {
                if (IsVoteInProgress())
                    CancelVote();
                PrintToChatAll("[GP] Will restart picking teams when we have enough players...");
                StartReadyUp(false);
            }
        }
        // Previously there was stuff about slot handling here. If a slot is
        // open a player can just join.
    }

    new cash = GetEntProp(client, Prop_Send, "m_iAccount");
    SetTrieValue(hSaveCash, steamId, cash);

    new kills = GetEntProp(client, Prop_Send, "m_iKills");
    SetTrieValue(hSaveKills, steamId, kills);

    new assists_offset = FindDataMapOffs(client, "m_iKills") + 4;
    new assists = GetEntData(client, assists_offset);
    SetTrieValue(hSaveAssists, steamId, assists);

    new deaths = GetEntProp(client, Prop_Send, "m_iDeaths");
    SetTrieValue(hSaveDeaths, steamId, deaths);

    g_playerReady[client] = false;

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
            g_matchState = MS_LIVE;
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
    g_matchState = MS_MAP_VOTE;
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
                Format(map, sizeof(map), "workshop/%s/%s", fileid, mapname);
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
        Format(map, sizeof(map), "workshop/%s/%s", fileid, mapname);
        GPSetNextMap(map);
        ChooseCaptains();
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
    g_matchState = MS_PICK_CAPTAINS;
    StartMatchInfoText();

    SortPlayersByRws();

    new Handle:menu = CreateMenu(Menu_CaptainsVote);
    SetMenuTitle(menu, "Vote for captains (RWS in parentheses)");

    new count = 0;
    new i = 0;
    // Get up to 4 highest rws players
    while (count < 4 && i < GetArraySize(hSortedClients))
    {
        new client = GetArrayCell(hSortedClients, i);
        if (g_playerReady[client])
        {
            decl String:auth[STEAMID_LEN];
            GetClientAuthString(client, auth, sizeof(auth));
            decl String:name[64];
            GetClientName(client, name, sizeof(name));
            decl Float:rws;
            GetTrieValue(hPlayerRws, auth, rws);
            decl String:display[64];
            Format(display, sizeof(display), "(%.2f) %s", rws, name);
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

SortPlayersByRws()
{
    ClearArray(hSortedClients);
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            PushArrayCell(hSortedClients, i);
        }
    }
    SortADTArrayCustom(hSortedClients, RwsSortDescending);
}

public RwsSortDescending(index1, index2, Handle:array, Handle:hndl)
{
    decl String:auth1[STEAMID_LEN];
    GetClientAuthString(GetArrayCell(array, index1), auth1, sizeof(auth1));
    decl String:auth2[STEAMID_LEN];
    GetClientAuthString(GetArrayCell(array, index2), auth2, sizeof(auth2));

    decl Float:rws1;
    if (!GetTrieValue(hPlayerRws, auth1, rws1))
        rws1 = 0.0;
    decl Float:rws2;
    if (!GetTrieValue(hPlayerRws, auth2, rws2))
        rws2 = 0.0;

    if (rws1 > rws2)
        return -1;
    else if (rws1 == rws2)
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
    g_captClients[0] = FindClientByName(g_capt1);
    g_captClients[1] = FindClientByName(g_capt2);
    decl String:auth1[STEAMID_LEN];
    GetClientAuthString(g_captClients[0], auth1, sizeof(auth1));
    decl String:auth2[STEAMID_LEN];
    GetClientAuthString(g_captClients[1], auth2, sizeof(auth2));
    decl Float:capt1rws;
    if (!GetTrieValue(hPlayerRws, auth1, capt1rws))
    {
        capt1rws = 0.0;
    }
    decl Float:capt2rws;
    if (!GetTrieValue(hPlayerRws, auth2, capt2rws))
    {
        capt2rws = 0.0;
    }
    PrintToChatAll("[GP] %s's RWS: %.2f", g_capt1, capt1rws);
    PrintToChatAll("[GP] %s's RWS: %.2f", g_capt2, capt2rws);
    if (capt1rws < capt2rws)
    {
        PrintToChatAll("[GP] %s will pick first. %s will pick sides", g_capt1, g_capt2);
        g_firstPick = 0;
    }
    else if (capt1rws > capt2rws)
    {
        PrintToChatAll("[GP] %s will pick first. %s will pick sides", g_capt2, g_capt1);
        g_firstPick = 1;
    }
    else
    {
        new rand = GetURandomInt() % 2;
        if (rand == 0)
        {
            PrintToChatAll("[GP] %s will pick first. %s will pick sides", g_capt1, g_capt2);
            g_firstPick = 0;
        }
        else
        {
            PrintToChatAll("[GP] %s will pick first. %s will pick sides", g_capt2, g_capt1);
            g_firstPick = 1;
        }
    }

    ChooseSides();
}

ChooseSides()
{
    new Handle:menu = CreateMenu(Menu_Sides);
    SetMenuTitle(menu, "Which side do you want first?");
    AddMenuItem(menu, "CT", "CT");
    AddMenuItem(menu, "T", "T");
    SetMenuExitButton(menu, false);
    DisplayMenu(menu, g_captClients[g_firstPick ^ 1], 0);
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
                // Captain 2 should be team 1
                if (g_firstPick == 1)
                {
                    SwapCaptains();
                }
            }
            else
            {
                if (g_firstPick == 0)
                {
                    SwapCaptains();
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

/**
 * This function exists to keep captain 1 and 2 in line with valve cvars.
 * Team 1 is CT first, team 2 is T first.
 */
SwapCaptains()
{
    decl String:tmpname[64];
    strcopy(tmpname, sizeof(tmpname), g_capt1);
    strcopy(g_capt1, sizeof(g_capt1), g_capt2);
    strcopy(g_capt2, sizeof(g_capt2), tmpname);
    new tmp = g_captClients[0];
    g_captClients[0] = g_captClients[1];
    g_captClients[1] = tmp;
    g_firstPick ^= g_firstPick;
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
    g_matchState = MS_PICK_TEAMS;
    g_period = 0;
    SetTeamNames(g_capt1, g_capt2);
    ClearTeams();
    ForceAllSpec();
    ForcePlayerTeam(g_captClients[0], GP_TEAM_1);
    ForcePlayerTeam(g_captClients[1], GP_TEAM_2);
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

ForceAllSpec()
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            ForcePlayerTeam(i, GP_TEAM_NONE);
        }
    }
}

/**
 * Force a player to join the specified team
 */
ForcePlayerTeam(client, GpTeam:team, bool:changeTeam=true)
{
    if (IsValidPlayer(client))
    {
        decl String:steamId[STEAMID_LEN];
        GetClientAuthString(client, steamId, sizeof(steamId));

        decl index;
        if (team == GP_TEAM_1)
        {
            index = FindStringInArray(hTeam2, steamId);
            if (index >= 0)
                RemoveFromArray(hTeam2, index);
            index = FindStringInArray(hTeam1, steamId);
            if (index < 0)
                PushArrayString(hTeam1, steamId);
        }
        else if (team == GP_TEAM_2)
        {
            index = FindStringInArray(hTeam1, steamId);
            if (index >= 0)
                RemoveFromArray(hTeam1, index);
            index = FindStringInArray(hTeam2, steamId);
            if (index < 0)
                PushArrayString(hTeam2, steamId);
        }
        else
        {
            index = FindStringInArray(hTeam1, steamId);
            if (index >= 0)
                RemoveFromArray(hTeam1, index);
            index = FindStringInArray(hTeam2, steamId);
            if (index >= 0)
                RemoveFromArray(hTeam2, index);
        }

        if (changeTeam)
            GPChangeClientTeam(client, team);
    }
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
    static pickCount = 0;
    // If state was reset abort
    if (g_matchState != MS_PICK_TEAMS)
        return Plugin_Stop;

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
        g_matchState = MS_PRE_LIVE;
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
    else
    {
        if (pickNum == 1)
        {
            g_whosePick = g_firstPick;
            ClearArray(hSortedClients);
            for (new i = 1; i <= MaxClients; i++)
            {
                if (IsValidPlayer(i) && GetClientTeam(i) == CS_TEAM_SPECTATOR
                    && g_playerReady[i])
                {
                    PushArrayCell(hSortedClients, i);
                }
            }
            SortADTArrayCustom(hSortedClients, RwsSortDescending);
            pickCount = 1;
        }
        else if (pickCount == 2)
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
        hTeamPickMenu = BuildPickMenu();
        DisplayMenu(hTeamPickMenu, g_captClients[g_whosePick], 0);
        pickCount++;
        pickNum++;
    }

    return Plugin_Continue;
}

/**
 * Builds a menu with a list of pickable players
 */
Handle:BuildPickMenu()
{
    new Handle:menu = CreateMenu(Menu_PickPlayer);
    for (new i = 0; i < GetArraySize(hSortedClients); i++)
    {
        new client = GetArrayCell(hSortedClients, i);
        decl String:name[64];
        GetClientName(client, name, sizeof(name));
        decl String:auth[STEAMID_LEN];
        GetClientAuthString(client, auth, sizeof(auth));
        decl Float:rws;
        if (!GetTrieValue(hPlayerRws, auth, rws))
            rws = 0.0;
        decl String:display[64];
        Format(display, sizeof(display), "(%.2f) %s", rws, name);
        AddMenuItem(menu, name, display);
    }

    SetMenuTitle(menu, "Choose a player (RWS in parentheses)");
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
            decl String:pickName[64];
            GetMenuItem(menu, param2, pickName, sizeof(pickName));
            new pick = FindClientByName(pickName, true);

            if (g_whosePick == 0)
            {
                PrintToChatAll("[GP] %s picks %s.", g_capt1, pickName);
                ForcePlayerTeam(pick, GP_TEAM_1);
            }
            else
            {
                PrintToChatAll("[GP] %s picks %s.", g_capt2, pickName);
                ForcePlayerTeam(pick, GP_TEAM_2);
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

    // Always let players move to spec
    if (team == CS_TEAM_SPECTATOR)
    {
        return Plugin_Continue;
    }

    decl String:steamId[STEAMID_LEN];
    GetClientAuthString(client, steamId, sizeof(steamId));

    switch (g_matchState)
    {
        case MS_PICK_TEAMS, MS_PRE_LIVE, MS_LIVE, MS_HALFTIME, MS_OT:
        {
            new period = g_period;
            if (period == 0)
                period = 1;
            new GpTeam:assignedTeam = GP_TEAM_NONE;
            new index = FindStringInArray(hTeam1, steamId);
            if (index >= 0)
            {
                assignedTeam = GP_TEAM_1;
            }
            else
            {
                index = FindStringInArray(hTeam2, steamId);
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
                        {
                            ForcePlayerTeam(client, GP_TEAM_1);
                            PushArrayString(hTeam1, steamId);
                        }
                        else
                        {
                            GPChangeClientTeam(client, GP_TEAM_NONE);
                        }
                    }
                    else
                    {
                        if (TryJoinTeam(client, GP_TEAM_2))
                        {
                            ForcePlayerTeam(client, GP_TEAM_2);
                            PushArrayString(hTeam2, steamId);
                        }
                        else
                        {
                            GPChangeClientTeam(client, GP_TEAM_NONE);
                        }
                    }
                }
                else    // team == CS_TEAM_T
                {
                    if (period % 2)
                    {
                        // Team 1 is CT in odd halfs, T in even
                        if (TryJoinTeam(client, GP_TEAM_2))
                        {
                            ForcePlayerTeam(client, GP_TEAM_2);
                            PushArrayString(hTeam2, steamId);
                        }
                        else
                        {
                            GPChangeClientTeam(client, GP_TEAM_NONE);
                        }
                    }
                    else
                    {
                        if (TryJoinTeam(client, GP_TEAM_1))
                        {
                            ForcePlayerTeam(client, GP_TEAM_1);
                            PushArrayString(hTeam1, steamId);
                        }
                        else
                        {
                            GPChangeClientTeam(client, GP_TEAM_NONE);
                        }
                    }
                }
            }

            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

CountActivePlayers(GpTeam:team)
{
    decl Handle:hTeam;
    if (team == GP_TEAM_1)
        hTeam = hTeam1;
    else if (team == GP_TEAM_2)
        hTeam = hTeam2;
    else
        return 0;

    new count = 0;
    for (new i = 0; i < GetArraySize(hTeam); i++)
    {
        decl String:auth[STEAMID_LEN];
        GetArrayString(hTeam, i, auth, sizeof(auth));
        new client = FindClientByAuthString(auth);
        if (client > 0 && (GetClientTeam(client) == CS_TEAM_CT || GetClientTeam(client) == CS_TEAM_T))
        {
            count++;
        }
    }

    return count;
}

bool:TryJoinTeam(client, GpTeam:team)
{
    new count = CountActivePlayers(team);
    if (count < g_maxPlayers / 2)
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
    StartServerDemo();
    g_matchState = MS_LIVE;
    g_period = 1;
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
                UploadDemo(zip);
            }
        }
        else
        {   
            LogError("Could not open %s for writing", zip);
        }
    }
    DeleteFile(demo);
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
        Format(key, sizeof(key), "%s/%s", ip, filename);
    else
        Format(key, sizeof(key), "%s", filename);
    curl_formadd(hForm, CURLFORM_COPYNAME, "key", CURLFORM_COPYCONTENTS, key, CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "acl", CURLFORM_COPYCONTENTS, "public-read", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "AWSAccessKeyId", CURLFORM_COPYCONTENTS,
                 "AKIAIS5ZO5F5TODWJ6ZQ", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "Policy", CURLFORM_COPYCONTENTS,
                 "eyJleHBpcmF0aW9uIjogIjIwMTQtMDEtMDFUMDA6MDA6MDBaIiwNCiAgImNvbmRpdGlvbnMiOiBbIA0KICAgIHsiYnVja2V0IjogImdvb25wdWctZGVtb3MifSwgDQogICAgWyJzdGFydHMtd2l0aCIsICIka2V5IiwgIi8iXSwNCiAgICB7ImFjbCI6ICJwdWJsaWMtcmVhZCJ9LA0KICBdDQp9", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "signature", CURLFORM_COPYCONTENTS, "8RrNPLHjNXuCe6k2GGWwAAul3p0=", CURLFORM_END);
    curl_formadd(hForm, CURLFORM_COPYNAME, "file", CURLFORM_FILE, filename, CURLFORM_END);
    curl_easy_setopt_handle(hCurl, CURLOPT_HTTPPOST, hForm);
    curl_easy_setopt_string(hCurl, CURLOPT_URL, "http://goonpug-demos.s3.amazonaws.com");
    PrintToServer("[GP] Uploading %s to S3...", filename);
    WritePackCell(hPack, hForm);
    WritePackString(hPack, filename);
    curl_easy_perform_thread(hCurl, UploadDemoCb, hPack);
}

public UploadDemoCb(Handle:hCurl, CURLcode:code, any:hPack)
{
    CloseHandle(hCurl);
    ResetPack(hPack);
    new Handle:hForm = ReadPackCell(hPack);
    CloseHandle(hForm);

    if (CURLE_OK != code) {
        LogError("Curl could not upload demo (%i)", code);
        CloseHandle(hPack);
        return;
    }

    decl String:filename[PLATFORM_MAX_PATH];
    ReadPackString(hPack, filename, sizeof(filename));
    DeleteFile(filename);

    CloseHandle(hPack);
}

public Action:Event_AnnouncePhaseEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
    ClearSaves();
    if (g_period == 1)
    {
        PrintToChatAll("[GP] Halftime. Will resume match when all players are ready.");
        g_matchState = MS_HALFTIME;
        StartReadyUp(true);
    }
    else if ((g_period % 2) == 0)
    {
        StartOvertimeVote();
    }
    else
    {
        new Handle:pause = FindConVar("mp_halftime_pausetimer");
        SetConVarInt(pause, 0);
    }
    g_period++;

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
    g_matchState = MS_POST_MATCH;
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
        Format(map, sizeof(map), "workshop/%s/%s", fileid, mapname);
        GPSetNextMap(map);
        new Handle:hDelay = FindConVar("tv_delay");
        new Float:delay = float(GetConVarInt(hDelay));
        PrintToChatAll("[GP] Will switch to warmup map when GOTV broadcast completes (%0.f seconds)", delay);
        CreateTimer(delay, Timer_ChangeMap);
    }
    else
    {
        PrintToChatAll("[GP] Skipping warmup map change.");
        g_matchState = MS_WARMUP;
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
        g_matchState = MS_OT;
        new Handle:pause = FindConVar("mp_halftime_pausetimer");
        SetConVarInt(pause, 0);
        new Handle:time = FindConVar("mp_halftime_duration");
        new timeval = GetConVarInt(time);
        PrintToChatAll("[GP] Starting OT in in %d seconds.", timeval);
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
                    ForcePlayerTeam(i, GP_TEAM_1, false);
                }
                case CS_TEAM_T:
                {
                    ForcePlayerTeam(i, GP_TEAM_2, false);
                }
                default:
                {
                    ForcePlayerTeam(i, GP_TEAM_NONE, false);
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
            if (g_period % 2)
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
