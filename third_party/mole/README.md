# Cleanup engine: Mole

Squeeze's **Clean Up** tab runs the cleanup part of [Mole](https://github.com/tw93/Mole) by tw93 and contributors
(`mo clean`), licensed under GPL-3.0. Squeeze ships it inside `Squeeze.app/Contents/Resources/CleanupEngine` and
runs it as a separate program (`/bin/bash bin/clean.sh`); Squeeze's own code stays MIT.

Squeeze is not Mole and is not affiliated with or endorsed by the Mole project. "Mole" is the Mole project's name;
see its [trademark policy](https://github.com/tw93/Mole/blob/main/TRADEMARK.md).

- Version: V1.62.0, commit `91a7bf44f96995361b10b5a0e9efae36a1490bf9` (pinned in `scripts/build-mole.sh`).
- Files shipped: `bin/` and `lib/` as published, plus `LICENSE`.
- Modification: [`mole-squeeze.patch`](mole-squeeze.patch), two environment variables:
  - `MOLE_EXTRA_WHITELIST_FILE`: extra protected paths (what the user left unticked in Squeeze), added on top of
    the user's own Mole whitelist or Mole's defaults;
  - `MOLE_PREVIEW_FILE`: where the dry-run preview is written, so Squeeze does not overwrite
    `~/.config/mole/clean-list.txt`.

The complete corresponding source is the files in the app bundle themselves (shell scripts), the upstream
repository at the commit above, and the patch in this folder.
