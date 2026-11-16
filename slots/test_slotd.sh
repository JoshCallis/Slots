#!/bin/bash
# test_slotd.sh — slots/slotd.py must do exactly what slotlib.sh does.
#
# Differential, dry-run (SLOT_DRYRUN=1 SLOT_SPACES=1 — no window is touched): every
# case starts two copies of the same state, runs the op through `bash slotlib.sh`
# in one and `slotd.py --once` in the other, and diffs stdout, every state file and
# the log (timestamps stripped). A case slotd hands back (FALLBACK) is counted, not
# compared — slotlib runs it for real then, so it is the same by construction —
# but a case listed as `want=handled` must not fall back.
#
# Run after ANY change to slotlib.sh's nav / navapp / spacesync path or to slotd.py.
set -u
LIB=/Users/josh/Code/Scripts/slots/slotlib.sh
PYD=/Users/josh/Code/Scripts/slots/slotd.py
PY=/Library/Developer/CommandLineTools/usr/bin/python3
[[ -x "$PY" ]] || PY=/usr/bin/python3
DELAY=977.25            # reconcile_left's delay: never fires during the test (killed at the end)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/slotd_test.XXXXXX")
PASS=0; FAIL=0; FELL=0

U_NOTES=U-NOTES; U_FUSION=U-FUSION; U_SAFARI=U-SAFARI; U_CHROME=U-CHROME; U_OFF=U-OFFSLOT

# ── fixtures ──────────────────────────────────────────────────────────────────
# Base: the live layout of 2026-10-10 — Notes, Fusion, Claude+Safari, Claude+Chrome.
base() {
  local d="$1"
  printf '%s\n' s22 s26 s27 s28 > "$d/slot_seq"
  printf '%s\n' 's26|Fusion|full|1859' 's22|Notes|full|1867' 's28|Claude|left|1881' \
    's28|Google Chrome|right|1882' 's27|Safari|right|1887' 's27|Claude|left|1888' > "$d/slot_members"
  printf '%s\n' 'Fusion|full' 'Notes|full' 'Claude|left' 'Safari|right' 'Google Chrome|right' > "$d/app_lastpos"
  echo 1888 > "$d/z_counter"; echo 28 > "$d/slot_counter"
  printf '%s\n' "s22|$U_NOTES" "s26|$U_FUSION" "s27|$U_SAFARI" "s28|$U_CHROME" > "$d/slot_spaces"
  printf '%s\n' "s22|3|$U_NOTES" "s26|8|$U_FUSION" "s27|9|$U_SAFARI" "s28|10|$U_CHROME" > "$d/slot_space_idx"
  printf '%s\n' 'Notes|101' 'Fusion|102' 'Claude|103' 'Safari|104' 'Google Chrome|105' > "$d/slot_winids"
  printf '%s\n' Safari 'Google Chrome' Notes Fusion Claude > "$d/app_mru"
  echo "1728 1085" > "$d/screen_dims"
}
fixture() {             # dir name
  local d="$1"; base "$d"
  case "$2" in
    base) ;;
    chrome_recent)      # Chrome used more recently than Safari
      printf '%s\n' 'Google Chrome' Safari Notes Fusion Claude > "$d/app_mru" ;;
    no_companion)       # Claude dropped out of Safari's space (it quit overnight)
      grep -v '^s27|Claude|' "$d/slot_members" > "$d/m"; mv "$d/m" "$d/slot_members" ;;
    one_claude)         # a single Claude space, holding Safari; Chrome in no slot
      grep -v '^s28|' "$d/slot_members" > "$d/m"; mv "$d/m" "$d/slot_members"
      printf '%s\n' s22 s26 s27 > "$d/slot_seq"
      printf '%s\n' 'Google Chrome' Safari Notes > "$d/app_mru" ;;
    floater)            # a floater sits where Claude would be refilled
      grep -v '^s27|Claude|' "$d/slot_members" > "$d/m"; mv "$d/m" "$d/slot_members"
      echo 's27|Preview|10,10,500,500|1890' >> "$d/slot_members"; echo 1890 > "$d/z_counter" ;;
    floater_far)        # …or somewhere that doesn't block the left tile
      grep -v '^s27|Claude|' "$d/slot_members" > "$d/m"; mv "$d/m" "$d/slot_members"
      echo 's27|Preview|1000,10,500,500|1890' >> "$d/slot_members"; echo 1890 > "$d/z_counter" ;;
    claude_elsewhere)   # Claude snapped at a different tile somewhere → can't be refilled
      grep -v '^s27|Claude|' "$d/slot_members" > "$d/m"; mv "$d/m" "$d/slot_members"
      sed 's/^s28|Claude|left|/s28|Claude|full|/' "$d/slot_members" > "$d/m"; mv "$d/m" "$d/slot_members" ;;
    single)             # one slot only
      printf '%s\n' s22 > "$d/slot_seq"; echo 's22|Notes|full|1867' > "$d/slot_members" ;;
    stale_seq)          # current isn't in the sequence
      : ;;
    no_idx)             # no cached desktop for Fusion's slot → falls back (not in a dry run)
      grep -v '^s26|' "$d/slot_space_idx" > "$d/m"; mv "$d/m" "$d/slot_space_idx" ;;
    grid)               # the grid's cells not yet entered (base ring only)
      : ;;
    grid_in)            # on the middle cell, Chrome picked; the top cell entered before
      printf '%s\n' s22 s26 g1 g2 > "$d/slot_seq"
      printf '%s\n' 's26|Fusion|full|1859' 's22|Notes|full|1867' 'g1|Claude|left|1890' \
        'g1|Google Chrome|right|1891' 'g2|Fusion|full|1892' > "$d/slot_members"
      echo 1892 > "$d/z_counter"; echo 'g1|right|Google Chrome' > "$d/slot_grid_active"
      printf '%s\n' "g1|U-G1" "g2|U-G2" >> "$d/slot_spaces" ;;
    *) echo "unknown fixture $2"; exit 2 ;;
  esac
}

