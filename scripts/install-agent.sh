#!/bin/bash
# Installs the background job (a launchd agent) that keeps compressed Steam games compressed after updates.
# It runs squeeze-steam.sh every 2 hours; the script itself waits for AC power and an idle Mac.
#
#   ./scripts/install-agent.sh            install or update
#   ./scripts/install-agent.sh --remove   remove the job (compressed files stay compressed)
set -eu

LABEL=io.github.yuran1174.squeeze.steam
DIR="$HOME/Library/Application Support/Squeeze"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [ "${1:-}" = "--remove" ]; then
  rm -f "$PLIST" "$DIR/squeeze-steam.sh"
  echo "Removed. Already compressed files stay compressed; to undo compression run: afsctool -d <folder>"
  exit 0
fi

command -v afsctool >/dev/null || [ -x /opt/homebrew/bin/afsctool ] || [ -x /usr/local/bin/afsctool ] ||
  [ -x /Applications/Squeeze.app/Contents/Helpers/afsctool ] || [ -x "$HOME/Applications/Squeeze.app/Contents/Helpers/afsctool" ] || {
  echo "afsctool not found. Install Squeeze.app or run: brew install afsctool" >&2
  exit 1
}

mkdir -p "$DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$(cd "$(dirname "$0")" && pwd)/squeeze-steam.sh" "$DIR/squeeze-steam.sh"
chmod +x "$DIR/squeeze-steam.sh"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DIR/squeeze-steam.sh</string>
  </array>
  <key>StartInterval</key><integer>7200</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/squeeze.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed. Squeeze checks your Steam games every 2 hours (on AC power, when the Mac is idle)."
echo "Log: ~/Library/Logs/squeeze.log · Status now: \"$DIR/squeeze-steam.sh\" --list"
