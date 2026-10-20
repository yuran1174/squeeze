#!/bin/bash
# Squeeze — keep Steam games compressed with APFS transparent compression.
#
# Finds installed Steam games and compresses files that are not compressed yet
# (for example, files a game update has just written). Uses afsctool from Homebrew.
#
#   squeeze-steam.sh            games that are already mostly compressed: compress new files
#   squeeze-steam.sh --all      every installed game
#   squeeze-steam.sh --app 570  one game by Steam app id (570 = Dota 2)
#   squeeze-steam.sh --list     show games, size on disk and how much is compressed; change nothing
#   squeeze-steam.sh --force    do not wait for AC power and an idle Mac
#
# Safety: a game is skipped while it is running or while Steam is installing or updating it.
set -u

STEAM="${SQUEEZE_STEAM_ROOT:-$HOME/Library/Application Support/Steam}"
LOG="${SQUEEZE_LOG:-$HOME/Library/Logs/squeeze.log}"
IDLE_MIN="${SQUEEZE_IDLE_MINUTES:-5}"
MIN_NEW_MB="${SQUEEZE_MIN_NEW_MB:-50}"
LOCK="${TMPDIR:-/tmp}/squeeze-steam.lock"

MODE=managed APP="" FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all ;;
    --app) MODE=app; APP="${2:-}"; shift ;;
    --list) MODE=list ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"Squeeze\"" >/dev/null 2>&1 || true; }
human() { awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1000 && i < 5) { b /= 1000; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }

AFSCTOOL="$(command -v afsctool || true)"
for p in /opt/homebrew/bin/afsctool /usr/local/bin/afsctool; do [ -z "$AFSCTOOL" ] && [ -x "$p" ] && AFSCTOOL="$p"; done
if [ -z "$AFSCTOOL" ]; then echo "afsctool is not installed. Run: brew install afsctool" >&2; exit 1; fi
[ -d "$STEAM/steamapps" ] || { echo "Steam library not found: $STEAM" >&2; exit 1; }

# one run at a time
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +240 2>/dev/null)" ]; then rmdir "$LOCK"; mkdir "$LOCK" || exit 0; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

if [ "$FORCE" = 0 ] && [ "$MODE" != list ]; then
  if ! /usr/bin/pmset -g batt | grep -q "AC Power"; then exit 0; fi
  idle=$(/usr/sbin/ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }')
  [ "${idle:-0}" -ge $((IDLE_MIN * 60)) ] || exit 0
fi

# Steam library folders: the main one plus every "path" in libraryfolders.vdf
libraries() {
  echo "$STEAM"
  [ -f "$STEAM/steamapps/libraryfolders.vdf" ] && sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$STEAM/steamapps/libraryfolders.vdf"
}
field() { sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" "$2" | head -1; }
running_inside() { /bin/ps -axo comm= | grep -qF "$1/"; }
bytes() { find "$1" -type f "${@:2}" -print0 2>/dev/null | xargs -0 stat -f %z 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }'; }
ondisk() { du -sk "$1" 2>/dev/null | awk '{ printf "%d", $1 * 1024 }'; }

libraries | awk '!seen[$0]++' | while IFS= read -r lib; do
  for manifest in "$lib"/steamapps/appmanifest_*.acf; do
    [ -f "$manifest" ] || continue
    id=$(field appid "$manifest"); name=$(field name "$manifest"); dir=$(field installdir "$manifest"); state=$(field StateFlags "$manifest")
    path="$lib/steamapps/common/$dir"
    [ -n "$dir" ] && [ -d "$path" ] || continue
    [ "$id" = 228980 ] && continue # Steamworks Common Redistributables

    total=$(bytes "$path")
    plain=$(bytes "$path" ! -flags +compressed)
    if [ "$MODE" = list ]; then
      pct=0; [ "$total" -gt 0 ] && pct=$(( (total - plain) * 100 / total ))
      printf '%-8s %-32s on disk %-9s of %-9s compressed %3d%%\n' "$id" "$name" "$(human "$(ondisk "$path")")" "$(human "$total")" "$pct"
      continue
    fi
    [ "$MODE" = app ] && [ "$id" != "$APP" ] && continue
    # by default only games that are already mostly compressed: the user chose to compress them
    if [ "$MODE" = managed ] && { [ "$total" -eq 0 ] || [ $(( (total - plain) * 2 )) -lt "$total" ]; }; then continue; fi
    [ "$MODE" = managed ] && [ "$plain" -lt $((MIN_NEW_MB * 1000000)) ] && continue
    [ "$plain" -gt 0 ] || continue

    if [ "$state" != 4 ] || [ -n "$(ls -A "$lib/steamapps/downloading/$id" 2>/dev/null)" ]; then log "$name: Steam is installing or updating it, skipped"; continue; fi
    if running_inside "$path"; then log "$name: running, skipped"; continue; fi

    before=$(ondisk "$path")
    log "$name: compressing $(human "$plain") of new files"
    # only files that are not compressed yet, in small batches; stop if the game starts or Steam begins an update
    find "$path" -type f -size +0 ! -flags +compressed -print0 | xargs -0 -n 64 sh -c '
      m="$1"; p="$2"; a="$3"; shift 3
      grep -q "\"StateFlags\"[[:space:]]*\"4\"" "$m" || exit 255
      /bin/ps -axo comm= | grep -qF "$p/" && exit 255
      "$a" -c -T LZFSE "$@" >/dev/null 2>&1; exit 0' sh "$manifest" "$path" "$AFSCTOOL"
    after=$(ondisk "$path")
    saved=$(( before - after )); [ "$saved" -lt 0 ] && saved=0
    log "$name: done, freed $(human "$saved"), now $(human "$after") on disk"
    [ "$saved" -gt 0 ] && notify "$name: freed $(human "$saved") after an update"
  done
done
exit 0
