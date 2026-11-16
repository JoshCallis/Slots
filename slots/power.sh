#!/bin/bash
# power.sh — the one on/off switch for the whole slots layer (Control Room ▸ Slots).
#
#   power.sh off      slots stop: every entry point, yabai handler and slotlib op
#                     sees the flag and steps aside; windows are put back to plain
#                     macOS (normal sub-layer, drop shadow back), the JankyBorders
#                     line goes.
#   power.sh on       flag cleared, then `yabai --restart-service` — yabairc is what
#                     starts borders (it must be yabai's child for the AX grant) and
#                     runs the startup `slotlib pin`, so a restart is the one path
#                     that brings everything back exactly as a login would.
#   power.sh status   prints on / off.
#
# THE FLAG is config/slots_off (gitignored, machine state). It persists across
# reboots on purpose — /tmp would quietly switch slots back on at the next login.
# Every guard is the same one-line test of that path (`slots_off` below is only a
# spelling of it for this file); nothing caches it.
#
# WHAT OFF DOES NOT TOUCH, deliberately:
#   * Light / Dark / Extras — contrast_theme and the appearance cycle are separate
#     processes that never read this flag.
#   * CAD navigation (reanchor, FusionScrollFilter, fusion_dwell) — Fusion tooling
#     driven by yabai's Fusion/SketchUp activation signals, not by slots.
#   * yabai itself — Fusion's helper windows lean on its rules and the SA.
# FALLBACKS while off, so no key goes dead: goto_app.sh / focus.sh / toggle_app.sh
# just bring the app forward (`open -a`), slot_winclose.sh (BTT's Cmd+W) posts a
# native Cmd+W to the front app. Swipes, snaps, remove/destroy/fullnew do nothing.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
FLAG=/Users/josh/Code/Scripts/config/slots_off
slots_off() { [[ -f "$FLAG" ]]; }

# Every window back to plain: `below`/`above` → normal, shadow restored where slotlib
# stripped it. yabai's own rules keep theirs (FusionParams is `above` by rule,
# screen_frame is unmanaged); Remap stays flat for the same reason pin_loose_above
# keeps it flat (its CSS edge + a shadow's rim = a double line).
plain_windows() {
  yabai -m query --windows 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
keep = {"FusionParams", "screen_frame"}
for w in ws:
    app = w.get("app")
    if app in keep: continue
    if w.get("sub-layer") not in ("normal", None): print(w["id"], "sublayer")
    if w.get("has-shadow") is False and app != "Remap": print(w["id"], "shadow")
' 2>/dev/null | while read -r id kind; do
    case "$kind" in
      sublayer) yabai -m window "$id" --sub-layer normal 2>/dev/null ;;
      shadow)   yabai -m window "$id" --toggle shadow    2>/dev/null ;;
    esac
  done
}

case "${1:-status}" in
  off)
    touch "$FLAG"
    # Wait out an op already in flight so it can't re-strip a shadow after us.
    for _ in $(seq 1 40); do [[ -f /tmp/.slot_lock ]] || break; sleep 0.05; done
    pkill -x borders 2>/dev/null
    plain_windows
    echo off ;;
  on)
    rm -f "$FLAG"
    yabai --restart-service >/dev/null 2>&1
    echo on ;;
  status)
    slots_off && echo off || echo on ;;
  *) echo "usage: power.sh on|off|status" >&2; exit 2 ;;
esac
