# Top Shelf

A small Mac app that turns the MacBook notch into a shelf: now playing, next event, weather, a files tray,
clipboard history and Claude Code session status. Screens without a notch get a capsule at the top center.

Author: John Hesch.

## Building

Builds run on GitHub Actions only (manual trigger): `scripts/cloud-build.sh`. Debug builds carry a self-test
(`--selftest`) and draw every shelf state off screen (`--shots <dir>`).

## Credits

Now Playing on macOS 15.4 and later works by loading a small helper into `/usr/bin/perl`, a system program
that may still read the system Now Playing service. The technique comes from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD 3-Clause); the helper here is
written from scratch.
