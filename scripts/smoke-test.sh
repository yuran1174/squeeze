#!/bin/bash
# Starts Squeeze.app, lets it open its window and measure the programs, and checks it is still running.
# Saves a screenshot, the app's output and any crash report to <out>.
#   ./scripts/smoke-test.sh dist/Squeeze.app build/smoke
set -u
APP="${1:?path to Squeeze.app}"
OUT="${2:-build/smoke}"
WAIT="${SMOKE_SECONDS:-25}"
mkdir -p "$OUT"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
rm -f "$REPORTS"/Squeeze* 2>/dev/null

"$APP/Contents/MacOS/Squeeze" >"$OUT/output.txt" 2>&1 &
pid=$!
sleep "$WAIT"
screencapture -x "$OUT/screen.png" 2>/dev/null || true

if kill -0 "$pid" 2>/dev/null; then
  echo "Squeeze is running after ${WAIT}s"
  kill "$pid"
  wait "$pid" 2>/dev/null
  status=0
else
  wait "$pid"
  echo "Squeeze exited early with status $?"
  status=1
fi
sleep 2
for r in "$REPORTS"/Squeeze*; do
  [ -e "$r" ] || continue
  echo "crash report: $r"
  cp "$r" "$OUT/"
  head -60 "$r"
  status=1
done
tail -20 "$OUT/output.txt"
exit $status
