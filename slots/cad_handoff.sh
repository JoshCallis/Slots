#!/bin/bash
# cad_handoff.sh PREV_FOCUS NEW_FOCUS
#
# Ported verbatim from the old simple_nav.sh tail. Runs the Fusion/SketchUp
# reanchor / scroll / dwell handoffs when the focused app changes between a
# CAD app and something else. Driven by the focus-app transition that the slot
# engine reports (PREV|NEW).
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
SCRIPTS=/Users/josh/Code/Scripts
PREV="$1"
NEW="$2"
LOG=/tmp/slots.log
log() { echo "[$(date '+%H:%M:%S')] [cad_handoff] $*" >> "$LOG"; }

# Which apps count as CAD comes from config/settings.json (any app with a `cad`
# block). The per-app branches below stay hardcoded on purpose: they orchestrate
# Fusion/SketchUp-specific daemons, which is code, not configuration.
source "$SCRIPTS/config/load_settings.sh"
is_cad() { [[ -n "$1" && " $CAD_APPS " == *" $1 "* ]]; }
[[ "$PREV" == "$NEW" ]] && exit 0

if is_cad "$PREV" && ! is_cad "$NEW"; then
  log "leaving CAD ($PREV→$NEW) → cad_deactivated.sh"
  "$SCRIPTS/cad_deactivated.sh"
fi

if [[ "$NEW" == "Fusion" ]]; then
  if [[ "$PREV" == "SketchUp" ]]; then
    log "SketchUp → Fusion: scroll/dwell on"
    "$SCRIPTS/BetterTouchTool/fusion_scroll.sh" on
    "$SCRIPTS/BetterTouchTool/fusion_dwell.sh" on
  else
    log "→ Fusion: fusion_activated.sh"
    "$SCRIPTS/fusion_activated.sh"
  fi
fi

if [[ "$NEW" == "SketchUp" ]]; then
  if [[ "$PREV" == "Fusion" ]]; then
    # Filter stays running (persistent, Fusion-gated) — only dwell goes off.
    log "Fusion → SketchUp: dwell off (scroll stays, Fusion-gated), reanchor → orbit if was pan"
    "$SCRIPTS/BetterTouchTool/fusion_dwell.sh" off
    MODE=$(cat /tmp/fusion_reanchor_mode 2>/dev/null || echo "orbit")
    [[ "$MODE" == "pan" ]] && "$SCRIPTS/BetterTouchTool/reanchor.sh" orbit
  else
    log "→ SketchUp: sketchup_activated.sh"
    "$SCRIPTS/sketchup_activated.sh"
  fi
fi
