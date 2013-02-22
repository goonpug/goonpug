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
 * @brief GoonPUG recipient filter interface
 *
 * @author Peter Rowlands <peter@pmrowla.com>
 */

#include <eiface.h>
#include <iplayerinfo.h>

#include "goonpug.h"
#include "gp_recipientfilter.h"

GpRecipientFilter::GpRecipientFilter()
{
    reliable = false;
    initMessage = false;
}

GpRecipientFilter::GpRecipientFilter(const GpRecipientFilter &other)
{
    reliable = other.IsReliable();
    initMessage = other.IsInitMessage();

    for (int i = 0; i < other.GetRecipientCount(); i++)
    {
        int index = other.GetRecipientIndex(i);
        if (index >= 0)
        {
            AddPlayer(index);
        }
    }
}

bool GpRecipientFilter::IsReliable() const
{
    return reliable;
}

bool GpRecipientFilter::IsInitMessage() const
{
    return initMessage;
}

void GpRecipientFilter::MakeReliable()
{
    reliable = true;
}

void GpRecipientFilter::RemoveAllRecipients()
{
    recipients.RemoveAll();
}

int GpRecipientFilter::GetRecipientCount() const
{
    return recipients.Count();
}

int GpRecipientFilter::GetRecipientIndex(int slot) const
{
    if (slot < 0 || slot >= GetRecipientCount())
    {
        return -1;
    }

    return recipients[slot];
}

void GpRecipientFilter::AddAllPlayers()
{
    for (int i = 1; i <= MAX_CLIENTS; i++)
    {
        edict_t *player = PEntityOfEntIndex(i);
        if (!player || player->IsFree())
        {
            continue;
        }

        IPlayerInfo *playerInfo = playerinfomanager->GetPlayerInfo(player);
        if (!playerInfo || playerInfo->IsConnected())
        {
            continue;
        }
        else if (playerInfo->IsHLTV() || strcmp (playerInfo->GetNetworkIDString(), "BOT") == 0)
        {
            continue;
        }

        recipients.AddToTail(i);
    }
}

void GpRecipientFilter::AddPlayer(int index)
{
    recipients.AddToTail(index);
}
