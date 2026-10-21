#!/bin/bash
# Fetches the cleanup engine (Mole's `mo clean`, GPL-3) at a pinned commit, applies Squeeze's small patch
# and puts it in build/mole/: engine/ (bin/, lib/), LICENSE, SOURCE.txt and the patch.
# See third_party/mole/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

MOLE_TAG=V1.62.0
MOLE_COMMIT=91a7bf44f96995361b10b5a0e9efae36a1490bf9
MOLE_REPO=https://github.com/tw93/Mole

OUT=build/mole
SRC=build/mole-src
rm -rf "$OUT" "$SRC"
git clone --quiet --depth 1 --branch "$MOLE_TAG" "$MOLE_REPO" "$SRC"
got=$(git -C "$SRC" rev-parse HEAD)
if [ "$got" != "$MOLE_COMMIT" ]; then
  echo "Mole $MOLE_TAG is $got, expected $MOLE_COMMIT" >&2
  exit 1
fi

mkdir -p "$OUT/engine"
cp -R "$SRC/bin" "$SRC/lib" "$OUT/engine/"
(cd "$OUT/engine" && patch -p1 --forward --quiet) < third_party/mole/mole-squeeze.patch
find "$OUT/engine" -name '*.sh' -print0 | xargs -0 -n1 bash -n
cp "$SRC/LICENSE" "$OUT/LICENSE"
cp third_party/mole/mole-squeeze.patch third_party/mole/README.md "$OUT/"
cat >"$OUT/SOURCE.txt" <<EOF
Cleanup engine: Mole $MOLE_TAG by tw93 and contributors — GNU General Public License v3.
Squeeze runs it as a separate program; Squeeze itself is MIT licensed.
Squeeze is not affiliated with or endorsed by the Mole project.

Source: $MOLE_REPO at commit $MOLE_COMMIT
Changes: mole-squeeze.patch (two environment variables, see README.md)
Built by scripts/build-mole.sh in https://github.com/yuran1174/squeeze
EOF
rm -rf "$SRC"
echo "cleanup engine ready: $OUT/engine (Mole $MOLE_TAG, patched)"
