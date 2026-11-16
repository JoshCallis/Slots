#!/bin/bash
# slot_activate.sh "<App>"
#
# Bring an app to the front WITHOUT swiping (BTT hotkey / dock-replacement script).
# Records it into the current slot at its last position (a fill-screen app simply
# takes over the current space), then runs CAD handoff.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots
APP="${1:?app name required, e.g. \"Notes\" or \"Autodesk Fusion\"}"

# Resident engine (slots/slotd.py) first: it raises a floater in one round trip and
# hands anything else back untouched.
source /Users/josh/Code/Scripts/slots/jump_stamp.sh   # latest press wins; dropped 3s after it
if [[ -f /Users/josh/Code/Scripts/config/slots_daemon ]]; then RES=$(/Users/josh/bin/slotc activate "$APP" 2>/dev/null); RC=$?; else RC=2; fi
(( RC == 4 )) && exit 0                       # dropped (stale / superseded): do nothing
if (( RC != 0 )); then
  RES=$(bash "$SLOTS/slotlib.sh" activate "$APP" 2>/dev/null)
fi
RES="${RES##*$'\n'}"
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
