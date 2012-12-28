/**
 * Goon competitive PUG plugin
 *
 * Author: astroman <peter@pmrowla.com>
 */

#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <sdktools_functions>

#define GOONPUG_VERSION "0.0.1"

#if defined MAXPLAYERS
#undef MAXPLAYERS
#endif

#define MAXPLAYERS 64

/**
 * Match states
 */
enum MatchState
{
    MS_PRE_SETUP = 0,
    MS_SETUP,
    MS_PRE_1H,
    MS_LIVE_1H,
    MS_PRE_2H,
    MS_LIVE_2H,
    MS_PRE_OT_1H,
    MS_LIVE_OT_1H,
    MS_PRE_OT_2H,
    MS_LIVE_OT_2H,
    MS_POST_MATCH,
};

// Global convar handles
new Handle:g_hMaxPugPlayers;

// GO:TV
new Handle:g_hTvEnabled;

// Current match state
new MatchState:g_matchState = MS_PRE_SETUP;

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
    g_hMaxPugPlayers = CreateConVar("gp_max_pug_players", "10",
                                    "Maximum players allowed in a PUG",
                                    FCVAR_PLUGIN|FCVAR_REPLICATED|FCVAR_SPONLY|FCVAR_NOTIFY);

    // Load global convars
    g_hTvEnabled = FindConVar("tv_enable");

    // Register commands
    RegConsoleCmd("sm_ready", CmdReady, "Sets a client's status to ready.");
    RegConsoleCmd("sm_unready", CmdUnReady, "Sets a client's status to not ready.");
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
 * Check if the match is in a state where players need to ready up
 */
bool:NeedReadyUp()
{
    switch (g_matchState)
    {
        case MS_PRE_SETUP, MS_PRE_1H, MS_PRE_2H, MS_PRE_OT_1H, MS_PRE_OT_2H:
        {
            return true;
        }
    }

    return false;
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

    for (new i = 1; i < MAXPLAYERS; i++)
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
        new neededCount = GetConVarInt(g_hMaxPugPlayers);

        if (playerCount < neededCount)
        {
            allReady = false
        }

        PrintToChatAll("[GoonPUG] Still waiting on %d players to join...",
                       neededCount - playerCount);
    }

    return allReady;
}

/**
 * Sets a player's ready up state to ready
 */
public Action:CmdReady(client, args)
{
    if (!NeedReadyUp())
    {
        PrintToChat(client, "[GoonPUG] You don't need to ready up right now.");
        return Plugin_Handled;
    }

    if (g_playerReady[client])
    {
        PrintToChat(client, "[GoonPUG] You are already ready.")
    }
    else
    {
        decl String:name[64];
        GetClientName(client, name, sizeof(name));
        g_playerReady[client] = true;
        PrintToChatAll("[GoonPUG] %s is now ready.", name);

        CheckAllReady()
    }

    return Plugin_Handled;
}

/**
 * Sets a player's ready up state to not ready
 */
public Action:CmdUnReady(client, args)
{
    if (!NeedReadyUp())
    {
        PrintToChat(client, "[GoonPUG] You don't need to ready up right now.");
        return Plugin_Handled;
    }

    if (!g_playerReady[client])
    {
        PrintToChat(client, "[GoonPUG] You are already not ready.")
    }
    else
    {
        decl String:name[64];
        GetClientName(client, name, sizeof(name));
        g_playerReady[client] = false;
        PrintToChatAll("[GoonPUG] %s is no longer ready.", name);

        // Call this check to print the waiting for count
        CheckAllReady()
    }

    return Plugin_Handled;
}
