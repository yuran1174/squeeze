#!/bin/bash
# End-to-end check of the bundled cleanup engine on a throwaway Mac (CI):
# preview finds a test cache, a kept path is left out of the plan and out of the cleanup,
# a real cleanup removes the test cache. DO NOT run on your own Mac: it really cleans.
#   ./scripts/test-cleanup-engine.sh build/mole/engine
set -euo pipefail
ENGINE="${1:?path to the engine folder (with bin/clean.sh)}"
[ "${CI:-}" = true ] || { echo "refusing to run outside CI: this really cleans caches" >&2; exit 2; }

W="$(mktemp -d)"
REMOVE="$HOME/Library/Caches/io.github.yuran1174.squeeze-test.remove"
KEEP="$HOME/Library/Caches/io.github.yuran1174.squeeze-test.keep"
mkdir -p "$REMOVE" "$KEEP"
head -c 5000000 /dev/urandom >"$REMOVE/blob"
head -c 5000000 /dev/urandom >"$KEEP/blob"
touch -t 202001010000 "$REMOVE/blob" "$KEEP/blob" "$REMOVE" "$KEEP"

run() { # dry-run|real keep-file preview-file
  local args=()
  [ "$1" = dry-run ] && args=(--dry-run)
  NO_COLOR=1 TERM=dumb MOLE_EXTRA_WHITELIST_FILE="$2" MOLE_PREVIEW_FILE="$3" \
    /usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV or die' /bin/bash "$ENGINE/bin/clean.sh" ${args[@]+"${args[@]}"} </dev/null
}

echo "=== 1. preview, nothing kept"
: >"$W/keep-none"
start=$(date +%s)
run dry-run "$W/keep-none" "$W/preview1.txt" >"$W/out1.txt" 2>&1 || { tail -40 "$W/out1.txt"; exit 1; }
echo "took $(( $(date +%s) - start ))s"
grep "^===" "$W/preview1.txt" || true
grep -F "$REMOVE" "$W/preview1.txt"
grep -F "$KEEP" "$W/preview1.txt"

echo "=== 2. preview with the keep list"
printf '%s\n' "$KEEP" >"$W/keep"
run dry-run "$W/keep" "$W/preview2.txt" >"$W/out2.txt" 2>&1 || { tail -40 "$W/out2.txt"; exit 1; }
grep -F "$REMOVE" "$W/preview2.txt"
if grep -F "$KEEP" "$W/preview2.txt"; then echo "kept path is still in the plan" >&2; exit 1; fi

echo "=== 3. the user's own Mole files are not touched"
[ ! -e "$HOME/.config/mole/clean-list.txt" ] || { echo "wrote ~/.config/mole/clean-list.txt" >&2; exit 1; }

echo "=== 4. real cleanup with the keep list"
run real "$W/keep" "$W/preview3.txt" >"$W/out3.txt" 2>&1 || { tail -40 "$W/out3.txt"; exit 1; }
tail -15 "$W/out3.txt"
if [ -e "$REMOVE/blob" ]; then echo "test cache was not removed" >&2; exit 1; fi
[ -s "$KEEP/blob" ] || { echo "kept cache was removed" >&2; exit 1; }
echo "cleanup engine OK"
