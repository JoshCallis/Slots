#!/bin/bash
# toggle_app.sh "<appA>" "<appB>" ["<startsOn>"]
#
# One key, two slots. Press it on A's space and you land on B; press it on B's
# space and you come back to A. Press it anywhere else and you land on the one
# named third (the "starts on" app — A if it is left out).
#
# Names are the friendly ones goto_app.sh and focus.sh take ("fusion", "chrome",
# an exact app name — see app_resolve.sh); they resolve to the slot system's own
# state keys before anything is compared.
#
# WHERE AM I is answered by SLOT MEMBERSHIP, not by what is frontmost. The unit
# the key toggles between is a space, and a space can hold several apps (a paired
# layout), so "am I on Fusion's space" is the question that matches what the hand
# means — and it is already written down in the members file.
#
# THE ONE CASE WHERE Z-ORDER DECIDES: both apps in the SAME slot (a paired
# layout — Fusion left, Chrome right). Membership can't separate them there, so
# the topmost of the two is taken as "where I am" and the other is raised in
# place. Nothing jumps, which is right: they are both already on screen.
#
# Landing is goto_app.sh (jump to its space) unless the target is already a
# member of this one, in which case it is focus.sh (raise it here, no jump) —
# the same two verbs the four-finger layer uses.
#
# Set up from Control Room ▸ Slots ▸ Shortcuts: + New command ▸ Toggle between
# two apps. That page writes the binding that calls this; the two app names and
# the starting one are this script's arguments.
#
# Env (tests): SLOT_STATE_DIR as slotlib's; TOGGLE_DRYRUN=1 prints the decision
# ("goto <app>" / "focus <app>") instead of acting. See slots/test_toggle.sh.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
SCRIPTS=/Users/josh/Code/Scripts

A_ARG="${1:?two app names required, e.g. toggle_app.sh fusion chrome}"
B_ARG="${2:?two app names required, e.g. toggle_app.sh fusion chrome}"
START_ARG="${3:-$A_ARG}"

# Resident engine (slots/slotd.py): the whole decision + the jump in one round
# trip — the path below costs ~250 ms before it even switches (mostly topsnapped's
# window read). It replies "focus APP" when the target is already in this slot.
source "$SCRIPTS/slots/jump_stamp.sh"   # latest press wins; dropped 3s after it
RC=2
if [[ -z "${TOGGLE_DRYRUN:-}" && -f "$SCRIPTS/config/slots_daemon" ]]; then
  RES=$(/Users/josh/bin/slotc toggle "$A_ARG" "$B_ARG" "$START_ARG" 2>/dev/null); RC=$?
fi
(( RC == 4 )) && exit 0                 # dropped (stale / superseded): do nothing
if (( RC == 0 )); then
  RES="${RES##*$'\n'}"
  [[ "$RES" == "focus "* ]] && exec "$SCRIPTS/focus.sh" "${RES#focus }"
  [[ "$RES" == coherence\|* ]] && exit 0      # 3ds Max's own desktop: outside the slots
  exec "$SCRIPTS/slots/cad_handoff.sh" "${RES%%|*}" "${RES##*|}"
fi

SDIR="${SLOT_STATE_DIR:-/tmp}"
MEM="$SDIR/slot_members"      # slotID|app|position|z
CUR="$SDIR/current_slot"

# Resolve each friendly name to the key the slot system stores (SLOT_NAME).
source "$SCRIPTS/app_resolve.sh"
resolve_app "$A_ARG";     A="$SLOT_NAME"
resolve_app "$B_ARG";     B="$SLOT_NAME"
resolve_app "$START_ARG"; START="$SLOT_NAME"

# Slots switched off (slots/power.sh): no membership to read — whichever of the
# two is frontmost is "where I am", so go to the other; neither → the start app.
if [[ -f "$SCRIPTS/config/slots_off" ]]; then
  resolve_app "$A";  A_OPEN="$OPEN_NAME"
  front=$(frontmost_app 2>/dev/null)
  if [[ "$front" == "$A_OPEN" ]]; then T="$B"
  elif resolve_app "$B"; [[ "$front" == "$OPEN_NAME" ]]; then T="$A"
  else T="$START"; fi
  [[ -n "${TOGGLE_DRYRUN:-}" ]] && { echo "goto $T"; exit 0; }
  exec "$SCRIPTS/goto_app.sh" "$T"
fi

cur=$(cat "$CUR" 2>/dev/null)

in_cur() {                      # app → true if it is a member of the current slot
  [[ -n "$cur" && -f "$MEM" ]] || return 1
  awk -F'|' -v s="$cur" -v a="$1" '$1==s && $2==a{f=1} END{exit !f}' "$MEM" 2>/dev/null
}

top_of_cur() {                  # the topmost member of the current slot (highest z)
  [[ -n "$cur" && -f "$MEM" ]] || return 0
  awk -F'|' -v s="$cur" '$1==s{print $4"|"$2}' "$MEM" 2>/dev/null \
    | sort -t'|' -k1,1n | tail -1 | cut -d'|' -f2
}

if [[ "$A" == "$B" ]]; then
  TARGET="$A"
elif in_cur "$A" && in_cur "$B"; then
  # Both here: whichever is in front is "where I am", so raise the other.
  [[ "$(top_of_cur)" == "$A" ]] && TARGET="$B" || TARGET="$A"
elif in_cur "$A"; then
  TARGET="$B"
elif in_cur "$B"; then
  TARGET="$A"
else
  TARGET="$START"
fi

# ALREADY IN FRONT: if the target is the topmost snapped window on screen right
# now (e.g. clicked on top of this space, so membership doesn't show it), you are
# looking at it — land on the other one instead.
if [[ "$A" != "$B" ]] && ! { in_cur "$A" && in_cur "$B"; } \
   && [[ "$(bash "$SCRIPTS/slots/slotlib.sh" topsnapped 2>/dev/null)" == "$TARGET" ]]; then
  [[ "$TARGET" == "$A" ]] && TARGET="$B" || TARGET="$A"
fi

if in_cur "$TARGET"; then VERB=focus; else VERB=goto; fi

if [[ -n "${TOGGLE_DRYRUN:-}" ]]; then
  echo "$VERB $TARGET"
  exit 0
fi

if [[ "$VERB" == "focus" ]]; then
  exec "$SCRIPTS/focus.sh" "$TARGET"
else
  exec "$SCRIPTS/goto_app.sh" "$TARGET"
fi
