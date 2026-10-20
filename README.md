# Squeeze

[English](README.md) · [Русский](README.ru.md)

Squeeze frees disk space on macOS with **APFS transparent compression**. Files stay where they are and
open as usual, but take less space on disk. Example: Dota 2 went from 72 GB to 38 GB.

It is a CompactGUI-like tool for the Mac, focused on games. It finds your Steam games, shows how much
compression would save, compresses with one click, and **keeps games compressed after updates**
(a game update writes new files uncompressed).

> **Status:** early version. The code is written, but the app has only just started to be built and
> tested automatically. Expect rough edges and read [Limitations](#limitations).

## How it works

APFS can store a file compressed and decompress it on the fly when it is read. Programs see the same
file with the same size, so games keep working with no changes. You pay with a little CPU when the file
is read; on modern Macs this is usually not noticeable, and loading from a compressed file can even be
faster on a slow disk.

Squeeze does not implement compression itself. It runs [afsctool](https://formulae.brew.sh/formula/afsctool)
(LZFSE), installed by Homebrew. afsctool is GPL-3 licensed, so Squeeze does not bundle it and only calls
the copy you installed. Squeeze's own code is MIT.

Before compressing, Squeeze can **estimate the saving** without changing anything: it reads a sample of
the files and compresses it in memory in 64 KiB blocks, the way APFS does. Games full of already
compressed video or archives save little; others save a lot.

## Install

1. Install afsctool:

   ```bash
   brew install afsctool
   ```

2. Get the app: download `Squeeze-<version>.zip` from the
   [Releases](https://github.com/yuran1174/squeeze/releases) page (or the latest build from the
   [Actions](https://github.com/yuran1174/squeeze/actions) page), unzip it and move `Squeeze.app` to
   Applications. Or build it yourself (below).

3. **First launch.** The app is signed ad hoc, not with an Apple Developer ID, so macOS warns about an
   unknown developer. Either right-click `Squeeze.app` → **Open** → **Open**, or run once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Squeeze.app
   ```

Squeeze lives in the menu bar and has no Dock icon.

Requirements: macOS 13 or newer, an APFS disk (every Mac since 2017 or so).

## The menu bar app

- A list of your Steam games (all libraries, including external drives) and any folders you add, with
  size on disk, size as apps see it, and an estimated saving.
- **Compress**, **Decompress** and **Stop** buttons with progress. Files are processed in small batches
  (64 files or 256 MB), so stopping never interrupts a file in the middle.
- **Keep compressed after updates**: every 30 minutes Squeeze looks for new uncompressed files in games
  and folders you already compressed, and compresses them.
- History of what was compressed and how much space it freed, plus notifications.

Settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| Compress after updates | on | Background work for items that were already compressed |
| Only on AC power | on | Do not run background work on battery |
| Only after N minutes idle | 5 | Wait until you stop using the Mac |
| New data threshold | 100 MB | Do not bother until this much new data appeared |
| Launch at login | off | Start Squeeze when you log in |

Settings are stored in `~/Library/Application Support/Squeeze/settings.json`.

## The background script (no app needed)

```bash
git clone https://github.com/yuran1174/squeeze && cd squeeze
./scripts/squeeze-steam.sh --list              # games, size on disk, how much is compressed
./scripts/squeeze-steam.sh --app 570 --force   # compress one game now (570 = Dota 2)
./scripts/squeeze-steam.sh --all --force       # compress every installed game
./scripts/install-agent.sh                     # every 2 hours: compress new files of compressed games
./scripts/install-agent.sh --remove            # remove the background job
```

By default the script only touches games that are already more than half compressed, only on AC power,
and only while the Mac is idle. `--force` skips the power and idle checks. Log:
`~/Library/Logs/squeeze.log`.

## Safety

- A game is **never touched while it is running or while Steam is installing or updating it**. This is
  checked before every batch, not only at the start.
- Squeeze refuses system folders, `/Volumes` itself, your home folder, `~/Library`, and iCloud Drive or
  other cloud-synced folders.
- Compression is lossless and reversible. Files that afsctool cannot compress (in use, no permission)
  are left as they are.
- Decompression checks that there is enough free space first.

### Undo compression

In the app press **Decompress**, or in Terminal:

```bash
afsctool -d "/path/to/folder"
```

Make sure you have enough free space: the folder returns to its full size.

## Build from source

```bash
git clone https://github.com/yuran1174/squeeze && cd squeeze
swift test                            # unit tests (real compression tests need afsctool)
./scripts/build-app.sh                # dist/Squeeze.app and a zip, native architecture
UNIVERSAL=1 ./scripts/build-app.sh    # Apple Silicon + Intel (needs full Xcode)
```

Swift package for macOS 13+: `Sources/SqueezeCore` (Steam libraries, scanning, estimates, afsctool,
settings) and `Sources/Squeeze` (the SwiftUI menu bar app). Every push is built and tested on
GitHub Actions (`.github/workflows/build.yml`); a tag like `v0.1.0` publishes a release.

## Limitations

- Compression helps files that compress. Video, audio and already packed archives barely change.
- Updates and verification by Steam write files uncompressed; Squeeze compresses them again later.
- Some games, anti-cheat systems or launchers dislike modified files. Compression does not change file
  contents, but if a game misbehaves, decompress it.
- Only Steam games and folders you add by hand are supported for now.
- The app is not notarized (see [Install](#install)).

## Roadmap

- App icon.
- English / Russian interface switch.
- Shared database of how well each game compresses.
- Other launchers; CrossOver and Whisky bottles.
- Homebrew cask that depends on `afsctool`.
- Apple Developer signing and notarization.

## License

MIT. afsctool is a separate program under GPL-3 and is not part of this repository.
