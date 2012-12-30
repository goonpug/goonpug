GoonPUG
=======
CS:GO PUG plugin

Provides a simple way to manage a PUG server.


Overview
========
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


Commands
========
/ready - ready up
/unready - un-ready up


Admin Commands
==============
/lo3 - Force a lo3 and start a match on the current map
/warmup - Force a warmup/idle phase on the current map


Notes
=====
Server demos will automatically be recorded for matches started by the plugin
or /lo3.
