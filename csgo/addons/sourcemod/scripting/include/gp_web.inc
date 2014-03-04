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
 * GoonPUG Web API module
 *
 * Author: Peter "astroman" Rowlands <peter@pmrowla.com>
 */

new Handle:hWebApiEnabled = INVALID_HANDLE;
new Handle:hWebApiUrl = INVALID_HANDLE;

GpWeb_Init()
{
    hWebApiEnabled = CreateConVar("gp_web_api_enabled", "0",
            "Use GoonPUG Web API for stats", FCVAR_PLUGIN | FCVAR_SPONLY);
    hWebApiUrl = CreateConVar("gp_web_api_url", "http://goonpug.com/api",
            "GoonPUG Web API URL", FCVAR_PLUGIN | FCVAR_SPONLY);
}

GpWeb_Fini()
{
    if (hWebApiEnabled != INVALID_HANDLE)
        CloseHandle(hWebApiEnabled);
    if (hWebApiUrl != INVALID_HANDLE)
        CloseHandle(hWebApiUrl);
}

bool:GpWeb_Enabled()
{
    if (hWebApiEnabled == INVALID_HANDLE)
        return false;

    new enabled = GetConVarInt(hWebApiEnabled);
    if (0 == enabled)
        return false;
    else
        return true;
}

Float:GpWeb_FetchPlayerRating(const String:auth[])
{
    if (GpWeb_Enabled())
    {
        // TODO
        return 0.0;
    }
    else
    {
        return 0.0;
    }
}
