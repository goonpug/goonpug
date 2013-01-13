GoonPUG
=======

CS:GO competitive PUG plugin

GoonPUG consists of two parts:

1. The Sourcemod PUG plugin

2. The stats tracking daemon and web application (optional)


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

If the stats module is enabled, live match stats will be tracked and players
will be ranked by an RWS score.


Plugin Installation
-------------------

1. Ensure that [SourceMod](http://www.sourcemod.net) is installed and properly configured on your server.

2. Extract the contents of the goonpug\_\<version\>.zip file into your csgo
   server folder. Everything is properly organized underneath the standard
   csgo/ directory.

3. Configure your maplists

4. Configure your match and idle configs \(optional\).


Map Configuration
-----------------

Map rotations are configured in files found in
`csgo/addons/sourcemod/configs`. Any maps found in `goonpug_idle_maplist.txt`
will be randomly selected for warmup/idle rounds. Any maps found in
`goonpug_match_maplist.txt` will be used in the votemap list when selecting a
match map. You must also configure your standard sourcemod `maplists.txt` file.
See the `maplists.txt.example` file included with GoonPUG for more information.


Plugin Cvars
------------

GoonPUG cvars should be set in `csgo/cfg/sourcemod/goonpug.cfg`. This file is
automatically created the first time the plugin is loaded, if it does not
already exist.

`gp_max_pug_players`
> sets the number of players required for a PUG match \(Defaults to 10\).

`gp_idle_dm`
> if enabled, players will automatically respawn deathmatch-style during
> warmup/idle rounds. \(Disabled by default\)


.cfgs
-----

Two .cfg files are included with GoonPUG and can be found in `csgo/cfg`.
The default values should be sufficient for most users, but they can be
customized as necessary.

`goonpug_match.cfg`
> loaded for any matches started by the plugin or the
> `/lo3` command.
> *Note: `goonpug_match.cfg` is based on the ESL 5on5 cfg, version 0.0.6
> \(17.09.2012\).*

`goonpug_warmup.cfg`
> loaded for any idle/warmup round started by the plugin or the /warmup
> command.


User Commands
-------------

`/ready` \(`sm_ready`\)
> ready up

`/unready` \(`sm_unready`\)
> un-ready up


Admin Commands
--------------

`/lo3` \(`sm_lo3`\)
> force a lo3 and start a match on the current map. *Requires the SM
> ADMIN_CHANGEMAP privilege.*

`/warmup` \(`sm_warmup`\)
> force a warmup/idle phase on the current map. *Requires the SM
> ADMIN_CHANGEMAP privilege.*


Notes
-----

Server demos will automatically be recorded for matches started by the plugin
or `/lo3` if GOTV is running on the server.


License
-------
GoonPUG is distributed under the GNU General Public License version 3. See
[LICENSE.md](https://github.com/pmrowla/goonpug/blob/master/LICENSE.md) for
more information.
