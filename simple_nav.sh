#!/bin/bash
# simple_nav.sh +1 | -1
#
# Swipe entry point (BTT → yabai_nav.sh → here). Now a thin wrapper over the
# slot engine: navigate the slot sequence, then run the Fusion/SketchUp handoff
# based on the focus-app transition the engine reports.
#
# The old implementation (cache, group filtering, inline scene_restore) lives in
# snapshots/*_working_atomic_confirmed/simple_nav.sh if a rollback is needed.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
SLOTS=/Users/josh/Code/Scripts/slots
DIR="${1:?direction required (+1 or -1)}"

# NOTE: deliberately do NOT kill FusionScrollFilter here. Killing it before the
# space switch left Fusion unprotected for the rest of the swipe, so the 4-finger
# gesture's residual scroll/momentum events reached Fusion raw and zoomed it. The
# live filter swallows all momentum and anything that isn't a clean 2-finger
# touch, so keeping it running through the swipe is what prevents the stray zoom.
# cad_handoff.sh below still restarts/stops it correctly once the switch settles.

# The resident engine first (slots/slotd.py — see slots/slotd.sh); slotlib when it's
# off, down, or hands the op back.
source /Users/josh/Code/Scripts/slots/jump_stamp.sh   # latest press wins; dropped 3s after it
if [[ -f /Users/josh/Code/Scripts/config/slots_daemon ]]; then RES=$(/Users/josh/bin/slotc nav "$DIR" 2>/dev/null); RC=$?; else RC=2; fi
(( RC == 4 )) && exit 0                       # dropped (stale / superseded): do nothing
if (( RC == 0 )); then
  RES="${RES##*$'\n'}"
else
  RES=$(bash "$SLOTS/slotlib.sh" nav "$DIR" 2>/dev/null | tail -1)
fi
PREV="${RES%%|*}"
NEW="${RES##*|}"
"$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
