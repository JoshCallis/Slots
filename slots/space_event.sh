#!/bin/bash
# space_event.sh — yabai space_changed → keep the slot engine in step with the
# active desktop, in native-spaces mode (config/slots_spaces) only.
#
# macOS changes desktop by itself when you click a Dock icon or ⌘-Tab to an app whose
# window is on another desktop, or pick one in Mission Control. Two things follow it:
#   * /tmp/.slot_active_desk — the active desktop's uuid, which every slot op reads
#     instead of asking the window server (slotlib.sh active_desk);
#   * "current" — `slotlib spacesync`, so the next swipe starts from the right slot.
# The slots' own flips fire this too; both are then no-ops.
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0     # slots switched off (slots/power.sh)
[[ -f /Users/josh/Code/Scripts/config/slots_spaces ]] || exit 0  # single-space mode: nothing to follow
a=$(/Users/josh/bin/space_query active 2>/dev/null) && echo "${a#* }" > /tmp/.slot_active_desk
[[ -f /Users/josh/Code/Scripts/config/slots_daemon ]] \
  && /Users/josh/bin/slotc spacesync >/dev/null 2>&1 && exit 0   # resident engine (slots/slotd.sh)
exec bash /Users/josh/Code/Scripts/slots/slotlib.sh spacesync >/dev/null 2>&1
