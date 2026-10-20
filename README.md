# Squeeze

[English](README.md) · [Русский](README.ru.md)

**Free disk space on your Mac without deleting anything.** Squeeze compresses folders with the
compression built into APFS: files stay where they are and open as usual, they just take less space on
disk. Example: a 72 GB game folder went down to 38 GB.

Choose a folder, see how much it would save, press **Compress**. Squeeze can also keep folders
compressed when new files appear in them (after an app or game update, for example).

> **Status:** early version. Builds and tests run on every change, but the app has not been tried by
> many people yet. Read [Limitations](#limitations).

## Install

1. Download `Squeeze-<version>.zip` from [Releases](https://github.com/yuran1174/squeeze/releases),
   open it and move `Squeeze.app` to **Applications**.
2. Open Squeeze. The first time, macOS stops it because the app is not signed by a paid Apple
   developer account (see [why](#why-the-macos-warning)). Allow it once:
   - **macOS 15 Sequoia and newer:** close the warning, open **System Settings → Privacy & Security**,
     scroll down to “Squeeze was blocked…”, press **Open Anyway** and confirm with your password.
   - **macOS 13–14:** right-click `Squeeze.app` → **Open** → **Open**.

That's all: nothing else to install. Squeeze appears in the menu bar (it has no Dock icon).

Requirements: macOS 13 or newer, an APFS disk (every Mac from about 2017 on, and most external
drives formatted on a Mac).

<details>
<summary>Terminal alternative to step 2</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Squeeze.app
```
</details>

## How it works

APFS can store a file compressed and decompress it on the fly when it is read. Programs see the same
file with the same size, so nothing has to change in them. The price is a little CPU time when a file is
read; on current Macs it is usually unnoticeable.

Before changing anything, Squeeze **estimates the saving**: it reads a sample of the files and compresses
it in memory the way APFS would.

### What is worth compressing

Large files that are read often but rarely rewritten:

| Compresses well | Barely changes |
| --- | --- |
| Games (Steam games are found automatically) | Photos, video, music |
| Old projects, `node_modules`, build caches you keep | ZIP, DMG and other archives |
| SDKs, toolchains, app data folders | Most AI model weights |
| Text, logs, datasets in CSV/JSON | Files that are rewritten all the time (virtual machine disks, databases) |

When a program rewrites a compressed file, the new version is stored uncompressed. That is why Squeeze
can recompress folders in the background.

## Using the app

- **Add Folder…** or drop a folder onto the list. Squeeze shows the size on disk, the size programs
  see, and how much compression would free.
- **Compress**, **Stop**, **Decompress**. Files are processed in small batches (64 files or 256 MB), so
  stopping never leaves a file half done.
- **Found automatically:** installed Steam games from all libraries, including external drives. Can be
  turned off in settings.
- History of what was compressed and how much it freed, and notifications.

Settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| Keep folders compressed | on | Every 30 minutes, compress new files in folders that are already compressed |
| Only when plugged in | on | No background work on battery |
| Only after N minutes without input | 5 | Wait until you are not using the Mac |
| Only when N MB or more are new | 100 MB | Do not bother for a few small files |
| Show Steam games automatically | on | List installed Steam games |
| Open at login | off | Start Squeeze when you log in |

Settings live in `~/Library/Application Support/Squeeze/settings.json`.

## Safety

- Compression is lossless and reversible; file contents do not change.
- Squeeze does not touch a folder while a program from it is running, and does not touch a Steam game
  while Steam installs or updates it. This is checked before every batch, not only at the start.
- System folders, `/Applications`, whole disks, your home folder, `~/Library`, iCloud Drive and other
  cloud folders are refused.
- Files that cannot be compressed (in use, no permission) are left as they are.
- Before decompressing, Squeeze checks that there is enough free space.

**Undo:** press **Decompress**. The folder returns to its full size, so it needs that much free space.

## Why the macOS warning

Apple shows no warning only for apps signed with a paid Developer ID ($99 a year) and checked by Apple
(notarization). Squeeze is free and not signed that way yet, so macOS asks you to allow it once. The
source code is open, and every release is built from it on GitHub Actions
([build log](https://github.com/yuran1174/squeeze/actions)).

## For Steam players: script without the app

A shell script that does the background part for Steam games, if you prefer launchd to a menu bar app.
It uses the compression tool inside Squeeze.app, or Homebrew's `afsctool`.

```bash
git clone https://github.com/yuran1174/squeeze && cd squeeze
./scripts/squeeze-steam.sh --list              # games, size on disk, how much is compressed
./scripts/squeeze-steam.sh --app 570 --force   # compress one game now (570 = Dota 2)
./scripts/install-agent.sh                     # every 2 hours: compress new files of compressed games
./scripts/install-agent.sh --remove            # remove the background job
```

By default it only touches games that are already more than half compressed, only on AC power and only
when the Mac is idle (`--force` skips the last two). Log: `~/Library/Logs/squeeze.log`.

## Build from source

```bash
git clone https://github.com/yuran1174/squeeze && cd squeeze
./scripts/build-afsctool.sh           # compression tool from its source (needs Homebrew for build tools)
swift test                            # unit tests
UNIVERSAL=1 ./scripts/build-app.sh    # dist/Squeeze.app and zip, Apple Silicon + Intel (needs Xcode)
```

`Sources/SqueezeCore`: scanning, estimates, running the compression tool, Steam libraries, settings.
`Sources/Squeeze`: the SwiftUI menu bar app. Every push is built and tested on GitHub Actions; a tag like
`v0.1.0` publishes a release.

## Limitations

- Only APFS (and HFS+) disks; not exFAT or network drives.
- Some programs or anti-cheat systems dislike files being changed on disk. Contents stay the same, but if
  something misbehaves, decompress that folder.
- The interface is in English for now.

## Roadmap

- App icon; Russian interface.
- Suggestions beyond Steam: other launchers, CrossOver and Whisky bottles, large developer folders.
- Shared data on how well popular games and apps compress.
- Developer ID signing and notarization: no warning on first launch, then a Homebrew cask.

## License and credits

Squeeze is MIT licensed. Compression is done by [afsctool](https://github.com/RJVB/afsctool) by its own
authors, GPL-3 licensed. Squeeze.app includes an unmodified copy built from its published source and runs
it as a separate program; its licenses and the exact source are listed in
`Squeeze.app/Contents/Resources/ThirdParty/afsctool`.
