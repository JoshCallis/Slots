#!/usr/bin/env bash
# restore_state.sh — rebuild the slot sequence/contents captured below.
#
# Slots are virtual (a single macOS space); the whole "which apps live in which
# space, in what order, at what positions" state is just the /tmp/slot_* files
# that slotlib.sh reads. This script overwrites those files with the snapshot
# embedded below, then asks slotlib to realize the current slot on screen.
#
# Snapshot was taken on 2026-06-11. Re-capture any time with:  restore_state.sh --capture
# (prints a fresh SEQ_DATA/MEM_DATA/CUR_SLOT block you can paste back in here).
#
# On restore:
#   - a member whose app has no open window right now is dropped,
#   - any slot left with no surviving members is dropped from the sequence,
#   - slot ids / z-order / app_lastpos are rebuilt to stay consistent,
#   - the captured current slot (or the first surviving slot) is revealed.
# Nothing is launched: apps that aren't open are simply disregarded.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"

REPO="/Users/josh/Code/Scripts"
SDIR="${SLOT_STATE_DIR:-/tmp}"
SLOTLIB="$REPO/slots/slotlib.sh"

# ── captured snapshot ─────────────────────────────────────────────────────────
# slot ids in sequence order (top = first space)
SEQ_DATA="s65
s67
s63
s68
s69"

# slotID|app|position|z   (position is a tile name or literal x,y,w,h for floaters)
MEM_DATA="s69|Claude|left|2022
s69|Google Chrome|right|2023
s65|Notes|full|2024
s67|SketchUp|full|2025
s63|Fusion|full|2034
s68|Safari|right|2035
s68|Claude|left|2036"

CUR_SLOT="s69"   # the space that was current when captured

# ── --capture: dump current live state as a fresh snapshot block ──────────────
if [[ "${1:-}" == "--capture" ]]; then
  echo "SEQ_DATA=\"$(cat "$SDIR/slot_seq")\""
  echo
  echo "MEM_DATA=\"$(cat "$SDIR/slot_members")\""
  echo
  echo "CUR_SLOT=\"$(cat "$SDIR/current_slot" 2>/dev/null)\""
  exit 0
fi

# ── native spaces mode: never replay the snapshot ─────────────────────────────
# BTT's "Restore Slots" (Mission Control key + F16, → ~/bin/slots-restore) runs this
# after yabai-refresh. With each slot on its own desktop, win_list only sees the
# current desktop, so the replay below dropped every other app and wiped the live
# slots back to this June snapshot (2026-10-15: Photoshop/Fusion lost on every
# Mission Control press). Rebuild from the desktops instead (slot_reset.sh).
if [[ -f "$REPO/config/slots_spaces" && -z "${SLOT_STATE_DIR:-}" ]]; then
  echo "[$(date '+%H:%M:%S')] [slots] restore_state: native spaces mode — snapshot skipped, running slot_reset.sh" >> /tmp/slots.log
  sleep 3                       # yabai-refresh just restarted yabai; let it answer
  exec "$REPO/slots/slot_reset.sh"
fi

# ── which apps are open (have an on-screen window) ───────────────────────────
# win_list prints "owner|x|y|w|h" for every on-screen window. An app counts as
# open iff it owns at least one such window — that's also the only kind of app we
# could position, so it's exactly the right test.
running="$(win_list 2>/dev/null | cut -d'|' -f1 | sort -u)"

is_open() {                     # is_open "App Name" → 0 if a window owner matches (case-insensitive)
  local a="$1"
  printf '%s\n' "$running" | grep -qix -- "$a"
}

# ── filter members to open apps, then drop emptied slots ──────────────────────
# (bash 3.2 — no associative arrays; membership tests go through grep.)
kept_mem=""                     # surviving "slotID|app|pos|z" lines
while IFS='|' read -r slot app pos z; do
  [[ -z "$slot" ]] && continue
  if is_open "$app"; then
    kept_mem+="$slot|$app|$pos|$z"$'\n'
  else
    echo "drop: $app (not open) from $slot" >&2
  fi
done <<< "$MEM_DATA"

# Slots with at least one surviving member.
alive_slots="$(printf '%s' "$kept_mem" | cut -d'|' -f1 | sort -u)"
is_alive() { printf '%s\n' "$alive_slots" | grep -qx -- "$1"; }

# Surviving sequence = captured order minus the now-empty slots.
kept_seq=""
while IFS= read -r slot; do
  [[ -z "$slot" ]] && continue
  if is_alive "$slot"; then
    kept_seq+="$slot"$'\n'
  else
    echo "drop: empty space $slot (its only app(s) not open)" >&2
  fi
done <<< "$SEQ_DATA"

if [[ -z "$kept_seq" ]]; then
  echo "Nothing to restore — none of the captured apps are open." >&2
  exit 1
fi

# ── derive the rebuilt counters / current slot / app_lastpos ──────────────────
# current slot: captured one if it survived, else the first surviving slot.
cur="$CUR_SLOT"
is_alive "$cur" || cur="$(head -1 <<< "$kept_seq")"

# slot_counter = highest surviving numeric slot id (ids look like sNN).
counter=0
while IFS= read -r slot; do
  [[ -z "$slot" ]] && continue
  n="${slot#s}"; (( n > counter )) && counter="$n"
done <<< "$kept_seq"

# z_counter = highest surviving z value.
zc=0
while IFS='|' read -r _ _ _ z; do
  [[ -z "$z" ]] && continue
  (( z > zc )) && zc="$z"
done <<< "$kept_mem"

# ── write the state files ─────────────────────────────────────────────────────
printf '%s' "$kept_seq" > "$SDIR/slot_seq"
printf '%s' "$kept_mem" > "$SDIR/slot_members"
echo "$cur"     > "$SDIR/current_slot"
echo "$counter" > "$SDIR/slot_counter"
echo "$zc"      > "$SDIR/z_counter"
# app_lastpos rebuilt from surviving members — last position seen per app wins,
# matching how the engine keeps a single global last-position per app.
printf '%s' "$kept_mem" | awk -F'|' '$2!=""{p[$2]=$3} END{for(a in p) print a"|"p[a]}' \
  > "$SDIR/app_lastpos"
rm -f "$SDIR/prev_slot" 2>/dev/null || true

echo "restored: $(wc -l < "$SDIR/slot_seq" | tr -d ' ') spaces, current=$cur" >&2

# ── realize the current slot on screen ───────────────────────────────────────
exec "$SLOTLIB" reveal
