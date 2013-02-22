/*
 * Copyright (c) 2013 Peter Rowlands. All rights reserved.
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
 * @brief GoonPUG utility functions
 *
 * @author Peter Rowlands <peter@pmrowla.com>
 */

#ifndef _GOONPUG_UTIL_H_
#define _GOONPUG_UTIL_H_

#include <eiface.h>
#include <cstrike15_usermessage_helpers.h>

#include "gp_recipientfilter.h"

class GoonpugMessage
{
public:
    GoonpugMessage();

    bool ChatMsg(GpRecipientFilter filter, const char *msg);
    bool ChatMsg(edict_t *client, const char *fmt, ...);
#define ChatMsgAll(fmt, ...) ChatMsg(NULL, fmt, ##__VA_ARGS__)

    bool HudMsg(GpRecipientFilter filter, const char *msg);
    bool HudMsg(edict_t *client, const char *fmt, ...);
#define HudMsgAll(fmt, ...) HudMsg(NULL, fmt, ##__VA_ARGS__)

private:
    GpRecipientFilter chatFilter(edict_t *client);
};

extern GoonpugMessage g_gpMsg;

#endif // ! _GOONPUG_UTIL_H_