# ── one case ──────────────────────────────────────────────────────────────────
# case <want: handled|fallback|any> <fixture> <current> <active-desk uuid> <op> [args]
n=0
case_() {
  local want="$1" fx="$2" cur="$3" desk="$4"; shift 4
  n=$((n+1))
  local A="$ROOT/$n.bash" B="$ROOT/$n.py" d
  for d in "$A" "$B"; do
    mkdir -p "$d"; fixture "$d" "$fx"; echo "$cur" > "$d/current_slot"; echo s99 > "$d/prev_slot"
    [[ -n "$desk" ]] && echo "$desk" > "$d/.slot_active_desk"
  done
  local envs=(SLOT_DRYRUN=1 SLOT_SPACES=1 SLOT_RECONCILE_DELAY=$DELAY
              SLOT_GRID="$([[ "$fx" == grid* ]] && echo "$GRID" || echo /dev/null)"
              SLOT_RUNNING="${RUNNING-$'Safari\nGoogle Chrome\nClaude\nNotes\nFusion'}")
  local oa ob
  oa=$(env "${envs[@]}" SLOT_STATE_DIR="$A" SLOT_LOG="$A/log" bash "$LIB" "$@" 2>/dev/null)
  ob=$(env "${envs[@]}" SLOT_STATE_DIR="$B" SLOT_LOG="$B/log" "$PY" -S "$PYD" --once "$@" 2>&1)
  local label="[$n] $fx cur=$cur desk=${desk:-none}: $*"
  if [[ "$ob" == FALLBACK* ]]; then
    FELL=$((FELL+1))
    if [[ "$want" == handled ]]; then FAIL=$((FAIL+1)); echo "FAIL $label — fell back: $ob"; else echo "  ok  $label → ${ob}"; fi
    return
  fi
  if [[ "$want" == fallback ]]; then FAIL=$((FAIL+1)); echo "FAIL $label — expected a fallback, got [$ob]"; return; fi
  for d in "$A" "$B"; do [[ -f "$d/log" ]] && sed 's/^\[[0-9:]*\] //' "$d/log" > "$d/log.cmp"; rm -f "$d/log"; done
  local diffs; diffs=$(diff -r "$A" "$B" 2>&1)
  if [[ "$oa" != "$ob" ]]; then diffs="stdout: bash [$oa] vs slotd [$ob]"$'\n'"$diffs"; fi
  if [[ -z "$diffs" ]]; then PASS=$((PASS+1)); echo "  ok  $label → $ob"
  else FAIL=$((FAIL+1)); echo "FAIL $label"; echo "$diffs" | sed 's/^/      /'; fi
}

echo "── navapp"
for cur in s22 s26 s27 s28; do
  for app in Notes Fusion Claude Safari "Google Chrome" "Autodesk Fusion"; do
    case_ any base "$cur" "" navapp "$app"
  done
done
for fx in chrome_recent no_companion one_claude floater floater_far claude_elsewhere; do
  for app in Claude Safari "Google Chrome"; do case_ any "$fx" s22 "" navapp "$app"; done
done
case_ handled base s22 "" navapp Fusion
case_ handled no_companion s22 "" navapp Safari
case_ handled one_claude s22 "" navapp Claude
case_ handled base s26 "" navapp Fusion               # already in the current slot (in place)
case_ handled base s28 "" navapp Claude               # …e.g. from 3ds Max, current = the slot left
case_ handled base s22 "" navapp TextEdit             # in no slot, non-canon → raised as a floater
case_ handled floater s22 "" navapp Preview           # a floater of another slot → raised here
case_ handled floater s27 "" navapp Preview           # …or of this one
case_ any stale_seq s99 "" navapp Fusion
case_ any no_idx s22 "" navapp Fusion

echo "── activate (floater branch only)"
case_ handled base s22 "" activate TextEdit
case_ handled floater s22 "" activate Preview
case_ handled floater s27 "" activate Preview
case_ fallback base s22 "" activate Notes             # snapped member of current
case_ fallback base s22 "" activate Fusion            # canon, joins at its last tile
case_ any base s22 "$U_FUSION" activate TextEdit

