#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SCRIPTS=/Users/josh/Code/Scripts/BetterTouchTool
LOG=/tmp/yabai_debug.log

log() { echo "[$(date '+%H:%M:%S.%3N')] [cad_deactivated] $*" >> "$LOG"; }

log "called"
# reanchor is intentionally NOT killed here anymore: it now runs focus-independent
# so a 3-finger drag over an INACTIVE Fusion still orbits (it adds Ctrl to the
# drag). Its cursor-gate keeps it inert unless the pointer is over a CAD window, so
# it's harmless while you work elsewhere, and fusion_activated.sh restarts it
# (killall+start) on each activation so no duplicates accumulate.
# The scroll filter now runs PERSISTENTLY too (same reasoning as reanchor above):
# it must already be alive when a 2-finger scroll begins over an INACTIVE Fusion,
# or it misses the gesture start (phase==1) and Fusion zooms the flick natively.
# Its cursorOverCAD() gate (Fusion-only) keeps it inert everywhere else.
log "ACTION: killing dwell only (scroll + reanchor stay running, cursor-gated)"
"$SCRIPTS/fusion_dwell.sh" off

# cadbars sync removed with cadbars itself — see fusion_activated.sh.
