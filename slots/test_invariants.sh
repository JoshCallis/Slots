#!/bin/bash
# test_invariants.sh — property/fuzz tests for the slot engine.
#
# Runs long random sequences of the real deliberate operations (nav, snap,
# fullnew, activate, winclose, close, destroy) against slotlib.sh and, after
# EVERY step, checks the structural invariants that "spaces behaving correctly"
# depend on. The whole point is to surface the kind of inconsistency you hit by
# hand — a space silently losing apps, the same app recorded twice in one space,
# current pointing at a slot that no longer exists, two windows recorded at
# overlapping spots, etc. (An empty slot staying in the sequence is NOT a bug:
# closing a space's last app preserves the space; only `destroy` removes a slot.)
#
# Pure logic only: SLOT_DRYRUN=1 and no SLOT_WINLIST, so no windows are touched
# and the failsafe / window-adoption paths are skipped (they need a live screen).
#
# On a violation it prints the seed and the full op trace so the failure is
# reproducible:  SEED=<n> bash test_invariants.sh
#
# Usage:
#   bash test_invariants.sh                # 40 runs x 60 ops, random seeds
#   ITERS=200 OPS=120 bash test_invariants.sh
#   SEED=12345 bash test_invariants.sh     # replay one specific run

set -u
LIB=/Users/josh/Code/Scripts/slots/slotlib.sh
APPS=(Podcasts Notes Claude Kindle SketchUp)
POSITIONS=(full left right top-left top-right bottom-left bottom-right)
ITERS="${ITERS:-40}"
OPS="${OPS:-60}"

newdir() { mktemp -d "${TMPDIR:-/tmp}/slotinv.XXXXXX"; }

# run one op in a state dir with a given front app
runop() {
  local d="$1" front="$2"; shift 2
  SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
    SLOT_APPS="${APPS[*]}" SLOT_FRONT="$front" bash "$LIB" "$@" >/dev/null 2>&1
}

# ── invariant checks (echo a non-empty reason string on violation) ─────────────
# Positions overlap iff they share screen area (mirror of slotlib pos_overlaps).
overlaps() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  [[ "$a" == full || "$b" == full ]] && return 0
  [[ "$a" == left  && ( "$b" == top-left  || "$b" == bottom-left  ) ]] && return 0
  [[ "$a" == right && ( "$b" == top-right || "$b" == bottom-right ) ]] && return 0
  [[ "$b" == left  && ( "$a" == top-left  || "$a" == bottom-left  ) ]] && return 0
  [[ "$b" == right && ( "$a" == top-right || "$a" == bottom-right ) ]] && return 0
  return 1
}

