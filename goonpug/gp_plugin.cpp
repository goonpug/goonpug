/*
 * Copyright (c) 2013 Peter Rowlands
 *
 * This file is a part of GoonPUG.
 *
 * GoonPUG is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
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
 * @file
 * @brief Main GoonPUG plugin
 *
 * @author Peter Rowlands <peter@pmrowla.com>
 */

#include <cstdlib>
#include <cstring>
#include <cctype>
#include <string>
#include <map>
#include <ISmmPlugin.h>
#include <igameevents.h>
#include <iplayerinfo.h>
#include <sh_vector.h>

#include "goonpug.h"
#include "gp_plugin.h"

GoonpugPlugin g_goonpugPlugin;
PLUGIN_EXPOSE(goonpug, g_goonpugPlugin);

IServerGameDLL *server = NULL;
IServerGameClients *gameclients = NULL;
IVEngineServer *engine = NULL;
IServerPluginHelpers *helpers = NULL;
IGameEventManager2 *gameevents = NULL;
IServerPluginCallbacks *vsp_callbacks = NULL;
IPlayerInfoManager *playerinfomanager = NULL;
ICvar *icvar = NULL;
CGlobalVars *gpGlobals = NULL;

// Hook declarations

// virtual void ClientCommand( edict_t *pEntity, const CCommand &args ) = 0;
SH_DECL_HOOK2_void(IServerGameClients, ClientCommand, SH_NOATTRIB, 0, edict_t *, const CCommand &);

/* 
 * Something like this is needed to register cvars/CON_COMMANDs.
 */
class BaseAccessor : public IConCommandBaseAccessor
{
public:
    bool RegisterConCommandBase(ConCommandBase *pCommandBase)
    {
        /* Always call META_REGCVAR instead of going through the engine. */
        return META_REGCVAR(pCommandBase);
    }
} s_BaseAccessor;

bool GoonpugPlugin::Load(PluginId id, ISmmAPI *ismm, char *error, size_t maxlen, bool late)
{
    PLUGIN_SAVEVARS();

    GET_V_IFACE_CURRENT(GetEngineFactory, engine, IVEngineServer, INTERFACEVERSION_VENGINESERVER);
    GET_V_IFACE_CURRENT(GetEngineFactory, gameevents, IGameEventManager2, INTERFACEVERSION_GAMEEVENTSMANAGER2);
    GET_V_IFACE_CURRENT(GetEngineFactory, helpers, IServerPluginHelpers, INTERFACEVERSION_ISERVERPLUGINHELPERS);
    GET_V_IFACE_CURRENT(GetEngineFactory, icvar, ICvar, CVAR_INTERFACE_VERSION);
    GET_V_IFACE_ANY(GetServerFactory, server, IServerGameDLL, INTERFACEVERSION_SERVERGAMEDLL);
    GET_V_IFACE_ANY(GetServerFactory, gameclients, IServerGameClients, INTERFACEVERSION_SERVERGAMECLIENTS);
    GET_V_IFACE_ANY(GetServerFactory, playerinfomanager, IPlayerInfoManager, INTERFACEVERSION_PLAYERINFOMANAGER);

    gpGlobals = ismm->GetCGlobals();

    META_LOG(g_PLAPI, "Starting plugin.");

    /* Load the VSP listener.  This is usually needed for IServerPluginHelpers. */
    if ((vsp_callbacks = ismm->GetVSPInfo(NULL)) == NULL)
    {
        ismm->AddListener(this, this);
        ismm->EnableVSPListener();
    }

    g_pCVar = icvar;
    ConVar_Register(0, &s_BaseAccessor);

    // Load hooks
    SH_ADD_HOOK_MEMFUNC(IServerGameClients, ClientCommand, gameclients, this, &GoonpugPlugin::Hook_ClientCommand, false);

    return true;
}

