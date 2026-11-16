#!/bin/bash
# display_event.sh — a display was added/removed/changed/resized.
#
# Wired to yabai's display_* signals (see config/yabai/yabairc). Three jobs:
#   1. Drop the cached screen size so the next slot op re-probes it.
#   2. Stamp /tmp/.slot_display_ts. For DISPLAY_SETTLE seconds after it, slotlib's
#      reconcile (and window_event.sh) leave the recorded state alone: macOS is
#      busy shoving windows between screens, and recording that as the user's
#      layout is what used to corrupt every space after a monitor blip / dark wake.
#   3. Once the burst settles, re-reveal the current slot so its windows go back
#      to their tiles on whatever screen is now main (no reconcile — the recorded
#      layout is re-imposed, not re-read).
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)

SLOTS=/Users/josh/Code/Scripts/slots
PID_FILE=/tmp/.slot_display_debounce.pid
SETTLE=3            # seconds after the last display event before re-revealing

rm -f /tmp/screen_dims
touch /tmp/.slot_display_ts

# Debounce by token, not by kill: yabai fires display_added/changed/resized for one
# wake at the same instant, so a "kill the previous waiter" scheme raced (each read
# the pid file before the others wrote it) and up to 5 reveals ran at once
# (2026-10-13) — they fought over the slot lock and kept yabai busy, and every
# hotkey jump queued 10s behind them. Each event writes its own token; a waiter
# reveals only if its token is still the last one: one reveal per burst.
TOKEN="$$.$RANDOM"
echo "$TOKEN" > "$PID_FILE"
(
  sleep "$SETTLE"
  [[ "$(cat "$PID_FILE" 2>/dev/null)" == "$TOKEN" ]] || exit 0    # a later event owns it
  rm -f /tmp/screen_dims
  touch /tmp/.slot_display_ts        # restart the settle window from the last event
  bash "$SLOTS/slotlib.sh" reveal >/dev/null 2>&1
  echo "[$(date '+%H:%M:%S')] [display_event] settled → reveal $(cat /tmp/current_slot 2>/dev/null) at $(cat /tmp/screen_dims 2>/dev/null)" >> /tmp/slots.log
) </dev/null >/dev/null 2>&1 &
disown
