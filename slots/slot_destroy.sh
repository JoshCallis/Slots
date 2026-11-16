#!/bin/bash
# slot_destroy.sh
#
# Destroy the current space (slot). Its apps are NOT closed: any app that lived
# only in this space becomes unassigned (still running, just untracked), while
# apps also present in other spaces keep those memberships. We then land on the
# neighbouring space and restore it. Then runs CAD handoff for the new focus.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots

RES=$(bash "$SLOTS/slotlib.sh" destroy 2>/dev/null | tail -1)
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
