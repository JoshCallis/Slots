#!/bin/bash
# slot_winclose.sh
#
# Slot-aware "close window" — remapd's four-finger W (bindings.json slots.winclose).
# Cmd-W itself is native again (BTT's Cmd-W trigger retired 2026-10-13,
# remap/btt_retire.sh … cmdw), so apps get their own Close Tab / Close Window.
#
# Never closes/quits a window — it just removes the front app from the current
# space and hides it, so whatever was behind it comes forward.
#   - If the front app is a member of the CURRENT slot: remove it from this slot
#     only and hide it (the window is kept open, not closed). It stays a member
#     of, and visible in, any other slots; if this was its only slot it becomes
#     unassigned but keeps running. A window that exactly tiles the vacated
#     rectangle is adopted into the slot.
#   - If the front app is unmanaged / a true floating window (not a member of the
#     current slot): just hide it. It leaves this space (kept open, never closed)
#     even if it ends up assigned to no slot at all.
#
# Then runs the Fusion/SketchUp handoff for whatever now has focus.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
SLOTS=/Users/josh/Code/Scripts/slots

# Slots switched off (slots/power.sh): there's no slot to peel from, so hand the
# front app a native Cmd+W instead. keypost posts straight to the pid
# (CGEventPostToPid), under the event taps, so it can't re-trigger this script.
# 13 = W, 8 = Command.
if [[ -f /Users/josh/Code/Scripts/config/slots_off ]]; then
  pid=$(lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed 's/[^0-9]//g')
  [[ -n "$pid" ]] && keypost "$pid" 13 8
  exit 0
fi

RES=$(bash "$SLOTS/slotlib.sh" winclose 2>/dev/null | tail -1)
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