bool GoonpugPlugin::Unload(char *error, size_t maxlen)
{
    // Unload hooks
    SH_REMOVE_HOOK_MEMFUNC(IServerGameClients, ClientCommand, gameclients, this, &GoonpugPlugin::Hook_ClientCommand, false);
    return true;
}

bool GoonpugPlugin::Pause(char *error, size_t maxlen)
{
	return true;
}

bool GoonpugPlugin::Unpause(char *error, size_t maxlen)
{
	return true;
}


void GoonpugPlugin::OnVSPListening(IServerPluginCallbacks *iface)
{
	vsp_callbacks = iface;
}

void GoonpugPlugin::AllPluginsLoaded()
{
	/* This is where we'd do stuff that relies on the mod or other plugins 
	 * being initialized (for example, cvars added and events registered).
	 */
}

/**
 * Call the handler for the specified command
 */
void GoonpugPlugin::Hook_ClientCommand(edict_t *pEntity, const CCommand &args)
{
    if (!pEntity || pEntity->IsFree())
    {
        return;
    }

    const char *cmd = args.Arg(0);
    if (strcmp(cmd, "say") == 0 || strcmp(cmd, "say_team") == 0 || strcmp(cmd, "say2") == 0)
    {
        Command_Say(pEntity, args);
    }
    else if (strcmp(cmd, "jointeam") == 0)
    {
        Command_Jointeam(pEntity, args);
    }
}

/**
 * Command handler for "say"
 */
void GoonpugPlugin::Command_Say(edict_t *pEntity, const CCommand &args)
{
    const char *cmd = args.Arg(0);
    size_t len = strlen(cmd);
    char *tmp;

    if (len < 2)
    {
        return;
    }

    switch (cmd[0])
    {
        case '.':
        case '/':
        case '!':
            tmp = (char *)malloc(len);
            if (tmp == NULL)
            {
                return;
            }
            strncpy(tmp, cmd + 1, len);
            tmp[len - 1] = '\0';
            for (size_t i = 0; i < len; i++)
            {
                tmp[i] = tolower(tmp[i]);
            }

            if (strcmp(tmp, "help") == 0)
            {
                //ChatCommand_Help(pEntity, args);
            }
            else if (strcmp(tmp, "ready") == 0)
            {
                //ChatCommand_Ready(pEntity, args);
            }
            else if (strcmp(tmp, "unready") == 0)
            {
                //ChatCommand_Unready(pEntity, args);
            }
            else if (strcmp(tmp, "hp") == 0)
            {
                //ChatCommand_Hp(pEntity, args);
            }
            else if (strcmp(tmp, "dmg") == 0)
            {
                //ChatCommand_Dmg(pEntity, args);
            }
            else if (strcmp(tmp, "rank") == 0)
            {
                //ChatCommand_Rank(pEntity, args);
            }
            else if (strcmp(tmp, "dbserver") == 0)
            {
                //ChatCommand_Dbserver(pEntity, args);
            }

            free(tmp);
            break;
        default:
            break;
    }
}

/**
 * Command handler for "jointeam"
 */
void GoonpugPlugin::Command_Jointeam(edict_t *pEntity, const CCommand &args)
{
}

const char *GoonpugPlugin::GetLicense()
{
    return "GPLv3";
}

const char *GoonpugPlugin::GetVersion()
{
    return GOONPUG_VERSION;
}

const char *GoonpugPlugin::GetDate()
{
    return __DATE__;
}

const char *GoonpugPlugin::GetLogTag()
{
    return "GoonPUG";
}

const char *GoonpugPlugin::GetAuthor()
{
    return "Peter Rowlands";
}

const char *GoonpugPlugin::GetDescription()
{
    return "CS:GO competitive PUG plugin";
}

const char *GoonpugPlugin::GetName()
{
    return "GoonPUG Plugin";
}

const char *GoonpugPlugin::GetURL()
{
    return "http://www.goonpug.com/";
}
