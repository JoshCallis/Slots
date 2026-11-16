#!/bin/bash
# slot_reset.sh — "Reset slots": put the slots layer back in line with the screen
# when it has drifted. Bound in Control Room (Slots ▸ Shortcuts ▸ + New command ▸
# Reset slots); BTT's F16 "Restore Slots" reaches it through restore_state.sh.
#
#   1. yabai — restarted only if it doesn't answer within 2s (a restart costs
#      every slot jump for a few seconds, so a healthy yabai is left alone).
#   2. slotlib.sh reset — every slot rebuilt from what is on its desktop
#      (op_reset), the desktop caches dropped, the current slot shown again.
#   3. slotd restarted, so the resident engine starts clean too.
# Log: /tmp/slots.log ("reset: …").
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots
log() { echo "[$(date '+%H:%M:%S')] [slots] $*" >> /tmp/slots.log; }

yabai_ok() { perl -e 'alarm 2; exec @ARGV' yabai -m query --spaces --space >/dev/null 2>&1; }
if ! yabai_ok; then
  log "reset: yabai not answering → restarting it"
  yabai --restart-service 2>/dev/null || { yabai --stop-service; yabai --start-service; }
  for _ in $(seq 1 40); do sleep 0.25; yabai_ok && break; done
  sleep 2                                       # yabairc's signals + SA load
fi

bash "$SLOTS/slotlib.sh" reset
[[ -f /Users/josh/Code/Scripts/config/slots_daemon ]] && "$SLOTS/slotd.sh" restart >/dev/null 2>&1
exit 0
