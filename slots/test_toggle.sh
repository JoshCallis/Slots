#!/bin/bash
# CLI tests for toggle_app.sh — the decision only, no windows touched
# (TOGGLE_DRYRUN=1 prints "goto <app>" / "focus <app>" and stops).
#
# State is written by hand rather than built with slotlib ops: what is under test
# is how a members file is READ, so the fixture is that file.

set -u
TOG=/Users/josh/Code/Scripts/toggle_app.sh
PASS=0; FAIL=0

newdir() { mktemp -d "${TMPDIR:-/tmp}/toggletest.XXXXXX"; }

# state <dir> <current> <"slot|app|pos|z" ...>
state() {
  local d="$1" cur="$2"; shift 2
  echo "$cur" > "$d/current_slot"
  : > "$d/slot_members"
  local l; for l in "$@"; do echo "$l" >> "$d/slot_members"; done
}

# SLOT_DRYRUN keeps slotlib's "what's on top" read off the real screen; a test sets
# SLOT_WINLIST (front-to-back "owner|x|y|w|h") to mock it.
tog() { local d="$1"; shift; SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" TOGGLE_DRYRUN=1 bash "$TOG" "$@"; }

assert() { # desc, actual, expected
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "   expected: [$3]"; echo "   actual:   [$2]"; fi
}

echo "TEST 1: on A's space → jump to B, and back again"
d=$(newdir)
state "$d" s1 "s1|Notes|full|1" "s2|Podcasts|full|2"
assert "1.on Notes → Podcasts" "$(tog "$d" Notes Podcasts Notes)" "goto Podcasts"
state "$d" s2 "s1|Notes|full|1" "s2|Podcasts|full|2"
assert "1.on Podcasts → Notes" "$(tog "$d" Notes Podcasts Notes)" "goto Notes"
rm -rf "$d"

echo "TEST 2: on neither → the starting app"
d=$(newdir)
state "$d" s3 "s1|Notes|full|1" "s2|Podcasts|full|2" "s3|Claude|full|3"
assert "2.starts on Notes" "$(tog "$d" Notes Podcasts Notes)" "goto Notes"
assert "2.starts on Podcasts" "$(tog "$d" Notes Podcasts Podcasts)" "goto Podcasts"
assert "2.omitted → the first" "$(tog "$d" Notes Podcasts)" "goto Notes"
rm -rf "$d"

echo "TEST 3: both in one slot (a paired layout) → raise the other in place"
d=$(newdir)
state "$d" s1 "s1|Notes|left|5" "s1|Podcasts|right|4"    # Notes is on top
assert "3.Notes on top → focus Podcasts" "$(tog "$d" Notes Podcasts Notes)" "focus Podcasts"
state "$d" s1 "s1|Notes|left|4" "s1|Podcasts|right|5"    # Podcasts is on top
assert "3.Podcasts on top → focus Notes" "$(tog "$d" Notes Podcasts Notes)" "focus Notes"
rm -rf "$d"

echo "TEST 4: an app living in several slots is judged by THIS one"
d=$(newdir)
# Notes is a member of s1 and s3; we are on s1, so the toggle still reads "on Notes".
state "$d" s1 "s1|Notes|full|1" "s2|Podcasts|full|2" "s3|Notes|right|3"
assert "4.on Notes' slot → Podcasts" "$(tog "$d" Notes Podcasts Notes)" "goto Podcasts"
state "$d" s2 "s1|Notes|full|1" "s2|Podcasts|full|2" "s3|Notes|right|3"
assert "4.on Podcasts' slot → Notes" "$(tog "$d" Notes Podcasts Notes)" "goto Notes"
rm -rf "$d"

echo "TEST 5: no slot state at all → the starting app"
d=$(newdir)
assert "5.cold start" "$(tog "$d" Notes Podcasts Podcasts)" "goto Podcasts"
rm -rf "$d"

echo "TEST 5b: the target already snapped on top of this space → the other one"
d=$(newdir); printf '1000 800\n' > "$d/screen_dims"
# On Claude's s3 (neither app's space), Fusion was clicked on top, full, never summoned.
state "$d" s3 "s1|Fusion|full|1" "s2|Claude|full|2" "s3|Notes|full|3"
assert "5b.Fusion in front → Claude" \
  "$(SLOT_WINLIST=$'Fusion|0|0|1000|800\nNotes|0|0|1000|800' tog "$d" Fusion Claude Fusion)" "goto Claude"
assert "5b.a loose floater above is looked through" \
  "$(SLOT_WINLIST=$'Tiny|50|50|200|100\nFusion|0|0|1000|800' tog "$d" Fusion Claude Fusion)" "goto Claude"
assert "5b.target only behind something → still the target" \
  "$(SLOT_WINLIST=$'Notes|0|0|1000|800\nFusion|0|0|1000|800' tog "$d" Fusion Claude Fusion)" "goto Fusion"
# On Fusion's space, but Claude has been clicked on top of it → back to Fusion.
state "$d" s1 "s1|Fusion|full|1" "s2|Claude|full|2"
assert "5b.on Fusion's space with Claude in front → Fusion" \
  "$(SLOT_WINLIST=$'Claude|0|0|1000|800\nFusion|0|0|1000|800' tog "$d" Fusion Claude Fusion)" "focus Fusion"
rm -rf "$d"

echo "TEST 6: aliases resolve to the slot system's own names"
d=$(newdir)
state "$d" s1 "s1|Fusion|full|1" "s2|Google Chrome|full|2"
assert "6.\"fusion\" is Fusion's slot" "$(tog "$d" fusion chrome fusion)" "goto Google Chrome"
state "$d" s2 "s1|Fusion|full|1" "s2|Google Chrome|full|2"
assert "6.\"chrome\" is Google Chrome's" "$(tog "$d" fusion chrome fusion)" "goto Fusion"
rm -rf "$d"

echo "──────────────────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
