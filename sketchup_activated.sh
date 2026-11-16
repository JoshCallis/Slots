#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SCRIPTS=/Users/josh/Code/Scripts/BetterTouchTool
# If orbit reanchor is already running (handoff from Fusion via space_changed), skip restart
if pgrep -x reanchor > /dev/null && [[ "$(cat /tmp/fusion_reanchor_mode 2>/dev/null)" == "orbit" ]]; then
  exit 0
fi
"$SCRIPTS/reanchor.sh" orbit

# cadbars sync removed with cadbars itself — see fusion_activated.sh.
