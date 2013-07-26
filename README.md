GoonPUG
=======

CS:GO competitive PUG plugin

A server running this plugin will alternate between an idle/warmup phase and an actual match.

While waiting for 10 players, the server should be left on some aim/dm type maps.
During the idle phase, all players will respawn automatically.
When enough players have readied up (via /ready), the game will progress to the match phase.

After all players have readied up, the following steps will occur:

1. Vote for the map to play.
2. Vote for team captains.
3. Pick teams.
4. Switch to the match map
5. Wait for all players to load the map and ready up
6. Live on 3
7. Play match
8. Switch back to an aim/dm map and idle


Requirements
------------

- [SourceMod 1.5](http://www.sourcemod.net) - Until an official 1.5 build is released, you should use the most 1.5 (stable branch) snapshot
- [SM cURL](http://forums.alliedmods.net/showthread.php?t=152216)
- [SMJansson](http://forums.alliedmods.net/showthread.php?t=184604)
- [sm-zip](https://github.com/pmrowla/sm-zip)

Please note that the plugin has only been tested on Linux dedicated servers.
In theory everything should also work on Windows servers, but there are no guarantees.


Plugin Installation
-------------------

1.  Install SourceMod and the required extensions.
    Make sure you install both the binaries (`.ext.dll` or `.ext.so`) and include files (`.inc`) for all the extensions.
2.  Extract the contents of the `goonpug_<version>.zip` file into your csgo server folder.
    Everything is properly organized underneath the standard `csgo/` directory.
3.  Compile and install the plugin.
    The plugin has only been tested using the compiler bundled with SM distrubtions, and the web compiler is not supported.

    ```
    cd csgo/addons/sourcemod/scripting
    ./compile.sh goonpug.sp
    cp compiled/goonpug.sp ../plugins/
    ```
4.  Configure your server to work properly with the Steam Workshop.
    Instructions can be found on the [Valve Developer Wiki](https://developer.valvesoftware.com/wiki/CSGO_Workshop_For_Server_Operators#How_to_host_workshop_maps_with_a_CS:GO_dedicated_server).
    Please note that you MUST put your API key in `webapi_authkey.txt` for the plugin to work, even if you run srcds with the `-authkey` command line option.


Map Configuration
-----------------

Map rotations are loaded from the GoonPUG (or user provided) steam workshop map collections.
By default, the plugin will use the following collections:

-   [GoonPUG Match Maps](http://steamcommunity.com/sharedfiles/filedetails/?id=141468891)
-   [GoonPUG Warmup Maps](http://steamcommunity.com/sharedfiles/filedetails/?id=141469710)

Server admins can specify their own map collections to use via cvars (see below).


Plugin Cvars
------------

GoonPUG cvars can be set or overridden in your `sourcemod.cfg` file.

-   `gp_match_map_collection` specifies the workshop map collection file ID to be used for match maps.
    Defaults to `"141468891"` (the ID for the GoonPUG Match Maps collection).
-   `gp_warmup_map_collection` specifies the workshop map collection file ID to be used for match maps.
    Defaults to `"141469710"` (the ID for the GoonPUG Warmup Maps collection).


Server configs
--------------

Two .cfg files are included with GoonPUG and can be found in `csgo/cfg`.
The default values should be sufficient for most users, but they can be customized as necessary.

-   `goonpug_pug.cfg` will be executed for any matches started by the plugin.
    For convenience, this should be the file executed by your gamemodes_server.txt for the Classic Competitive gametype.
-   `goonpug_warmup.cfg` will be executed for any warmup rounds.


User Commands
-------------

All user commands can be prefixed in chat with any one of the `.`, `!` or `/` characters.
They can also be issued in the console by prefixing the command with `sm_`.
For example, to ready up a player could say any one of `.ready`, `!ready` or `/ready` in chat, or the player could use `sm_ready` in his or her console.

-   `.ready` Set yourself as ready.
-   `.notready` Set yourself as not ready.
-   `.unready` Alias for `.notready`.


Admin Commands
--------------

All admin commands require the SM `ADMIN_CHANGEMAP` privilege.
Admin commands can be prefixed with `!` or `/` in chat, or with `sm_` in the console.
Currently, the plugin admin commands do not appear in the `sm_admin` menu.

-   `/lo3` Start a match with the current teams and on the current map.
-   `/endmatch` End the current match.
    Match results and stats will be saved to the GoonPUG server and the GO:TV demo will be saved and uploaded to S3.
-   `/abortmatch` Abort the current match.
    Match results and stats will not be saved and the GO:TV demo will not be uploaded to S3.
-   `/restartmatch` Restart the current match.
    Note that if the match is in the second half, the plugin will swap the teams back to the sides they originally started on.


Stats
-----

The GoonPUG plugin will sync players' statistics (including RWS) with the http://goonpug.com/ web server.


Notes
-----

GO:TV match demos will be automatically recorded and saved if GO:TV is enabled on the server.
Upon conclusion of the match, the GO:TV demo will be automatically compressed into a .zip file and uploaded to an Amazon S3 bucket.
Demos can be accessed via the goonpug web site.


License
-------
GoonPUG is copyright (c) 2013 Peter Rowlands.
GoonPUG is distributed under the GNU General Public License version 3.
See [COPYING.md](https://github.com/goonpug/goonpug/blob/master/COPYING.md) for more information.
