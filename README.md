# Squeeze

> Work in progress — first version, not built or released yet.

Squeeze frees disk space on macOS with **APFS transparent compression**: files stay where they are and
open as usual, but take less space on disk. Example: Dota 2 went from 72 GB to 38 GB.

It is a CompactGUI-like tool for the Mac, focused on games: it finds your Steam games, shows how much
compression would save, compresses with one click, and **keeps games compressed after updates**
(updates write new files uncompressed).

Compression itself is done by [afsctool](https://formulae.brew.sh/formula/afsctool) (GPL, installed
separately with `brew install afsctool`; Squeeze does not bundle it).

## Right now: background script for Steam games

```bash
brew install afsctool
git clone https://github.com/yuran1174/squeeze && cd squeeze
./scripts/squeeze-steam.sh --list        # games, size on disk, how much is compressed
./scripts/squeeze-steam.sh --app 570 --force   # compress one game now (570 = Dota 2)
./scripts/install-agent.sh               # every 2 hours, on AC power and idle: compress new files of compressed games
./scripts/install-agent.sh --remove      # remove the background job
```

A game is never touched while it is running or while Steam installs or updates it.
Log: `~/Library/Logs/squeeze.log`. Undo compression of a folder: `afsctool -d <folder>`.

## Menu bar app (in progress)

Swift package, macOS 13+: `Sources/SqueezeCore` (Steam libraries, scanning, estimates, afsctool) and
`Sources/Squeeze` (SwiftUI menu bar app). Build: `./scripts/build-app.sh` → `dist/Squeeze.app`.

License: MIT.
