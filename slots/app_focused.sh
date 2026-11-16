#!/bin/bash
# app_focused.sh — the user focused a window that a reveal had parked `below`.
#
# Wired to yabai's application_activated and window_focused signals (see yabairc).
# A slot reveal hides the windows it isn't showing by pushing them to yabai's
# `below` sub-layer, and app activation can never lift a `below` window over a
# `normal` one. So clicking Fusion's canvas where it shows through beside a
# half-width window focused Fusion but left the other window in front. This hands
# such a focus to `slotlib clicked`, which lifts the window — or, if it fills the
# screen and has a full-screen space, switches to that space.
#
# Fast path: nearly every focus change is of a window that is NOT `below`; that
# costs one yabai query and exits. Same op-guard as window_event.sh, so the reveal's
# own activations (which land on windows mid-sub-layer-shuffle) are ignored.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)
# Native spaces: nothing is parked `below` (a slot's windows live on its own desktop),
# and a yabai window query on EVERY activation was one more call that a busy Fusion
# could stall yabai with — so the `below` path steps aside. One job remains: an app
# opened outside the scripts (Dock, Spotlight, ⌘-Tab) whose windows all sit on
# another desktop took focus with nothing on screen (switch-on-activate is off).
# If it is no slot's member, its windows are floaters by definition → make them
# sticky so they appear here. Read via space_query (window server), never yabai.
if [[ -f /Users/josh/Code/Scripts/config/slots_spaces ]]; then
  [[ -z "$YABAI_WINDOW_ID" && -n "$YABAI_PROCESS_ID" ]] || exit 0   # app activations only
  ids=$("$HOME/bin/space_query" json 2>/dev/null | PID="$YABAI_PROCESS_ID" /usr/bin/python3 -c '
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
pid = int(os.environ["PID"])
act = {s["id"] for s in d["spaces"] if s.get("active") in (1, True)}
full = {s["id"] for s in d["spaces"] if s.get("fullscreen") in (1, True)}
mine = [w for w in d["windows"] if w["pid"] == pid and w["w"] * w["h"] >= 200 * 150]
if not mine or any(set(w["spaces"]) & act for w in mine): sys.exit(0)
app = mine[0]["app"]
# Every owner name a slot member answers to (key, open/activate names, alt_names).
try: apps = json.load(open("/Users/josh/Code/Scripts/config/settings.json"))["apps"]
except Exception: apps = []
names = {}
for a in apps:
    for n in [a.get("open"), a.get("activate")] + list(a.get("alt_names") or []):
        if n: names.setdefault(n, set()).add(a["key"])
members, mwids = set(), set()
for f, kcol in (("/tmp/slot_members", 1), ("/tmp/slot_winids", 0)):
    try:
        for ln in open(f):
            p = ln.rstrip("\n").split("|")
            if len(p) > kcol: members.add(p[kcol])
            if len(p) > 1 and p[-1].isdigit(): mwids.add(int(p[-1]))
    except OSError: pass
if app in members or names.get(app, set()) & members: sys.exit(0)
out = [w["id"] for w in mine if len(w["spaces"]) == 1 and w["spaces"][0] not in full
       and w["id"] not in mwids]
if out: print(app + "\t" + " ".join(map(str, out)))' 2>/dev/null)
  [[ -z "$ids" ]] && exit 0
  app="${ids%%$'\t'*}"
  # "could not locate" = yabai never registered the app (seen 2026-10-18: Terminal
  # launched onto an inactive desktop) — only relaunching the app (or yabai) fixes it.
  ok= bad=
  for id in ${ids#*$'\t'}; do
    if yabai -m window "$id" --toggle sticky 2>/dev/null; then ok+=" $id"; else bad+=" $id"; fi
  done
  echo "[$(date +%H:%M:%S)] [app_focused] $app: windows on another desktop →${ok:+ sticky floater:$ok}${bad:+ UNLOCATABLE by yabai:$bad}" >> /tmp/slots.log
  "$HOME/bin/activate_app" "$app" >/dev/null 2>&1
  exit 0
fi

SLOTS=/Users/josh/Code/Scripts/slots
GUARD=/tmp/.slot_op_ts
COOLDOWN=2

[[ -f /tmp/.yabai_sa_loaded ]] || exit 0          # no SA → nothing is ever `below`
if [[ -f "$GUARD" ]]; then
  now=$(date +%s); ts=$(stat -f %m "$GUARD" 2>/dev/null || echo 0)
  (( now - ts < COOLDOWN )) && exit 0
fi

# The focused window; for application_activated fall back to that pid's frontmost
# `below` window (Fusion's canvas doesn't always report focus through AX).
hit=$(yabai -m query --windows 2>/dev/null | /usr/bin/python3 -c '
import sys, json, os
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
wid = os.environ.get("YABAI_WINDOW_ID"); pid = os.environ.get("YABAI_PROCESS_ID")
cand = [w for w in ws if wid and str(w["id"]) == wid] \
    or [w for w in ws if w.get("has-focus")] \
    or [w for w in ws if pid and str(w["pid"]) == pid and w.get("sub-layer") == "below" and w.get("is-visible")]
if not cand: sys.exit(0)
w = cand[0]
if w.get("sub-layer") != "below": sys.exit(0)
f = w["frame"]
print("%s\t%d\t%d %d %d %d" % (w["app"], w["id"], f["x"], f["y"], f["w"], f["h"]))' 2>/dev/null)
[[ -z "$hit" ]] && exit 0

IFS=$'\t' read -r app wid geom <<< "$hit"
RES=$(bash "$SLOTS/slotlib.sh" clicked "$app" "$wid" "$geom" 2>/dev/null | tail -1)
PREV="${RES%%|*}"; NEW="${RES##*|}"
[[ -n "$NEW" ]] && "$SLOTS/cad_handoff.sh" "$PREV" "$NEW"
exit 0
