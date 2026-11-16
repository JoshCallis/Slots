#!/bin/bash
# snap.sh <position>
#
# Snap the frontmost app and record it into the current slot via the slot engine.
# Positions: full | left | right | top-left | top-right | bottom-left | bottom-right
# (full = fills the current slot; a floater snapped full gets its own new slot after
#  the current one — slots/MODEL.md § Snap.)
#
# Thin wrapper over slots/slotlib.sh. Old bitmask/group implementation is in
# snapshots/*_working_atomic_confirmed/snap.sh if a rollback is needed.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots
POS="${1:?position required: full|left|right|top-left|top-right|bottom-left|bottom-right}"

bash "$SLOTS/slotlib.sh" snap "$POS"