check_invariants() {              # statedir → echoes first violation, or nothing
  local d="$1"
  local SEQ="$d/slot_seq" MEM="$d/slot_members" CUR="$d/current_slot"
  local seq; seq=$(grep -v '^$' "$SEQ" 2>/dev/null)
  local cur; cur=$(cat "$CUR" 2>/dev/null)

  # I1: no duplicate slot IDs in the sequence
  local dup; dup=$(printf '%s\n' "$seq" | grep -v '^$' | sort | uniq -d | head -1)
  [[ -n "$dup" ]] && { echo "I1 duplicate slot '$dup' in seq"; return; }

  # I2: current is a slot that exists in seq (unless everything is empty)
  if [[ -n "$seq" ]]; then
    printf '%s\n' "$seq" | grep -qxF "$cur" || { echo "I2 current '$cur' not in seq"; return; }
  fi

  # I3: every slot that has members is present in seq (no orphaned membership)
  local mslots; mslots=$(awk -F'|' '{print $1}' "$MEM" 2>/dev/null | sort -u)
  local s
  for s in $mslots; do
    printf '%s\n' "$seq" | grep -qxF "$s" || { echo "I3 orphan members in slot '$s' (not in seq)"; return; }
  done

  # I4: (retired) — an empty slot may legitimately remain in the sequence now.
  # Closing the last app in a space NEVER destroys it (only the deliberate
  # `destroy` op does); the space persists empty until something is revealed and
  # adopted into it. So "empty slot still in seq" is expected, not a bug.

  # I5: no app recorded twice in the same slot
  local d2; d2=$(awk -F'|' '{print $1"|"$2}' "$MEM" 2>/dev/null | sort | uniq -d | head -1)
  [[ -n "$d2" ]] && { echo "I5 app recorded twice in a slot: '$d2'"; return; }

  # I6: within each slot, no two members occupy overlapping positions
  for s in $seq; do
    [[ -z "$s" ]] && continue
    local positions; positions=$(awk -F'|' -v s="$s" '$1==s{print $3}' "$MEM" 2>/dev/null)
    local arr=(); local p; for p in $positions; do arr+=("$p"); done
    local i j
    for ((i=0; i<${#arr[@]}; i++)); do
      for ((j=i+1; j<${#arr[@]}; j++)); do
        overlaps "${arr[$i]}" "${arr[$j]}" \
          && { echo "I6 overlapping positions in slot '$s': ${arr[$i]} & ${arr[$j]}"; return; }
      done
    done
  done

  return 0
}

# ── fuzz driver ────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
ONESEED="${SEED:-}"

run_one() {                       # seed → 0 ok / 1 violated (prints trace)
  local seed="$1"
  local d; d=$(newdir)
  RANDOM=$seed
  runop "$d" "${APPS[0]}" init
  local trace="init(front=${APPS[0]})"
  local k op front pos
  for ((k=0; k<OPS; k++)); do
    front="${APPS[$((RANDOM % ${#APPS[@]}))]}"
    op=$((RANDOM % 8))
    case $op in
      0) runop "$d" "$front" nav +1;        trace+=$'\n'"nav +1        front=$front" ;;
      1) runop "$d" "$front" nav -1;        trace+=$'\n'"nav -1        front=$front" ;;
      2) pos="${POSITIONS[$((RANDOM % ${#POSITIONS[@]}))]}"
         runop "$d" "$front" snap "$pos";   trace+=$'\n'"snap $pos     front=$front" ;;
      3) runop "$d" "$front" fullnew;       trace+=$'\n'"fullnew       front=$front" ;;
      4) runop "$d" "$front" activate "$front"; trace+=$'\n'"activate $front" ;;
      5) runop "$d" "$front" winclose;      trace+=$'\n'"winclose      front=$front" ;;
      6) runop "$d" "$front" destroy;       trace+=$'\n'"destroy       front=$front" ;;
      7) # placeapp only models giving an UNASSIGNED app its own space (goto_app's
         # fallback), so pick an app currently in no slot; if all are assigned,
         # fall back to a no-harm nav so the step still counts.
         unassigned=""
         for a in "${APPS[@]}"; do
           grep -qF "|$a|" "$d/slot_members" 2>/dev/null || { unassigned="$a"; break; }
         done
         if [[ -n "$unassigned" ]]; then
           runop "$d" "$front" placeapp "$unassigned"; trace+=$'\n'"placeapp $unassigned"
         else
           runop "$d" "$front" nav +1;        trace+=$'\n'"nav +1 (no unassigned) front=$front"
         fi ;;
    esac
    local why; why=$(check_invariants "$d")
    if [[ -n "$why" ]]; then
      echo "──────────────────────────────────────────"
      echo "VIOLATION  seed=$seed  step=$((k+1))/$OPS  → $why"
      echo "trace:"; printf '%s\n' "$trace" | sed 's/^/   /'
      echo "state:"; SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 bash "$LIB" dump | sed 's/^/   /'
      echo "──────────────────────────────────────────"
      rm -rf "$d"; return 1
    fi
  done
  rm -rf "$d"; return 0
}

if [[ -n "$ONESEED" ]]; then
  if run_one "$ONESEED"; then echo "seed=$ONESEED OK ($OPS ops)"; else exit 1; fi
  exit 0
fi

for ((it=0; it<ITERS; it++)); do
  seed=$(( (RANDOM<<15 ^ RANDOM ^ (it*2654435761)) & 0x7fffffff ))
  if run_one "$seed"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done

echo "──────────────────────────────────────────"
echo "fuzz runs: PASS=$PASS  FAIL=$FAIL   (${OPS} ops each)"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || { echo "SOME FAILED — replay with SEED=<n>"; exit 1; }
