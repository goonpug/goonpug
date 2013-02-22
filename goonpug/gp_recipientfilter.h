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

#ifndef _GOONPUG_RECIPIENT_FILTER_H_
#define _GOONPUG_RECIPIENT_FILTER_H_

#include <irecipientfilter.h>
#include <tier1/utlvector.h>

class GpRecipientFilter : public IRecipientFilter
{
public:
    GpRecipientFilter();
    GpRecipientFilter(const GpRecipientFilter &other);

    virtual bool IsReliable() const;
    virtual bool IsInitMessage() const;
    virtual void MakeReliable();
    virtual void RemoveAllRecipients();
    virtual int GetRecipientCount() const;
    virtual int GetRecipientIndex(int slot) const;
    void AddAllPlayers();
    void AddPlayer(int index);

private:
    bool reliable;
    bool initMessage;
    CUtlVector<int> recipients;
};

#endif // _GOONPUG_RECIPIENT_FILTER_H_