echo "── navapp after a desktop switch macOS made (spaces_follow)"
case_ any base s22 "$U_SAFARI" navapp Fusion
case_ any base s22 "$U_FUSION" navapp Notes
case_ any base s22 "$U_OFF" navapp Fusion

echo "── nav"
desk_of() { case "$1" in s22) echo "$U_NOTES" ;; s26) echo "$U_FUSION" ;; s27) echo "$U_SAFARI" ;; s28) echo "$U_CHROME" ;; esac; }
for cur in s22 s26 s27 s28; do
  for dir in +1 -1 +2 -3; do case_ handled base "$cur" "$(desk_of "$cur")" nav "$dir"; done
done
for cur in s22 s26 s27 s28; do
  case_ handled base "$cur" "$U_NOTES" nav +1
  case_ handled base "$cur" "$U_CHROME" nav -1
done
case_ handled base s27 "$U_OFF" nav +1                 # off-slot desktop → back to current
case_ handled single s22 "$U_NOTES" nav +1             # nowhere to go
case_ any stale_seq s99 "$U_FUSION" nav +1
case_ fallback base s22 "$U_NOTES" nav sideways

echo "── the grid (swipe / gridtoggle / navapp into a cell)"
# A plus: Claude | Safari·Chrome in the middle, Fusion on top, Notes on the right.
GRID="$ROOT/grid.json"
cat > "$GRID" <<'J'
{"arm_hops": true, "home": "g1", "cells": [
 {"id": "g1", "row": 1, "col": 1, "layout": "split", "left": ["Claude"], "right": ["Safari", "Google Chrome"]},
 {"id": "g2", "row": 0, "col": 1, "layout": "full", "full": ["Fusion", "3ds Max 2027"]},
 {"id": "g3", "row": 1, "col": 2, "layout": "full", "full": ["Notes"]}]}
J
case_ handled grid s22 "$U_NOTES" swipe left          # off-grid → home (middle)
case_ handled grid s22 "$U_OFF" swipe up              # 3ds Max's desktop → home
case_ handled grid_in g1 U-G1 swipe left              # middle → right arm
case_ handled grid_in g1 U-G1 swipe down              # middle → top arm (content follows)
case_ handled grid_in g1 U-G1 swipe right             # nothing that way
case_ handled grid_in g2 U-G2 swipe left              # top arm → right arm (round the plus)
case_ handled grid_in g2 U-G2 swipe up                # top arm → middle
case_ handled grid_in g1 U-G1 gridtoggle              # Chrome → Safari, sticks
case_ handled grid_in g2 U-G2 gridtoggle              # Fusion → 3ds Max: its Space, Fusion stays resident
case_ handled grid_in s22 "$U_NOTES" gridtoggle       # off-grid: nothing
case_ handled grid s22 "$U_NOTES" navapp Safari       # into its cell, Safari picked
case_ handled grid_in s22 "$U_NOTES" navapp Safari    # cell showing Chrome → Safari
case_ handled grid_in s22 "$U_NOTES" navapp Claude    # keeps the pick (Chrome)
case_ handled grid_in g1 U-G1 navapp Fusion           # → the top cell
case_ fallback grid_in g1 U-G1 swipe sideways
# A cell none of whose apps is open is skipped, never launched (2026-11-15).
RUNNING=$'Safari\nGoogle Chrome\nClaude\nFusion'
case_ handled grid_in g1 U-G1 swipe left              # right arm (Notes) closed → nothing
case_ handled grid_in g2 U-G2 swipe left              # round the plus to closed Notes → nothing
RUNNING=$'Safari\nClaude\nNotes'
case_ handled grid_in g1 U-G1 swipe down              # top arm (Fusion) closed → nothing
case_ handled grid_in g1 U-G1 swipe left              # Notes open: lands, Chrome pick stays shut
GRID="$ROOT/grid_row.json"                            # a row: g1 | Notes | Fusion
cat > "$GRID" <<'J'
{"arm_hops": true, "home": "g1", "cells": [
 {"id": "g1", "row": 1, "col": 0, "layout": "split", "left": ["Claude"], "right": ["Safari", "Google Chrome"]},
 {"id": "g3", "row": 1, "col": 1, "layout": "full", "full": ["Notes"]},
 {"id": "g6", "row": 1, "col": 2, "layout": "full", "full": ["Fusion"]}]}
J
RUNNING=$'Claude\nFusion'
case_ handled grid_in g1 U-G1 swipe left              # past closed Notes → Fusion
unset RUNNING

echo "── spacesync"
for desk in "$U_NOTES" "$U_FUSION" "$U_SAFARI" "$U_CHROME" "$U_OFF"; do
  case_ any base s22 "$desk" spacesync
done

rm -rf "$ROOT"
pkill -f "sleep $DELAY" 2>/dev/null
echo
echo "passed $PASS, failed $FAIL (fallbacks: $FELL)"
[[ $FAIL -eq 0 ]]
