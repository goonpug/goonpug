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
 * @brief GoonPUG generic headers
 *
 * @author Peter Rowlands <peter@pmrowla.com>
 */

#include "gp_version.h"

#include <eiface.h>
#include <iplayerinfo.h>

#define MAX_CLIENTS 64

#define GP_MSG_LEN 192 // Maximum length of a chat message

extern IVEngineServer *engine;
extern IPlayerInfoManager *playerinfomanager;
extern CGlobalVars *gpGlobals;

inline int IndexOfEdict(const edict_t *pEdict)
{
	return (int)(pEdict - gpGlobals->pEdicts);
}

inline edict_t *PEntityOfEntIndex(int iEntIndex)
{
	if (iEntIndex >= 0 && iEntIndex < gpGlobals->maxEntities)
	{
		return (edict_t *)(gpGlobals->pEdicts + iEntIndex);
	}
	return NULL;
}
