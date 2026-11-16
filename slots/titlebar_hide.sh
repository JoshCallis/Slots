#!/bin/bash
# titlebar_hide.sh — yabai window_moved/window_resized for an app with a `titlebar`
# setting (config/settings.json; today Photoshop) → keep its title bar pushed above
# the top screen edge while it is snapped to a top-edge tile.
#
# do_move / realize_plan.py set the window to y=-titlebar, h+titlebar, but the app
# drags it back on screen itself every time it is activated (Photoshop: to y=-1).
# This puts it back. Geometry only: a window whose screen-clamped rect is a top-edge
# tile (full / left / right / top-*) is re-set to that tile, extended upwards; a
# loose window is left alone. Its own move fires this again — a no-op then.
# Reads the window server (space_query), never yabai's AX-backed query.
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0     # slots switched off (slots/power.sh)
wid="$YABAI_WINDOW_ID"; [[ "$wid" =~ ^[0-9]+$ ]] || exit 0
read -r sw sh < /tmp/screen_dims 2>/dev/null
[[ -n "$sh" ]] || exit 0
set -- $(/Users/josh/bin/space_query json 2>/dev/null | /Library/Developer/CommandLineTools/usr/bin/python3 -S -c '
import json, sys
wid, sw, sh = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
tb = {}
for a in json.load(open("/Users/josh/Code/Scripts/config/settings.json")).get("apps", []):
    if a.get("titlebar"):
        for n in [a["key"], a.get("open", a["key"]), a.get("activate", a["key"])] + a.get("alt_names", []):
            tb[n] = int(a["titlebar"])
w = next((w for w in json.load(sys.stdin)["windows"] if w["id"] == wid), None)
if not w or w["app"] not in tb or not w["spaces"]:
    sys.exit()
t = tb[w["app"]]
x, y, ww, wh = w["x"], w["y"], w["w"], w["h"]
cy, ch = max(y, 0), min(y + wh, sh) - max(y, 0)          # clamped to the screen
hw, hh = sw // 2, sh // 2
tol = 8
for tx, tw, th in ((0, sw, sh), (0, hw - 1, sh), (hw, hw, sh), (0, hw - 1, hh), (hw, hw, hh)):
    if abs(x - tx) <= tol and abs(ww - tw) <= tol and cy <= tol and abs(ch - th) <= tol + t:
        if y != -t or wh != th + t:
            print(tx, -t, tw, th + t)
        break
' "$wid" "$sw" "$sh")
[[ $# -eq 4 ]] || exit 0
yabai -m window "$wid" --move abs:"$1":"$2" 2>/dev/null
yabai -m window "$wid" --resize abs:"$3":"$4" 2>/dev/null
