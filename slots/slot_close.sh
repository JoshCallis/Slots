#!/bin/bash
# slot_close.sh
#
# Close (quit) the frontmost app and clean up its slot membership. If that
# empties a slot it's removed from the sequence and we land on the previous
# slot. Then runs CAD handoff for the new focus.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots

RES=$(bash "$SLOTS/slotlib.sh" close 2>/dev/null | tail -1)
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
