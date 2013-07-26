GoonPUG
=======

CS:GO competitive PUG plugin


Overview
--------
The server will alternate between an idle/warmup phase and an actual match.

While waiting for 10 players, the server should be left on some aim/dm type
maps. During the idle phase, all players will respawn automatically. When
enough players have readied up (via /ready), the game will progress to the
match phase.

After all players have readied up, the following steps will occur:

1. Vote for the map to play.
2. Vote for team captains.
3. Pick teams.
4. Switch to the match map
5. Wait for all players to load the map and ready up
6. Live on 3
7. Play match
8. Switch back to an aim/dm map and idle


Plugin Installation
-------------------

1. Ensure that [SourceMod](http://www.sourcemod.net) is installed and properly configured on your server.
2. Extract the contents of the goonpug\_\<version\>.zip file into your csgo
   server folder. Everything is properly organized underneath the standard
   csgo/ directory.


Map Configuration
-----------------

Map rotations are loaded from the GoonPUG steam workshop map collections.


Plugin Cvars
------------

GoonPUG cvars should be set in `csgo/cfg/sourcemod/goonpug.cfg`. This file is
automatically created the first time the plugin is loaded, if it does not
already exist.


.cfgs
-----

Two .cfg files are included with GoonPUG and can be found in `csgo/cfg`.
The default values should be sufficient for most users, but they can be
customized as necessary.

`goonpug_pug.cfg`
> loaded for any matches started by the plugin or the
> `/lo3` command.

`goonpug_pug.cfg`
> loaded for any idle/warmup round started by the plugin or the /warmup
> command.


User Commands
-------------

`.ready` \(`sm_ready`\)
> ready up

`.unready` \(`sm_unready`\)
> un-ready up


Admin Commands
--------------

All admin commands require the SM `ADMIN_CHANGEMAP` privilge.

`/lo3` \(`sm_lo3`\)
> force a lo3 and start a match on the current map.

`/endmatch` \(`sm_endmatch`\)
> End the current match and save the results.

`/abortmatch` \(`sm_abortmatch`\)
> Abort the current match and do not save the results.

`/restartmatch` \(`sm_restartmatch`\)
> Restart the current match


Notes
-----

Server demos will automatically be recorded for matches started by the plugin
or `/lo3` if GOTV is running on the server.


License
-------
GoonPUG is distributed under the GNU General Public License version 3. See
[COPYING.md](https://github.com/pmrowla/goonpug/blob/master/COPYING.md) for
more information.
