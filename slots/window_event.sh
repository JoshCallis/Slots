#!/bin/bash
# window_event.sh — live reconcile when a window is moved/resized BY HAND.
#
# Wired to yabai's window_moved / window_resized signals (see yabairc). The slot
# engine normally only reconciles a space on switch-away; this makes it react the
# instant the user drags or resizes a window:
#   - drag a snapped window loose (non-tile size) → it becomes a sticky FLOATER
#     (recorded at literal geometry, pinned `above`, shown on every space).
#   - snap a window to a tile by hand           → it becomes a non-sticky SNAPPED
#     member (pulled to `normal`, a jump target like any canon snapped app).
#
# Two safeguards keep it from fighting the system:
#   1. Debounce — a drag fires a burst of events; we reconcile once, DELAY seconds
#      after the last one.
#   2. Op-guard — scene_restore and do_move reposition windows themselves, which
#      ALSO fire these signals. slotlib touches /tmp/.slot_op_ts on every op; we
#      ignore events for COOLDOWN seconds after it, so a reveal never triggers a
#      reconcile that competes with it.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)

SLOTS=/Users/josh/Code/Scripts/slots
GUARD=/tmp/.slot_op_ts
PID_FILE=/tmp/.slot_winevt_debounce.pid
COOLDOWN=2          # seconds: ignore events this soon after a slot op (our own moves)
DELAY=0.25          # seconds: settle time after the last manual event

# Sub-layer control needs the scripting addition; without it there's nothing to do.
# A MISSING sentinel is not proof the SA is dead — it is written from a loader whose
# exit code lies, and this script exiting here is one of the three things that go
# silently dead when it is wrong (see yabai_sa_probe.sh). So re-probe before giving
# up; the script rate-limits itself, and the sentinel-present case forks nothing.
if [[ ! -f /tmp/.yabai_sa_loaded ]]; then
  /Users/josh/Code/Scripts/yabai_sa_probe.sh --ensure >/dev/null 2>&1
  [[ -f /tmp/.yabai_sa_loaded ]] || exit 0
fi

# Fresh script-driven layout change in flight → this event is ours, not the user's.
guard_fresh() {
  [[ -f "$GUARD" ]] || return 1
  local now ts; now=$(date +%s); ts=$(stat -f %m "$GUARD" 2>/dev/null || echo 0)
  (( now - ts < COOLDOWN ))
}
guard_fresh && exit 0

# A display was just added/removed: these moves are macOS relocating windows between
# screens, not the user (see display_event.sh). slotlib's reconcile checks this too.
display_fresh() {
  [[ -f /tmp/.slot_display_ts ]] || return 1
  local now ts; now=$(date +%s); ts=$(stat -f %m /tmp/.slot_display_ts 2>/dev/null || echo 0)
  (( now - ts < 20 ))
}
display_fresh && exit 0

# UI Zoom's screen glide resizes every tiled window on screen, ~100 times a second,
# and then for a moment after (distance zoom starts one every second or so). Those
# are ours too: ui_zoom.sh holds its press lock until the glide lands and rewrites
# /tmp/.screen_zoom as it does (slotlib.sh zoom_busy — same test, kept in step).
zoom_fresh() {
  [[ -f /tmp/.screen_zoom ]] || return 1
  /usr/bin/lockf -k -s -t 0 /tmp/.ui_zoom.lock /usr/bin/true || return 0
  local now ts; now=$(date +%s); ts=$(stat -f %m /tmp/.screen_zoom 2>/dev/null || echo 0)
  (( now - ts <= 1 ))
}
zoom_fresh && exit 0

# Debounce: cancel any pending reconcile, schedule a fresh one after things settle.
[[ -f "$PID_FILE" ]] && { kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"; }
(
  sleep "$DELAY"
  guard_fresh && { rm -f "$PID_FILE"; exit 0; }   # a slot op started during the wait
  zoom_fresh && { rm -f "$PID_FILE"; exit 0; }    # …or a UI Zoom glide
  bash "$SLOTS/slotlib.sh" reconcile >/dev/null 2>&1
  rm -f "$PID_FILE"
) &
echo $! > "$PID_FILE"
disown
