#!/bin/bash
# Builds dist/Squeeze.app and dist/Squeeze-<version>.zip (ad-hoc signed).
#   ./scripts/build-app.sh               native architecture (Command Line Tools are enough)
#   UNIVERSAL=1 ./scripts/build-app.sh   Apple Silicon + Intel (needs full Xcode)
# If build/afsctool/afsctool exists (scripts/build-afsctool.sh), it is put inside the app,
# so users do not have to install anything else.
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
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

if [ -x build/afsctool/afsctool ]; then
  mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty/afsctool"
  cp build/afsctool/afsctool "$APP/Contents/Helpers/afsctool"
  cp -R build/afsctool/licenses build/afsctool/SOURCE.txt "$APP/Contents/Resources/ThirdParty/afsctool/"
  codesign --force --sign - --identifier io.github.yuran1174.squeeze.afsctool "$APP/Contents/Helpers/afsctool"
  echo "afsctool included"
else
  echo "afsctool not included (run scripts/build-afsctool.sh first); the app will look for a Homebrew copy"
fi

codesign --force --sign - "$APP"
(cd dist && ditto -c -k --keepParent Squeeze.app "Squeeze-$VERSION.zip")
echo "Built dist/Squeeze.app and dist/Squeeze-$VERSION.zip"
