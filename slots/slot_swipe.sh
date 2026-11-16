#!/bin/bash
# slot_swipe.sh left|right|up|down|toggle
#
# The grid's commands (Control Room ▸ Slots ▸ Grid; slots/grid.py): swipe to the
# neighbouring cell — content follows the fingers, so `left` goes to the cell on the
# right and `up` to the one below — or `toggle` this cell's alternatives (Safari ↔
# Chrome). Bound on Remap ▸ Shortcuts ▸ Slots like any slots command. Same shape as
# simple_nav.sh: slotd first, slotlib when it hands the op back, then the CAD handoff.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots
ARG="${1:?left|right|up|down|toggle}"
case "$ARG" in
  left|right|up|down) OP=(swipe "$ARG") ;;
  toggle)             OP=(gridtoggle) ;;
  *) echo "usage: slot_swipe.sh left|right|up|down|toggle" >&2; exit 1 ;;
esac

source "$SLOTS/jump_stamp.sh"   # latest press wins; dropped 3s after it
if [[ -f /Users/josh/Code/Scripts/config/slots_daemon ]]; then RES=$(/Users/josh/bin/slotc "${OP[@]}" 2>/dev/null); RC=$?; else RC=2; fi
(( RC == 4 )) && exit 0                       # dropped (stale / superseded): do nothing
if (( RC == 0 )); then
  RES="${RES##*$'\n'}"
else
  RES=$(bash "$SLOTS/slotlib.sh" "${OP[@]}" 2>/dev/null | tail -1)
fi
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
