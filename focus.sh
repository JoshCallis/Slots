#!/bin/bash
# focus.sh "<app>"
#
# Unified app-focus script. Replaces the per-app focus_*.sh scripts.
# Pass an app name (or a known short alias) as the only argument:
#
#   focus.sh fusion      -> Autodesk Fusion
#   focus.sh kindle      -> Safari, Kindle Cloud Reader tab (kindle/show_tab.sh)
#   focus.sh chrome      -> Google Chrome
#   focus.sh finder      -> Finder (guarantees a window exists)
#   focus.sh OrcaSlicer  -> exact name, no alias needed
#   focus.sh "Some New App"  -> any app you install later: just pass its name
#
# Behaviour for every app:
#   - if it is already running, raise it via the slot system (no swipe)
#   - otherwise launch it with `open -a`
# Known apps below get alias/regex matching and any per-app special handling.
# Unknown apps fall through to the generic path: the argument is used verbatim
# as the launch name, the process name, and the slot name.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
SLOTS=/Users/josh/Code/Scripts/slots

ARG="${1:?app name required, e.g. \"fusion\" or \"Notes\"}"

# Resident engine (slots/slotd.py): raising a running floater (and Control Room's
# toggle) in one round trip; anything else comes back untouched and runs below.
source /Users/josh/Code/Scripts/slots/jump_stamp.sh   # latest press wins; dropped 3s after it
# "kindle" = the Kindle Cloud Reader tab in Safari, not the Amazon Kindle app (see goto_app.sh).
[[ "$(printf '%s' "$ARG" | tr '[:upper:]' '[:lower:]')" == kindle ]] && { ARG=Safari; trap '/Users/josh/Code/Scripts/kindle/show_tab.sh' EXIT; }
if [[ -f /Users/josh/Code/Scripts/config/slots_daemon ]]; then RES=$(/Users/josh/bin/slotc focus "$ARG" 2>/dev/null); RC=$?; else RC=2; fi
(( RC == 4 )) && { trap - EXIT; exit 0; }     # dropped (stale / superseded): do nothing
if (( RC == 0 )); then
  RES="${RES##*$'\n'}"
  [[ "$RES" == controlroom\|* ]] && exit 0    # Control Room put away (it quit)
  "$SLOTS/cad_handoff.sh" "${RES%%|*}" "${RES##*|}"
  exit 0
fi

# --- resolve the argument to launch/process/slot names -----------------------
# Sets OPEN_NAME / SLOT_NAME / PGREP_PAT / SPECIAL (see app_resolve.sh).
source /Users/josh/Code/Scripts/app_resolve.sh
resolve_app "$ARG"

# 3ds Max / the Windows VM: resume the VM if max/vm.sh paused it.
[[ "$SPECIAL" == coherence || "$SPECIAL" == parallels ]] && /Users/josh/Code/Scripts/max/vm.sh ensure
# Control Room: summon it (unhide) and jump to its space like any app — not a toggle
# (remap_open.sh; 2026-10-17).
[[ "$SPECIAL" == controlroom ]] && exec "/Users/josh/Code/Scripts/remap/remap_open.sh"
# A Coherence app lives on its own full-screen macOS Space, outside the slots:
# it can't be raised "here", so this jumps to it like goto_app does.
[[ "$SPECIAL" == coherence ]] && { open_coherence; exit 0; }
# File Explorer floats on the Windows Spaces: "here" is there too (open_explorer).
[[ "$SPECIAL" == explorer ]] && { /Users/josh/Code/Scripts/max/vm.sh ensure; open_explorer; exit 0; }

# --- guarantee a window exists, then raise -----------------------------------
# ensure_app_window reproduces a Dock click for EVERY app (see app_resolve.sh):
# launches the app if needed, makes a window when none exists (so closing the
# last window with Cmd-W no longer leaves the script doing nothing), un-minimizes
# instead of duplicating, and handles the Finder/BTT special cases. It never
# spawns a duplicate when a window is already open. Then we raise/position via
# the slot system.
ensure_app_window
# Slots switched off (slots/power.sh): just bring the app forward.
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && { open -a "$OPEN_NAME"; exit 0; }
bash "$SLOTS/slot_activate.sh" "$SLOT_NAME"
