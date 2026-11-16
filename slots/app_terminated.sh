#!/bin/bash
# app_terminated.sh — slot-side reaction to an app quitting by ANY means: a Dock
# quit, ⌘Q, or a crash, not just our `close` script. Wired to yabai's
# application_terminated signal (alongside the fullscreen-cache rebuild in
# yabai_cache_debounced.sh).
#
# It asks slotlib to prune every member whose app is no longer running and to
# destroy any space the quit reduced to a bare full-screen shell — the quit app
# was the space's `full` member with no other snapped app left (floaters don't
# count). See op_app_terminated in slotlib.sh for the exact rule. If the current
# space is the one destroyed, slotlib lands us on a neighbour and restores it; we
# then run the CAD handoff for the new focus.
#
# Two safeguards, mirroring window_event.sh:
#   1. Debounce — quitting an app can fire a burst of events; we act once, DELAY
#      seconds after the last, which also lets System Events stop listing the
#      now-dead process before we enumerate what's still running.
#   2. Op-guard — never run during one of our own slot ops (scene_restore etc.
#      touch /tmp/.slot_op_ts); without this a restore could race the prune.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)

SLOTS=/Users/josh/Code/Scripts/slots
GUARD=/tmp/.slot_op_ts
PID_FILE=/tmp/.slot_appterm_debounce.pid
COOLDOWN=2          # seconds: ignore events this soon after a slot op (our own moves)
DELAY=0.6           # seconds: settle time after the last terminate event

# Fresh script-driven layout change in flight → let it finish; don't race it.
guard_fresh() {
  [[ -f "$GUARD" ]] || return 1
  local now ts; now=$(date +%s); ts=$(stat -f %m "$GUARD" 2>/dev/null || echo 0)
  (( now - ts < COOLDOWN ))
}
guard_fresh && exit 0

# Debounce: cancel any pending run, schedule a fresh one after things settle.
[[ -f "$PID_FILE" ]] && { kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"; }
(
  sleep "$DELAY"
  guard_fresh && { rm -f "$PID_FILE"; exit 0; }   # a slot op started during the wait
  RES=$(bash "$SLOTS/slotlib.sh" appterm 2>/dev/null | tail -1)
  PREV="${RES%%|*}"
  NEW="${RES##*|}"
  [[ -n "$PREV" || -n "$NEW" ]] && "$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
  rm -f "$PID_FILE"
) &
echo $! > "$PID_FILE"
disown
