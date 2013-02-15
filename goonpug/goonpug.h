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
 * @brief GoonPUG headers
 *
 * @author Peter Rowlands <peter@pmrowla.com>
 */

#ifndef _GOONPUG_H_
#define _GOONPUG_H_

#include <ISmmPlugin.h>
#include <igameevents.h>
#include <iplayerinfo.h>
#include <sh_vector.h>

class GoonpugPlugin : public ISmmPlugin, public IMetamodListener
{
public:
	bool Load(PluginId id, ISmmAPI *ismm, char *error, size_t maxlen, bool late);
	bool Unload(char *error, size_t maxlen);
	bool Pause(char *error, size_t maxlen);
	bool Unpause(char *error, size_t maxlen);
	void AllPluginsLoaded();
    // IMetamodListener
	void OnVSPListening(IServerPluginCallbacks *iface);
    // Hooks
	bool Hook_LevelInit(
        const char *pMapName,
		char const *pMapEntities,
		char const *pOldLevel,
		char const *pLandmarkName,
		bool loadGame,
		bool background);
	void Hook_LevelShutdown(void);
	void Hook_ClientActive(edict_t *pEntity, bool bLoadGame);
	void Hook_ClientDisconnect(edict_t *pEntity);
	void Hook_ClientPutInServer(edict_t *pEntity, char const *playername);
	void Hook_SetCommandClient(int index);
	void Hook_ClientSettingsChanged(edict_t *pEdict);
	bool Hook_ClientConnect(
        edict_t *pEntity, 
		const char *pszName,
		const char *pszAddress,
		char *reject,
		int maxrejectlen);
	void Hook_ClientCommand(edict_t *pEntity, const CCommand &args);
private:
    // Command handlers
    void Command_Say(edict_t *pEntity, const CCommand &args);
    void Command_Jointeam(edict_t *pEntity, const CCommand &args);
    void Command_Lo3(edict_t *pEntity, const CCommand &args); 
    void Command_Warmup(edict_t *pEntity, const CCommand &args); 
    // Chat commands
    void ChatCommand_Help(edict_t *pEntity, const CCommand &args); 
    void ChatCommand_Ready(edict_t *pEntity, const CCommand &args); 
    void ChatCommand_Unready(edict_t *pEntity, const CCommand &args); 
    void ChatCommand_Hp(edict_t *pEntity, const CCommand &args); 
    void ChatCommand_Dmg(edict_t *pEntity, const CCommand &args); 
    void ChatCommand_Rank(edict_t *pEntity, const CCommand &args); 
    void ChatCommand_Dbserver(edict_t *pEntity, const CCommand &args); 
public:
	const char *GetAuthor();
	const char *GetName();
	const char *GetDescription();
	const char *GetURL();
	const char *GetLicense();
	const char *GetVersion();
	const char *GetDate();
	const char *GetLogTag();
};

extern GoonpugPlugin g_SamplePlugin;

PLUGIN_GLOBALVARS();

#endif // ! _GOONPUG_H_
