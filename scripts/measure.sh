#!/bin/sh
# Measures MacLens's own footprint. Read-only: the scan phase only reads your home folder.
#   1. background idle (window closed, menu bar only)   2. window open on Dashboard, then Processes (default 5 s refresh)
#   3. full home-folder scan: duration and peak memory
# CPU numbers include child processes (/bin/ps, netstat) via /usr/bin/time.
set -eu
cd "$(dirname "$0")/.."
BIN=dist/MacLens.app/Contents/MacOS/MacLens
IDLE=${IDLE_SECONDS:-300}
WIN=${WINDOW_SECONDS:-120}
pkill -x MacLens 2>/dev/null || true

run() { # $1 = seconds, rest = args; prints cpu% of one core and footprint
  secs=$1; shift
  out=$(mktemp)
  ( /usr/bin/time -p "$BIN" "$@" 2> "$out" & )
  sleep 20                                   # skip launch cost
  pid=$(pgrep -x MacLens)
  t0=$(date +%s)
  c0=$(ps -o time= -p "$pid")
  sleep "$secs"
  fp=$(footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')
  peak=$(footprint "$pid" 2>/dev/null | awk '/phys_footprint_peak:/ {print $2, $3; exit}')
  kill -TERM "$pid"; sleep 2
  echo "  footprint now: $fp · peak: $peak"
  awk -v s="$secs" '/^user/ {u=$2} /^sys/ {y=$2} /^real/ {r=$2} END {printf "  CPU incl. children, whole run: %.2f%% of one core (%.2fs over %.0fs)\n", (u+y)/r*100, u+y, r}' "$out"
  rm -f "$out"
}

echo "1) Background idle, ${IDLE}s:"; run "$IDLE" --background
echo "2a) Window open on Dashboard, ${WIN}s:"; run "$WIN" --assume-visible --tab dashboard
echo "2b) Window open on Processes, ${WIN}s:"; run "$WIN" --assume-visible --tab processes
echo "3) Full home-folder scan (no cache, so it's a full scan):"
# Point the app at a throwaway cache dir so an existing cache can't turn this into a fast rescan.
CACHE=$(mktemp -d)
start=$(date +%s)
( MACLENS_CACHE_DIR="$CACHE" "$BIN" --autoscan-home --assume-visible >/dev/null 2>&1 & )
sleep 3; pid=$(pgrep -x MacLens)
until ls "$CACHE"/scan-*.bin >/dev/null 2>&1; do sleep 1; done
end=$(date +%s)
footprint "$pid" 2>/dev/null | awk '/phys_footprint(_peak)?:/ {print "  " $1, $2, $3}'
echo "  scan wall time (incl. writing cache): $((end-start))s"
kill -TERM "$pid"
rm -rf "$CACHE"   # the temporary cache directory created above
