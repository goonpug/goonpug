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
 * @brief GoonPUG state headers
 *
 * @author Peter Rowlands <peter@pmrowla.com>
 */

#ifndef _GOONPUG_STATE_H_
#define _GOONPUG_STATE_H_

#include <eiface.h>

/**
 * GoonPUG State
 */
class GoonpugState
{
public:
    virtual bool init() { return true; }
    virtual bool fini() { return true; };

    // Chat commands
    virtual void ChatCommand_Help(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }
    virtual void ChatCommand_Ready(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }
    virtual void ChatCommand_Unready(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }
    virtual void ChatCommand_Hp(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }
    virtual void ChatCommand_Dmg(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }
    virtual void ChatCommand_Rank(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }
    virtual void ChatCommand_Dbserver(edict_t *pEntity, const CCommand &args) { forbiddenChatCommand(pEntity, args); }

private:
    void forbiddenChatCommand(edict_t *pEntity, const CCommand &args);
};

#endif // ! _GOONPUG_STATE_H
