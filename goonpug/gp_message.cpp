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

#include <stdarg.h>
#include <string.h>
#include <eiface.h>
#include <cstrike15_usermessage_helpers.h>

#include "goonpug.h"
#include "gp_message.h"
#include "gp_recipientfilter.h"

/**
 * Global GoonpugMessage singleton
 */
GoonpugMessage g_gpMsg;

/**
 * Construct a GoonpugMessage
 */
GoonpugMessage::GoonpugMessage()
{
}

/**
 * Send a chat message.
 */
bool GoonpugMessage::ChatMsg(GpRecipientFilter filter, const char *buf)
{
    CCSUsrMsg_SayText *msg = (CCSUsrMsg_SayText *)g_Cstrike15UsermessageHelpers.GetPrototype(CS_UM_SayText)->New();
    if (msg == NULL)
    {
        return false;
    }

    msg->set_ent_idx(0);
    msg->set_text(buf);
    msg->set_chat(true);
    engine->SendUserMessage(filter, CS_UM_SayText, *msg);
    delete msg;
    
    return true;
}

/**
 * Send a chat message to the specified client.
 */
bool GoonpugMessage::ChatMsg(edict_t *client, const char *fmt, ...)
{
    char *newfmt = (char *)malloc(strlen(fmt) + 3);
    va_list argp;

    va_start(argp, fmt);

    if (newfmt == NULL)
    {
        return false;
    }
    strcat(newfmt, "\1\n");
    char buf[GP_MSG_LEN];
    int len = vsnprintf(buf, sizeof(buf), newfmt, argp);
    if (len >= GP_MSG_LEN)
    {
        buf[GP_MSG_LEN - 1] = '\0';
    }
    free(newfmt);
    GpRecipientFilter filter = chatFilter(client);

    return ChatMsg(filter, buf);
}

/**
 * Send a center text message.
 */
bool GoonpugMessage::HudMsg(GpRecipientFilter filter, const char *buf)
{
    CCSUsrMsg_HudMsg *msg = (CCSUsrMsg_HudMsg *)g_Cstrike15UsermessageHelpers.GetPrototype(CS_UM_HudMsg)->New();
    if (msg == NULL)
    {
        return false;
    }

    msg->set_text(buf);
    engine->SendUserMessage(filter, CS_UM_HudMsg, *msg);
    delete msg;

    return true;
}

/**
 * Send a center text message to the specified client.
 */
bool GoonpugMessage::HudMsg(edict_t *client, const char *fmt, ...)
{
    char *newfmt = (char *)malloc(strlen(fmt) + 3);
    va_list argp;

    va_start(argp, fmt);

    if (newfmt == NULL)
    {
        return false;
    }
    strcat(newfmt, "\1\n");
    char buf[GP_MSG_LEN];
    int len = vsnprintf(buf, sizeof(buf), newfmt, argp);
    if (len >= GP_MSG_LEN)
    {
        buf[GP_MSG_LEN - 1] = '\0';
    }
    free(newfmt);
    GpRecipientFilter filter = chatFilter(client);

    return HudMsg(filter, buf);
}

GpRecipientFilter GoonpugMessage::chatFilter(edict_t *client)
{
    GpRecipientFilter filter;

    filter.MakeReliable();
    if (client == NULL)
    {
        filter.AddAllPlayers();
    }
    else
    {
        filter.AddPlayer(IndexOfEdict(client));
    }

    return filter;
}
