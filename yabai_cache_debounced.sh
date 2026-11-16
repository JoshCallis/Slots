#!/bin/bash
# Debounced wrapper around yabai_cache.sh for application_launched /
# application_terminated signals.
#
# Why: when an app launches, the application_launched signal fires immediately
# while macOS is still animating it into fullscreen. spaces_info at that
# moment shows a transient state (app briefly on the desktop with no
# fullscreen space yet) and yabai_cache.sh builds a corrupted map from it.
#
# The debounce holds the rebuild for DELAY seconds; if another launch /
# terminate fires before the delay elapses, the pending rebuild is cancelled
# and the timer restarts. The cache is only rebuilt once the burst of
# launch/terminate events has settled.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"

DELAY=2
PID_FILE=/tmp/yabai_cache_debounce.pid

# Cancel any pending rebuild from a previous invocation
if [[ -f "$PID_FILE" ]]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
  rm -f "$PID_FILE"
fi

# Schedule a new rebuild after DELAY seconds, in the background.
# After rebuilding the cache, register any new fullscreen spaces (round-trip
# via desktop) so they immediately work as overlay-rendered ("working") apps —
# no manual reset needed when opening a new fullscreen app.
(
  sleep "$DELAY"
  /Users/josh/Code/Scripts/yabai_cache.sh
  /Users/josh/Code/Scripts/yabai_register.sh
  rm -f "$PID_FILE"
) &
echo $! > "$PID_FILE"
disown
