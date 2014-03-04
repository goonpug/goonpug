/* Copyright (c) 2013 Astroman Technologies LLC
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
 * GoonPUG team management module
 *
 * Author: Peter "astroman" Rowlands <peter@pmrowla.com>
 */

#define STEAMID_LEN 32

#define CS_TEAM_CT_FIRST 1
#define CS_TEAM_T_FIRST 2
enum GpTeam
{
    GP_TEAM_NONE = 0,
    GP_TEAM_1 = CS_TEAM_CT_FIRST,
    GP_TEAM_2 = CS_TEAM_T_FIRST,
};


new Handle:hTeam1 = INVALID_HANDLE;
new Handle:hTeam2 = INVALID_HANDLE;


/**
 * Initialize the GpTeam module
 */
GpTeam_Init()
{
    hTeam1 = CreateArray(STEAMID_LEN);
    hTeam2 = CreateArray(STEAMID_LEN);
}

/**
 * Finalize the GpTeam module
 */
GpTeam_Fini()
{
    if (hTeam1 != INVALID_HANDLE)
        CloseHandle(hTeam1);
    if (hTeam2 != INVALID_HANDLE)
        CloseHandle(hTeam2 );
}

/**
 * Force all players to the spectator team
 */
GpTeam_ForceAllSpec()
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsValidPlayer(i) && !IsFakeClient(i))
        {
            GpTeam_AssignPlayerTeam(i, GP_TEAM_NONE);
        }
    }
}

/**
 * Assign a player to the specified team
 *
 *  @param client the player's client index
 *  @param team the GpTeam the player should be assigned to
 *  @param changeTeam true if ChangeClientTeam() should also be called
 */
GpTeam_AssignPlayerTeam(client, GpTeam:team, bool:changeTeam=true)
{
    if (IsValidPlayer(client))
    {
        decl String:auth[STEAMID_LEN];
        GetClientAuthString(client, auth, sizeof(auth));

        decl index;
        if (team == GP_TEAM_1)
        {
            index = FindStringInArray(hTeam2, auth);
            if (index >= 0)
                RemoveFromArray(hTeam2, index);
            index = FindStringInArray(hTeam1, auth);
            if (index < 0)
                PushArrayString(hTeam1, auth);
        }
        else if (team == GP_TEAM_2)
        {
            index = FindStringInArray(hTeam1, auth);
            if (index >= 0)
                RemoveFromArray(hTeam1, index);
            index = FindStringInArray(hTeam2, auth);
            if (index < 0)
                PushArrayString(hTeam2, auth);
        }
        else
        {
            index = FindStringInArray(hTeam1, auth);
            if (index >= 0)
                RemoveFromArray(hTeam1, index);
            index = FindStringInArray(hTeam2, auth);
            if (index >= 0)
                RemoveFromArray(hTeam2, index);
        }

        if (changeTeam)
            GPChangeClientTeam(client, team);
    }
}
