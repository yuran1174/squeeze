#!/bin/bash
# Builds afsctool from its published source, for Apple Silicon and Intel, so it can ship inside Squeeze.app.
# afsctool is GPL-3 software by its authors (https://github.com/RJVB/afsctool); Squeeze runs it as a separate
# program. The result goes to build/afsctool/: the binary, the licenses and SOURCE.txt saying where the
# exact source came from.
#
# Needs: Xcode or Command Line Tools, Homebrew (for cmake, pkgconf and google-sparsehash, build time only).
set -euo pipefail
cd "$(dirname "$0")/.."

AFSCTOOL_VERSION=1.7.3
AFSCTOOL_URL="https://github.com/RJVB/afsctool/archive/refs/tags/v$AFSCTOOL_VERSION.tar.gz"
AFSCTOOL_SHA=5776ff5aaf05c513bead107536d9e98e6037019a0de8a1435cc9da89ea8d49b8
LZFSE_COMMIT=e634ca58b4821d9f3d560cdc6df5dec02ffc93fd
LZFSE_URL="https://github.com/lzfse/lzfse/archive/$LZFSE_COMMIT.tar.gz"
LZFSE_SHA=ca98aa6644d44500e3315858daa747ce15bd06d49e3edb12a5458e5525e8ebdb

OUT=build/afsctool
WORK=build/afsctool-src
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT/licenses" "$WORK"

for dep in cmake pkgconf google-sparsehash; do
  brew list --formula "$dep" >/dev/null 2>&1 || brew install "$dep"
done

fetch() { # url sha file
  curl -fsSL "$1" -o "$3"
  echo "$2  $3" | shasum -a 256 -c -
}
fetch "$AFSCTOOL_URL" "$AFSCTOOL_SHA" "$WORK/afsctool.tar.gz"
fetch "$LZFSE_URL" "$LZFSE_SHA" "$WORK/lzfse.tar.gz"

mkdir -p "$WORK/afsctool"
tar -xzf "$WORK/afsctool.tar.gz" -C "$WORK/afsctool" --strip-components 1
mkdir -p "$WORK/afsctool/src/private/lzfse"
tar -xzf "$WORK/lzfse.tar.gz" -C "$WORK/afsctool/src/private/lzfse" --strip-components 1

cmake -S "$WORK/afsctool" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
cmake --build "$WORK/build" --target afsctool

cp "$WORK/build/afsctool" "$OUT/afsctool"
strip -x "$OUT/afsctool" || true

# licenses of afsctool and of the code it includes
( cd "$WORK/afsctool" && find . -maxdepth 4 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) ) | while read -r f; do
  name=$(echo "${f#./}" | tr '/' '_')
  cp "$WORK/afsctool/$f" "$OUT/licenses/$name"
done

cat >"$OUT/SOURCE.txt" <<EOF
afsctool $AFSCTOOL_VERSION — free software under the GNU General Public License v3.
Squeeze runs it as a separate program; Squeeze itself is MIT licensed.

Source of this exact build:
  $AFSCTOOL_URL
  sha256 $AFSCTOOL_SHA
  with lzfse $LZFSE_URL
  sha256 $LZFSE_SHA

Built for arm64 and x86_64 by scripts/build-afsctool.sh in https://github.com/yuran1174/squeeze
EOF

echo "afsctool built: $OUT/afsctool ($(lipo -archs "$OUT/afsctool"))"
"$OUT/afsctool" 2>&1 | head -3 || true
