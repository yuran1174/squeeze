#!/bin/bash
# Builds dist/Squeeze.app and dist/Squeeze-<version>.zip (ad-hoc signed).
#   ./scripts/build-app.sh               native architecture (Command Line Tools are enough)
#   UNIVERSAL=1 ./scripts/build-app.sh   Apple Silicon + Intel (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$( (git describe --tags --abbrev=0 2>/dev/null || true) | sed 's/^v//')}"
VERSION="${VERSION:-0.1.0}"
ARCHS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Squeeze"
APP=dist/Squeeze.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Squeeze"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist >"$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent Squeeze.app "Squeeze-$VERSION.zip")
echo "Built dist/Squeeze.app and dist/Squeeze-$VERSION.zip"
