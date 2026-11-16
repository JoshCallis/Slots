#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SCRIPTS=/Users/josh/Code/Scripts/BetterTouchTool
MODE=$(cat /tmp/fusion_reanchor_mode 2>/dev/null || echo "orbit")
# Only (re)start reanchor if the correct mode's process isn't already running.
# This activation can fire mid-gesture — reanchor itself activates Fusion on a
# 2-finger scroll — and a killall+restart there would kill the very reanchor
# handling the gesture. Skip it when the right mode is already up.
if { [[ "$MODE" == "orbit" ]] && pgrep -x reanchor     > /dev/null; } || \
   { [[ "$MODE" == "pan"   ]] && pgrep -x reanchor_pan > /dev/null; }; then
  :   # already running in the right mode — leave it
else
  "$SCRIPTS/reanchor.sh" "$MODE"
fi
"$SCRIPTS/fusion_scroll.sh" on
"$SCRIPTS/fusion_dwell.sh" on

# The cadbars overlay-bar sync used to be poked from here. cadbars is retired (all
# four edges disabled, LaunchAgent gone — see the note in config/yabai/yabairc), so
# the call was a background subshell, a sleep and a pkill against a process that is
# never running, on every single activation of Fusion. Its source is at git tag
# `cadbars-last` if it is ever wanted back; reinstate the call with it.
