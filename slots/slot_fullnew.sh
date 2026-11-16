#!/bin/bash
# slot_fullnew.sh
#
# Duplicate the current space: create a NEW space one to the right that is an
# exact copy of the current one, and make it active. Nothing on screen changes —
# it's the same arrangement — the user then edits this fresh copy as they wish,
# leaving the original space untouched on swipe-back.
# (focus is unchanged, so the CAD handoff below is a no-op.)
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots

RES=$(bash "$SLOTS/slotlib.sh" fullnew 2>/dev/null | tail -1)
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
