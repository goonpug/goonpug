/* Copyright (c) 2014 Astroman Technologies LLC
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
 * GoonPUG TrueSkill module
 *
 * Author: Peter "astroman" Rowlands <peter@pmrowla.com>
 */

new Handle:hGpSkillEnabled = INVALID_HANDLE;
new Handle:hGpSkillConn = INVALID_HANDLE;

GpSkill_Init()
{
    hGpSkillEnabled = CreateConVar("gp_skill_enabled", "0",
            "Use GoonPUG trueskill implementation", FCVAR_PLUGIN | FCVAR_SPONLY);
}

GpSkill_Fini()
{
    if (hGpSkillEnabled != INVALID_HANDLE)
        CloseHandle(hGpSkillEnabled);
    if (hGpSkillConn != INVALID_HANDLE)
        CloseHandle(hGpSkillConn);
}

bool:GpSkill_Enabled()
{
    if (hGpSkillEnabled == INVALID_HANDLE)
        return false;

    new enabled = GetConVarInt(hGpSkillEnabled);
    if (0 == enabled)
        return false;
    else
        return true;
}

Float:GpSkill_FetchPlayerRating(const String:auth[])
{
    decl String:error[512];
    if (GpSkill_Enabled())
    {
        if (hGpSkillConn == INVALID_HANDLE)
        {
            hGpSkillConn = SQL_Connect("gpskill", true, error, sizeof(error));
            if (hGpSkillConn == INVALID_HANDLE)
            {
                LogError("Could not connect to gpskill db: %s", error);
                return 0.0;
            }
        }

        decl String:query[512];
        Format(query, sizeof(query), "SELECT rating, variance FROM gpskill WHERE steam_id = '%s'", auth);
        new Handle:hResult = SQL_Query(hGpSkillConn, query);

        new Float:conservativeRating = 0.0;
        if (SQL_FetchRow(hResult))
        {
            new Float:rating = SQL_FetchFloat(hResult, 0);
            new Float:variance = SQL_FetchFloat(hResult, 1);
            conservativeRating = rating - 3.0 * variance;
            if (conservativeRating < 0.0)
                conservativeRating = 0.0;
        }
        CloseHandle(hResult);
        return conservativeRating;
    }
    else
    {
        return 0.0;
    }
}
