# Squeeze

[English](README.md) · [Русский](README.ru.md)

**Free disk space on your Mac without deleting anything.** Squeeze lists your programs by size, shows how
much each one would shrink, and compresses it with the compression built into APFS. Programs stay where
they are and work as usual; they just take less space on disk. Example: a 72 GB game went down to 38 GB.

Squeeze finds a program's folders by itself: the app, its data in `~/Library/Application Support`, and
known extras such as Xcode device support files or the Android SDK. Steam games are listed one by one.
Any other folder can be added by hand.

> **Status:** early version. Builds and tests run on every change, but the app has not been tried by
> many people yet. Read [Limitations](#limitations).

## Install

1. Download **`Squeeze-<version>.zip`** from [Releases](https://github.com/yuran1174/squeeze/releases)
   (under “Assets”; not “Source code”), open it and move `Squeeze.app` to **Applications**.
2. Open Squeeze. The first time, macOS stops it because the app is not signed by a paid Apple
   developer account (see [why](#why-the-macos-warning)). Allow it once:
   - **macOS 15 Sequoia and newer:** close the warning, open **System Settings → Privacy & Security**,
     scroll down to “Squeeze was blocked…”, press **Open Anyway** and confirm with your password.
   - **macOS 13–14:** right-click `Squeeze.app` → **Open** → **Open**.

Nothing else to install. Squeeze opens a window with your programs and also lives in the menu bar.

Requirements: macOS 13 or newer, an APFS disk (every Mac from about 2017 on).

<details>
<summary>Terminal alternative to step 2</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Squeeze.app
```
</details>

## Using it

1. Open Squeeze. It measures every program: size on disk and **how much compression would free**
   (it compresses a sample in memory; nothing is changed yet). Sort by any column, search by name.
2. Press **Compress** next to a program. Progress is shown in the row and in the menu bar.
3. **Decompress** returns a program to its original size.

Two things macOS may ask for:

- **App Management.** macOS protects programs from being changed by other apps. The first time you
  compress a program, Squeeze shows a button that opens **Privacy & Security → App Management**; turn on
  Squeeze there once.
- **Administrator password.** Programs from the App Store (Xcode, Pages…) and some installers belong to
  the system. Their button is **Compress…**, and macOS asks for your password once per compression.

Squeeze keeps compressed programs compressed: updates write new files uncompressed, so every 30 minutes
(on power, while you are away) it compresses the new files. Programs that need a password are not touched
in the background. The menu bar shows what is happening and what is kept compressed.

### What compresses well

| Compresses well | Barely changes |
| --- | --- |
| Games, game engines, Xcode, Android SDK | Photos, video, music |
| Big apps (Adobe, office suites, IDEs) | ZIP, DMG and other archives |
| Old projects, `node_modules` you keep | Most AI model weights |
| Text, logs, datasets in CSV/JSON | Files rewritten all the time (virtual machine disks, databases) |

In app data folders, caches, databases and logs are skipped: programs rewrite them all the time.

## Settings

In the menu bar → Settings.

| Setting | Default | Meaning |
| --- | --- | --- |
| Keep programs compressed | on | Every 30 minutes, compress new files of what is already compressed |
| Only when plugged in | on | No background work on battery |
| Only after N min without input | 5 | Wait until you are not using the Mac |
| Only when N MB or more are new | 100 MB | Do not bother for a few small files |
| Show Steam games | on | List installed Steam games |
| Open at login | off | Start Squeeze when you log in (in the menu bar only, no window) |

Settings live in `~/Library/Application Support/Squeeze/settings.json`.

## Safety

- Compression is lossless and reversible; file contents and code signatures stay valid (checked on
  every build with a compressed copy of a real signed app).
- A program is not touched while it is open; a Steam game is not touched while Steam installs or updates
  it. This is checked before every batch, not only at the start.
- Files are processed in small batches (64 files or 256 MB), so stopping never leaves a file half done.
- System folders, whole disks, your home folder, `~/Library`, iCloud Drive and other cloud folders can't be
  added as folders.
- Before decompressing, Squeeze checks that there is enough free space.

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

## Build from source

```bash
git clone https://github.com/yuran1174/squeeze && cd squeeze
./scripts/build-afsctool.sh           # compression tool from its source (needs Homebrew for build tools)
swift test                            # unit tests
UNIVERSAL=1 ./scripts/build-app.sh    # dist/Squeeze.app and zip, Apple Silicon + Intel (needs Xcode)
```

`Sources/SqueezeCore`: finding programs and their folders, scanning, estimates, running the compression
tool (also with admin rights), Steam libraries, settings. `Sources/Squeeze`: the SwiftUI app. Every push is
built and tested on GitHub Actions; a tag like `v0.2.0` publishes a release.

## Limitations

- Only APFS (and HFS+) disks; not exFAT or network drives.
- Data of sandboxed App Store apps (`~/Library/Containers`) is protected by macOS and left alone.
- Some programs or anti-cheat systems dislike files being changed on disk. Contents stay the same, but if
  something misbehaves, decompress it.
- The interface is in English for now.

## Roadmap

- App icon; Russian interface.
- More launchers (Epic, Battle.net), CrossOver and Whisky bottles.
- Shared data on how well popular programs compress.
- Developer ID signing and notarization: no warning on first launch, then a Homebrew cask.

## License and credits

Squeeze is MIT licensed. Compression is done by [afsctool](https://github.com/RJVB/afsctool) by its own
authors, GPL-3 licensed. Squeeze.app includes an unmodified copy built from its published source and runs
it as a separate program; its licenses and the exact source are listed in
`Squeeze.app/Contents/Resources/ThirdParty/afsctool`.
