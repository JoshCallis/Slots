#!/bin/bash
# remove_app.sh "<app>"
#
# The argument-driven twin of goto_app.sh: instead of bringing an app forward,
# this removes the given app from the CURRENT space and hides it — exactly what
# slot_winclose.sh (Cmd-W) does, but aimed at the app you name rather than the
# front window. Accepts the same friendly names/aliases as focus.sh / goto_app.sh
# (e.g. "fusion", "kindle", "chrome").
#
# The window is never closed/quit — it's peeled out of this space and hidden
# (kept open, still a member of any other slot it belongs to). Whatever was
# behind it comes forward. See op_winclose in slotlib.sh for the full semantics.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SCRIPTS=/Users/josh/Code/Scripts
SLOTS="$SCRIPTS/slots"

ARG="${1:?app name required, e.g. \"fusion\" or \"Notes\"}"

# Resolve friendly name/alias to the slot system's state key (SLOT_NAME).
source "$SCRIPTS/app_resolve.sh"
resolve_app "$ARG"

RES=$(bash "$SLOTS/slotlib.sh" winclose "$SLOT_NAME" 2>/dev/null | tail -1)
PREV="${RES%%|*}"
NEW="${RES##*|}"

"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
