#!/bin/bash
# goto_app.sh "<app>"
#
# Jump to the NEXT space in the slot sequence that contains the given app
# (wrapping around), and focus that app there. Repeated calls cycle through every
# space the app lives in. Accepts the same friendly names/aliases as focus.sh
# (e.g. "fusion", "kindle", "chrome").
#
# If the app isn't assigned to any space, give it its OWN new fill-screen space:
# launch it if needed, then splice that space into the sequence next to the app's
# canonical neighbour (slotlib `placeapp`), and activate it.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
SCRIPTS=/Users/josh/Code/Scripts
SLOTS="$SCRIPTS/slots"

ARG="${1:?app name required, e.g. \"fusion\" or \"Notes\"}"

# Resident engine (slots/slotd.py, switched by slots/slotd.sh): the common jump — a
# running app that already has a slot — in one round trip. Whatever it doesn't
# handle it hands back untouched, and everything below runs exactly as before.
source /Users/josh/Code/Scripts/slots/jump_stamp.sh   # latest press wins; dropped 3s after it
# "kindle" = the Kindle Cloud Reader tab in Safari, not the Amazon Kindle app:
# jump to Safari, then bring that tab forward (kindle/show_tab.sh) on the way out.
[[ "$(printf '%s' "$ARG" | tr '[:upper:]' '[:lower:]')" == kindle ]] && { ARG=Safari; trap '"$SCRIPTS/kindle/show_tab.sh"' EXIT; }
if [[ -f "$SCRIPTS/config/slots_daemon" ]]; then RES=$(/Users/josh/bin/slotc goto "$ARG" 2>/dev/null); RC=$?; else RC=2; fi
(( RC == 4 )) && { trap - EXIT; exit 0; }     # dropped (stale / superseded): do nothing
if (( RC == 0 )); then
  RES="${RES##*$'\n'}"
  [[ "$RES" == coherence\|* ]] && exit 0      # 3ds Max's Space: outside the slots
  [[ "$RES" == controlroom\|* ]] && exit 0    # Control Room put away (it quit)
  "$SLOTS/cad_handoff.sh" "${RES%%|*}" "${RES##*|}"
  exit 0
fi

# Resolve friendly name/alias to the slot system's state key (SLOT_NAME).
source "$SCRIPTS/app_resolve.sh"
resolve_app "$ARG"

# 3ds Max / the Windows VM: resume the VM if max/vm.sh paused it.
[[ "$SPECIAL" == coherence || "$SPECIAL" == parallels ]] && "$SCRIPTS/max/vm.sh" ensure
# Control Room: summon it (unhide) and jump to its space like any app — not a toggle
# (remap_open.sh; 2026-10-17).
[[ "$SPECIAL" == controlroom ]] && exec "$SCRIPTS/remap/remap_open.sh"
# A Coherence app lives on its own full-screen macOS Space, outside the slots.
[[ "$SPECIAL" == coherence ]] && { open_coherence; exit 0; }
# File Explorer floats on the Windows Spaces, outside the slots (open_explorer).
[[ "$SPECIAL" == explorer ]] && { "$SCRIPTS/max/vm.sh" ensure; open_explorer; exit 0; }

# Guarantee the app is running with a real window before we navigate — this is
# the Dock-click behaviour (launch if needed, make a window when none exists, and
# handle the Finder/BTT special cases). Without it, an app that's running with no
# window (e.g. last window closed with Cmd-W) would give the slot engine nothing
# to focus. See ensure_app_window in app_resolve.sh.
ensure_app_window

# Slots switched off (slots/power.sh): just bring the app forward.
[[ -f "$SCRIPTS/config/slots_off" ]] && { open -a "$OPEN_NAME"; exit 0; }

RES=$(bash "$SLOTS/slotlib.sh" navapp "$SLOT_NAME" 2>/dev/null | tail -1)
PREV="${RES%%|*}"
NEW="${RES##*|}"

if [[ -z "$NEW" ]]; then
  # App isn't assigned to any space — give it its own new fill-screen space and
  # splice it into the canonical sequence (it's already running with a window
  # thanks to ensure_app_window above).
  RES=$(bash "$SLOTS/slotlib.sh" placeapp "$SLOT_NAME" 2>/dev/null | tail -1)
  PREV="${RES%%|*}"
  NEW="${RES##*|}"
fi

"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
