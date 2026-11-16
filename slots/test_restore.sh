#!/bin/bash
# test_restore.sh
#
# Navigate back and forth between two adjacent slots N times and dump the
# scene_restore timing log.  Start from whichever slot you're currently on;
# the script alternates -1 / +1.
#
# Usage:
#   cd /Users/josh/Code/Scripts
#   bash slots/test_restore.sh [rounds]   # default 6 rounds

export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
SLOTS=/Users/josh/Code/Scripts/slots
ROUNDS="${1:-6}"
DELAY=1.2          # seconds between swipes — enough for scene_restore to finish
SCENE_LOG=/tmp/scene_restore.log
SLOTS_LOG=/tmp/slots.log

echo "Clearing logs..."
: > "$SCENE_LOG"
: > "$SLOTS_LOG"

echo "Running $ROUNDS round-trips (total $((ROUNDS * 2)) swipes)..."
for ((i=1; i<=ROUNDS; i++)); do
    echo "  round $i: swipe -1"
    bash /Users/josh/Code/Scripts/simple_nav.sh -1 > /dev/null 2>&1
    sleep "$DELAY"
    echo "  round $i: swipe +1"
    bash /Users/josh/Code/Scripts/simple_nav.sh +1 > /dev/null 2>&1
    sleep "$DELAY"
done

echo ""
echo "════════════════════════════════════════"
echo "  slots.log  (nav events)"
echo "════════════════════════════════════════"
cat "$SLOTS_LOG"

echo ""
echo "════════════════════════════════════════"
echo "  scene_restore.log  (phase timing)"
echo "════════════════════════════════════════"
cat "$SCENE_LOG"

echo ""
echo "════════════════════════════════════════"
echo "  Summary: freeze error codes & total time per run"
echo "════════════════════════════════════════"
awk '
  /=== scene_restore fired/ { run++; pid=""; t0=""; label=$0; printf "\nRun %d: %s\n", run, label }
  /\[pid / {
    match($0, /\[pid ([0-9]+)\]/, a)
    if (!pid) pid=a[1]
  }
  /P1 freeze/ {
    match($0, /err=([0-9-]+)/, a)
    printf "  freeze err=%s\n", a[1]
  }
  /P5 unfreeze/ {
    match($0, /err=([0-9-]+)/, a)
    printf "  unfreeze err=%s\n", a[1]
  }
  /P6 focus re-assert/ {
    match($0, /total=([0-9.]+)ms/, a)
    printf "  total=%.1fms\n", a[1]
  }
  /wid=0 / { print "  *** wid=0 (excluded):", $0 }
  /P4 settled/ { print "  " $0 }
' "$SCENE_LOG"
