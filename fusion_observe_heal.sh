#!/bin/bash
# fusion_observe_heal.sh — make sure yabai actually OBSERVES Fusion's main window.
#
# Fusion is a Qt app; its main canvas window races yabai's AX observer at creation,
# and yabai sometimes never attaches an AX element to it. Such a window shows up in
# `yabai -m query --windows` with has-ax-reference=false / role='' and yabai REFUSES
# to act on it ("could not locate the window to act on!") — so it can't be moved to
# the `below` sub-layer. That breaks the atomic slot reveal: when you swipe away from
# Fusion, scene_restore can't lower it behind the revealed split, so Fusion bleeds
# through / appears stuck on top. (The window is a perfectly normal AXStandardWindow
# via the AX API directly — it's purely a yabai observation gap.)
#
# A `yabai --restart-service` re-enumerates every app's windows and picks the canvas
# up cleanly (verified: has-ax flips to true, --sub-layer then succeeds). layout is
# `float`, so the restart moves no windows; sub-layers reset to normal but the next
# reveal re-applies them. We only restart when the window is genuinely unobserved, so
# this is a no-op on a healthy launch and runs at most once per Fusion launch.
#
# Wired to yabai's `application_launched app="^(Autodesk )?Fusion$"` signal (yabairc).
# Safe to run by hand anytime: `fusion_observe_heal.sh`.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
LOG=/tmp/yabai_debug.log
log() { echo "[$(date '+%H:%M:%S.%3N')] [fusion_observe_heal] $*" >> "$LOG"; }

# Is Fusion's main (largest, non-floating) window unobserved by yabai? Prints the id
# if it needs healing, nothing if it's already fine or Fusion has no canvas yet.
needs_heal() {
  yabai -m query --windows 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
cand = [w for w in ws
        if "Fusion" in (w.get("app") or "")
        and not w.get("is-minimized")
        and (w.get("frame") or {}).get("w", 0) > 600]
if not cand: sys.exit(0)                       # canvas not up yet
big = max(cand, key=lambda w: w["frame"]["w"] * w["frame"]["h"])
if not big.get("has-ax-reference", True):      # yabai cannot act on it → heal
    print(big["id"])'
}

# One healer at a time: the restart below re-runs yabairc, which launches another.
# The older one keeps polling (it survives the restart); the newcomer just leaves.
if [[ $(pgrep -f "$0" | grep -vc "^$$\$") -gt 0 ]]; then exit 0; fi

# Poll up to ~5 min for Fusion's canvas (cold launch is slow), healing as soon as it
# is unobserved. A restart that did not take (the canvas was still being created)
# is retried once the cooldown passes, instead of giving up — 2026-10-10: the one
# restart fired mid-launch, the guard then blocked every retry, and slots sent the
# user to an empty desktop because yabai could not move the window.
for _ in $(seq 1 600); do
  id=$(needs_heal)
  if [[ -n "$id" ]]; then
    # Cooldown between restarts (bounded by the 5 min poll: at most a handful).
    TS=/tmp/.fusion_heal_ts
    now=$(date +%s); last=$(stat -f %m "$TS" 2>/dev/null || echo 0)
    if (( now - last < 45 )); then
      sleep 5; continue                         # cooldown: look again, don't quit
    fi
    touch "$TS"
    log "Fusion canvas $id is unobserved by yabai → restarting yabai to re-observe"
    yabai --restart-service
    sleep 2
    after=$(needs_heal)
    [[ -z "$after" ]] && { log "heal OK: canvas now observed"; exit 0; }
    log "heal FAILED: still unobserved ($after) — will retry after cooldown"
    continue
  fi
  # If a canvas exists AND is already observed, nothing to do.
  if yabai -m query --windows 2>/dev/null | /usr/bin/python3 -c '
import sys, json
ws=json.load(sys.stdin)
ok=any("Fusion" in (w.get("app") or "")
       and (w.get("frame") or {}).get("w",0)>600 and w.get("has-ax-reference")
       for w in ws)
sys.exit(0 if ok else 1)'; then
    log "Fusion canvas already observed — no heal needed"
    exit 0
  fi
  sleep 0.5
done
log "gave up waiting for Fusion canvas window"
