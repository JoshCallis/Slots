#!/bin/bash
# slotlib.sh — slot/space state engine. See slots/MODEL.md for behaviour.
#
# Dispatch:  slotlib.sh <op> [args]
#   init                         build sequence from APPS if state empty
#   nav      <+1|-1>             swipe to adjacent slot, restore it
#   snap     <position>          snap front app into current slot (full = fills it)
#   placeapp <App>               give an unassigned app its own new full slot,
#                                spliced next to its canonical neighbour
#   fullnew                      transplant front app to a new full slot to the right
#   activate <App>               bring app to front (non-swipe)
#   close                        quit front app, clean up its slot(s)
#   winclose                     slot-aware close of the front window
#   destroy                      drop the current slot; its solo apps go unassigned
#   appterm                      an app quit (any means): prune it, destroy a bare
#                                full-screen space it left behind
#   pin                          re-assert floater sub-layers + snapped-tile
#                                shadow-strip across ALL spaces (yabai startup)
#   spacesync                    native spaces: follow a desktop switch macOS made
#   spacebind                    native spaces: bind the current slot to the active desktop
#   dump                         print state (debug)
#
# Test hooks (env):
#   SLOT_STATE_DIR   dir for state files            (default /tmp)
#   SLOT_FRONT       override frontmost app name     (default: frontmost_app)
#   SLOT_DRYRUN=1    skip window moves / activation / restore (logic only)
#   SLOT_APPS        space-separated app list        (default: built-in)
#   SLOT_RUNNING     newline list of running apps for `appterm` (default: live AX)

export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"

SDIR="${SLOT_STATE_DIR:-/tmp}"
SEQ="$SDIR/slot_seq"          # ordered slot IDs (sequence)
MEM="$SDIR/slot_members"      # slotID|app|position|z
LP="$SDIR/app_lastpos"        # app|position
CUR="$SDIR/current_slot"      # current slot ID
PREVF="$SDIR/prev_slot"       # slot we were on before the current one (for winclose)
MRU="$SDIR/app_mru"           # apps switched to via slots, most recent first (layout tie-break)
SC="$SDIR/slot_counter"
ZC="$SDIR/z_counter"
DIMS_CACHE="$SDIR/screen_dims"
LOG="${SLOT_LOG:-/tmp/slots.log}"

# ── central settings ──────────────────────────────────────────────────────────
# All user-tunable, per-app configuration lives in config/settings.json (the file
# the future settings GUI edits). The loader compiles it to a sourced cache and
# defines, for everyone: APPS (canonical order), PLACE_LAYOUTS (placeapp pairing,
# see slots/MODEL.md §Custom default layouts), CAD_APPS / CAD_MATCH_NAMES, and the
# settings_normalize / settings_open_name / settings_alt_names / settings_resolve
# name maps. Schema + failure ladder: config/gen_settings.py + load_settings.sh.
source /Users/josh/Code/Scripts/config/load_settings.sh

# Test overrides (env): SLOT_APPS replaces the canonical list; SLOT_LAYOUTS — if
# SET, even to "" — replaces the layouts, one "PRIMARY|spec" entry per line.
[[ -n "$SLOT_APPS" ]] && IFS=' ' read -r -a APPS <<< "$SLOT_APPS"
if [[ -n "${SLOT_LAYOUTS+x}" ]]; then
  PLACE_LAYOUTS=(); _ll=""
  while IFS= read -r _ll; do [[ -n "$_ll" ]] && PLACE_LAYOUTS+=("$_ll"); done <<< "$SLOT_LAYOUTS"
fi

log() { echo "[$(date '+%H:%M:%S')] [slots] $*" >> "$LOG"; }

# ── name mapping (tables from config/settings.json via the loader) ────────────
normalize()  { settings_normalize "$1"; }   # CGWindowOwnerName / loose → state key
open_name()  { settings_open_name "$1"; }   # state key → name for activate/scene_restore

# System UI surfaces that frontmost_app can momentarily report (mid-gesture, or
# when the desktop/menu-bar owns the topmost layer-0 window). These are never a
# window the user snapped, so they must not be recorded as slot members — and, in
# the failsafe reconcile, they neither join a slot nor cover anything.
#
# `borders` (JankyBorders) belongs here for a stronger reason than the rest. Its
# overlay is a real on-screen window owned by a real process, so win_list reports
# it and every failsafe adopted it: a floater member of EVERY slot, injected back
# into every restore by global_floaters, and re-raised on every navigation — work
# done on a decoration that has no focus and no meaning. Worse, the overlay sits
# 10px OUTSIDE the window it decorates and ABOVE it in z, so in the coverage walk
# it fully covers the very window it is drawing around: any tile it decorated
# could be dropped from the slot as "hidden". It is paint, not a window.
is_system_surface() {
  case "$1" in
    "Window Server"|"WindowServer"|"Dock"|"WindowManager"|"SystemUIServer"|\
    "Control Center"|"Controlce"|"Notification Center"|"NotificationCenter"|\
    "Spotlight"|"Wallpaper"|"Universal Control"|"loginwindow"|"borders"|"") return 0 ;;
    *) return 1 ;;
  esac
}

front_app() {
  local f
  if [[ -n "$SLOT_FRONT" ]]; then f="$SLOT_FRONT"; else f="$(frontmost_app 2>/dev/null)"; fi
  is_system_surface "$f" && return     # echo nothing → callers no-op safely
  normalize "$f"
}

# The app that actually owns keyboard focus, which is NOT the same as front_app.
# frontmost_app reports the topmost window in z-order — and floaters are deliberately
# kept on top of the snapped windows beneath them. So front_app names whatever floats
# on top, even when the user is typing in (and means to snap) the window underneath.
# snap must act on the focused app, so resolve it via the frontmost *process* (the one
# owning the menu bar), which floaters raised without focus do not become.
focused_app() {
  local f
  if [[ -n "$SLOT_FRONT" ]]; then
    f="$SLOT_FRONT"
  else
    f="$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)"
  fi
  is_system_surface "$f" && return     # echo nothing → callers no-op safely
  normalize "$f"
}

# Is state-key app present in a newline-list of running process names? An app may
# report under any of its owner spellings (settings_alt_names — e.g. Fusion is
# sometimes "Autodesk Fusion"), so match every one.
app_running() {
  local app="$1" tokens="$2" n
  while IFS= read -r n; do
    [[ -n "$n" ]] && echo "$tokens" | grep -qxF "$n" && return 0
  done < <(settings_alt_names "$app")
  return 1
}

# ── counters ──────────────────────────────────────────────────────────────────
next_slot() { local n; n=$(( $(cat "$SC" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SC"; echo "s$n"; }
next_z()    { local n; n=$(( $(cat "$ZC" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ZC"; echo "$n"; }

# ── sequence helpers ──────────────────────────────────────────────────────────
seq_read()  { [[ -f "$SEQ" ]] && grep -v '^$' "$SEQ" || true; }
seq_write() { : > "$SEQ.tmp"; local s; for s in "$@"; do echo "$s" >> "$SEQ.tmp"; done; mv "$SEQ.tmp" "$SEQ"; }
# Populates global array SEQ_ARR (bash 3.2 has no local namerefs).
seq_array() { SEQ_ARR=(); local l; while IFS= read -r l; do [[ -n "$l" ]] && SEQ_ARR+=("$l"); done < <(seq_read); }
seq_append() { echo "$1" >> "$SEQ"; }

seq_index() {                 # echo index of slot in seq, or -1
  local target="$1" i=0; local s
  while IFS= read -r s; do [[ "$s" == "$target" ]] && { echo "$i"; return; }; i=$((i+1)); done < <(seq_read)
  echo -1
}

seq_insert_after() {          # insert NEW immediately after AFTER (or at end if AFTER absent)
  local after="$1" new="$2" out=() s placed=0
  seq_array
  for s in "${SEQ_ARR[@]}"; do
    [[ "$s" == "$new" ]] && continue        # remove existing copy first
    out+=("$s")
    if [[ "$s" == "$after" ]]; then out+=("$new"); placed=1; fi
  done
  [[ $placed -eq 0 ]] && out+=("$new")
  seq_write "${out[@]}"
}

seq_remove() {                # remove slot from sequence
  local del="$1" out=() s
  seq_array
  for s in "${SEQ_ARR[@]}"; do [[ "$s" != "$del" ]] && out+=("$s"); done
  if [[ ${#out[@]} -eq 0 ]]; then : > "$SEQ"; else seq_write "${out[@]}"; fi
}

# ── membership helpers ────────────────────────────────────────────────────────
# All MEM/LP mutations go through these two: run an awk filter (the program keeps
# the lines it prints) and atomically write the result back. One place owns the
# tmp-file + mv dance instead of every helper repeating it.
mem_keep() { awk -F'|' "$@" "$MEM" 2>/dev/null > "$MEM.tmp" || true; mv "$MEM.tmp" "$MEM"; }
lp_keep()  { awk -F'|' "$@" "$LP"  2>/dev/null > "$LP.tmp"  || true; mv "$LP.tmp"  "$LP";  }

members_of() {                # slotID → "app|position|z" lines, sorted by z asc
  awk -F'|' -v s="$1" '$1==s{print $2"|"$3"|"$4}' "$MEM" 2>/dev/null | sort -t'|' -k3,3n
}
slot_member_count() { awk -F'|' -v s="$1" '$1==s' "$MEM" 2>/dev/null | grep -c '^' ; }
app_slots()       { awk -F'|' -v a="$1" '$2==a{print $1"|"$3}' "$MEM" 2>/dev/null; }  # slot|pos

set_member() {                # slot app pos  → upsert at top of z-order
  local slot="$1" app="$2" pos="$3" z; z=$(next_z)
  mem_keep -v s="$slot" -v a="$app" '!($1==s && $2==a)'
  echo "$slot|$app|$pos|$z" >> "$MEM"
}
remove_member()               { mem_keep -v s="$1" -v a="$2" '!($1==s && $2==a)'; }   # slot app
remove_app_everywhere()       { mem_keep -v a="$1" '$2!=a'; }                          # app
remove_app_everywhere_in_slot() { mem_keep -v s="$1" '$1!=s'; }                        # slot (wipe)
# remove app from OTHER slots whose recorded pos != newpos (resize ⇒ no longer fits)
remove_app_diffpos_except()   { mem_keep -v a="$1" -v np="$2" -v keep="$3" \
                                  '!($2==a && $1!=keep && $3!=np)'; }                  # app newpos keepslot
# Floater twin of remove_app_diffpos_except: instead of EVICTING copies of a moved
# window from other slots, UPDATE their position to newpos so every space remembers
# where the user last left it. Only touches OTHER slots' *floating* entries (a
# literal "x,y,w,h" pos); a copy snapped to a tile elsewhere keeps its tile.
sync_app_pos_except()         { mem_keep -v a="$1" -v np="$2" -v keep="$3" -v OFS='|' \
                                  '$2==a && $1!=keep && $3 ~ /,/ { $3=np } 1'; }        # app newpos keepslot
lastpos()       { awk -F'|' -v a="$1" '$1==a{print $2; exit}' "$LP" 2>/dev/null; }
set_lastpos()   { lp_keep -v a="$1" '$1!=a'; echo "$1|$2" >> "$LP"; }                  # app pos
clear_lastpos() { lp_keep -v a="$1" '$1!=a'; }                                         # app

get_current() { cat "$CUR" 2>/dev/null; }
set_current() { echo "$1" > "$CUR"; }
# The slot we were on before the current one — recorded only on a real inter-slot
# move (nav / navapp / placeapp) so winclose can land "back where we came from".
get_prev() { cat "$PREVF" 2>/dev/null; }
set_prev() { echo "$1" > "$PREVF"; }
# Move to a different slot, remembering the one we left (no-op record if same).
goto_slot() { local from="$1" to="$2"; [[ "$to" != "$from" ]] && set_prev "$from"; set_current "$to"; }

# destroy any empty slot; if current was destroyed, move current to a neighbour
destroy_empty_slots() {
  seq_array
  local s cur; cur=$(get_current)
  local newcur="$cur"
  local prev=""
  for s in "${SEQ_ARR[@]}"; do
    if [[ "$(slot_member_count "$s")" -eq 0 ]]; then
      [[ "$s" == "$cur" ]] && newcur="$prev"
      seq_remove "$s"
    else
      prev="$s"
    fi
  done
  # if current ended up empty/unset, fall back to first slot in seq
  if [[ -z "$newcur" || "$(slot_member_count "$newcur")" -eq 0 ]]; then
    newcur=$(seq_read | head -1)
  fi
  set_current "$newcur"
}

# Where to land when slot DEAD is about to be removed from the sequence: the
# space we were on last if it's still around (gives the "left or right depending
# on which we came from" feel), else DEAD's left neighbour (wrapping). Call while
# DEAD is still in the sequence; echoes "" only if DEAD is the sole slot.
land_after_destroy() {          # deadSlot → slot to land on (or "")
  local dead="$1"; seq_array
  local n=${#SEQ_ARR[@]}; [[ $n -le 1 ]] && { echo ""; return; }
  local prev; prev=$(get_prev)
  if [[ -n "$prev" && "$prev" != "$dead" ]] && printf '%s\n' "${SEQ_ARR[@]}" | grep -qxF "$prev"; then
    echo "$prev"; return
  fi
  local i idx=-1
  for i in "${!SEQ_ARR[@]}"; do [[ "${SEQ_ARR[$i]}" == "$dead" ]] && idx=$i; done
  [[ $idx -lt 0 ]] && { echo "${SEQ_ARR[0]}"; return; }
  echo "${SEQ_ARR[$(((idx-1+n)%n))]}"
}

# ── geometry ──────────────────────────────────────────────────────────────────
# Probe the screen rectangle the slots live on. Echoes "w h", or nothing if both
# sources fail (callers already treat an empty result as "skip this pass").
#
# yabai's display frame is the authority: one display, in points. We take the
# display whose frame ORIGIN IS 0,0 — the main display — because pos_rect anchors
# every tile at "0 0" (see below); pairing some other display's SIZE with the main
# display's ORIGIN would place correctly-sized tiles on the wrong screen. Falls
# back to the focused display if none reports 0,0.
#
# The Finder desktop-bounds AppleScript is a last resort only (and 20x slower):
# with a second display EXTENDED it returns the bounding box of ALL desktops — a
# 1728-wide built-in beside a 1920-wide external answers "3648 1117", so every
# tile gets computed against a screen that doesn't exist. That is exactly the
# 2026-08-19 breakage. Mirrored displays collapse to one desktop, so it's right
# there, which is what makes it safe as a fallback.
#
# TWO yabai queries, because on macOS 26 with yabai 7.1.22 the ENUMERATION
# (`--displays`, and `--spaces` likewise) answers a bare `[` while the singular
# form (`--displays --display`) answers correctly. Without the second attempt
# every probe fell through to the Finder AppleScript below — the path this
# function's own comment calls 20x slower — on every cache miss. The singular
# query is only trusted when its frame origin IS 0,0, i.e. it happens to be the
# main display: pairing another display's size with the main display's origin is
# exactly the wrong-screen bug the enumeration was written to avoid.
screen_dims_probe() {
  local w h src
  for src in "--displays" "--displays --display"; do
    read -r w h < <(yabai -m query $src 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try: ds = json.load(sys.stdin)
except Exception: sys.exit(0)
if isinstance(ds, dict): ds = [ds]
def frame(d): return d.get("frame") or {}
main = next((d for d in ds if not frame(d).get("x") and not frame(d).get("y")), None)
if main is None and len(ds) > 1: main = next((d for d in ds if d.get("has-focus")), ds[0])
if main is None: sys.exit(0)
f = frame(main)
w, h = int(f.get("w") or 0), int(f.get("h") or 0)
if w and h: print(w, h)' 2>/dev/null)
    [[ -n "$w" && -n "$h" ]] && break
  done
  if [[ -z "$w" || -z "$h" ]]; then
    read -r w h < <(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
      | awk -F', ' '{print $3, $4}')
  fi
  # UI Zoom's screen zoom (ui_zoom.sh § Screen zoom, pinned top-left): only the
  # top-left w/z × h/z is visible, so that is the screen tiles are cut from. Same
  # truncation as scene_restore --zoom, so a probe agrees with the glide's last frame.
  local z; z=$(cat /tmp/.screen_zoom 2>/dev/null)
  if [[ -n "$w" && -n "$h" && -n "$z" ]]; then
    read -r w h < <(awk -v w="$w" -v h="$h" -v z="$z" \
      'BEGIN { if (z > 1) { w = int(w / z); h = int(h / z) } print w, h }')
  fi
  [[ -n "$w" && -n "$h" ]] && echo "$w $h"
}
# Cached because this is read on every snap, reconcile and window event. The
# cache is written ONCE and then never re-checked, so it MUST be invalidated
# whenever the display setup changes — a stale entry from a monitor that is no
# longer attached sizes every tile wrongly AND stops a genuinely full-screen
# window from matching `full`, so it gets recorded as a literal-geometry floater
# instead. Invalidation is event-driven, not polled: config/yabai/yabairc drops
# the file on display_{added,removed,changed,resized}, and both reset scripts
# clear it too. Only a non-empty probe is cached, so a transient failure (yabai
# restarting, Finder busy) can't pin a bogus size.
screen_dims() {
  if [[ ! -s "$DIMS_CACHE" ]]; then
    screen_dims_probe > "$DIMS_CACHE.tmp" 2>/dev/null
    if [[ -s "$DIMS_CACHE.tmp" ]]; then mv "$DIMS_CACHE.tmp" "$DIMS_CACHE"
    else rm -f "$DIMS_CACHE.tmp"; fi
  fi
  cat "$DIMS_CACHE" 2>/dev/null
}
# Did the display setup change moments ago? When the external monitor drops out
# (sleep / dark wake with the lid shut, cable, input switch) macOS shoves every
# window onto whatever screen is left, then back again when it returns. A reconcile
# in that window reads those shoved geometries as the user's arrangement — every
# snapped member recorded as a literal-geometry floater (seen 2026-09-25:
# "0,32,863,1085|Claude") — and the corrupted state outlives the display blip.
# slots/display_event.sh stamps DISPLAY_TS on every display_* signal; until it is
# DISPLAY_SETTLE seconds old, reconciles leave the recorded state alone.
DISPLAY_TS=/tmp/.slot_display_ts
DISPLAY_SETTLE=20
display_unsettled() {
  [[ -n "$SLOT_DRYRUN" ]] && return 1
  [[ -f "$DISPLAY_TS" ]] || return 1
  local now ts; now=$(date +%s); ts=$(stat -f %m "$DISPLAY_TS" 2>/dev/null || echo 0)
  (( now - ts < DISPLAY_SETTLE ))
}
# Single source of truth for position → screen rectangle. Echoes "x y w h"
# (empty for an unknown position). Used by snap, win-detection, and the failsafe.
pos_rect() {                  # pos → "x y w h"   (pos = tile name OR literal "x,y,w,h")
  case "$1" in *,*) echo "${1//,/ }"; return ;; esac   # literal geometry
  local sw sh; read -r sw sh < <(screen_dims)
  local hw=$((sw/2)) hh=$((sh/2))
  # Left-edge tiles are pulled in 1px on their right edge (x stays 0, width hw-1),
  # leaving a clean 1px seam between a left- and a right-snapped window. Detection
  # (pin_loose_above / tile_for_geom / scene_restore is_tile) uses the same inset so
  # a left window still classifies as `left`.
  local lw=$((hw-1))
  case "$1" in
    full)         echo "0 0 $sw $sh" ;;
    left)         echo "0 0 $lw $sh" ;;
    right)        echo "$hw 0 $hw $sh" ;;
    top-left)     echo "0 0 $lw $hh" ;;
    top-right)    echo "$hw 0 $hw $hh" ;;
    bottom-left)  echo "0 $hh $lw $hh" ;;
    bottom-right) echo "$hw $hh $hw $hh" ;;
  esac
}

# ── effects (skipped under SLOT_DRYRUN) ───────────────────────────────────────

# Is the scripting addition usable? Everything below that touches sub-layers or
# shadows depends on it, and the answer is cached in /tmp/.yabai_sa_loaded by
# yabai_sa_probe.sh (yabairc runs it at start and on dock_did_restart).
#
# The guard used to be a bare `[[ -f /tmp/.yabai_sa_loaded ]] || return 0`, which
# made a WRONG sentinel unrecoverable: the file is written from a loader whose exit
# code lies (see yabai_sa_probe.sh), and once it was missing, pin_loose_above,
# unstick_sublayers and window_event.sh were all silent no-ops until the next yabai
# restart — snapped tiles keeping their drop shadows with nothing logged anywhere.
#
# So a missing sentinel is now a question, not a verdict: re-probe (the script
# rate-limits itself to once every 30s, so a machine genuinely without the SA does
# not pay for it on every op) and re-read. The common case — sentinel present — is
# a bash file test and forks nothing.
SA_SENTINEL=/tmp/.yabai_sa_loaded
SA_PROBE=/Users/josh/Code/Scripts/yabai_sa_probe.sh
sa_ready() {
  [[ -f "$SA_SENTINEL" ]] && return 0
  [[ -x "$SA_PROBE" ]] && "$SA_PROBE" --ensure >/dev/null 2>&1
  [[ -f "$SA_SENTINEL" ]]
}
# Pull every window off yabai's `below` sub-layer back to `normal`. A multi-
# window restore reveals its group by pushing the windows that cover it to
# `below` (a `below` window can't be lifted above a `normal` one by app
# activation — that's what makes the reveal atomic and stagger-free). But that
# leaves those covers stuck `below`, where a later single-app activation can't
# raise them to the front. So before activating a single app we normalise the
# whole layer: cheap (one query; usually only a couple are non-normal) and it
# lets the activated app cover the previous group as expected. No-op without the
# scripting addition (sub-layer is unavailable / nothing was ever lowered).
unstick_sublayers() {
  sa_ready || return 0
  yabai -m query --windows 2>/dev/null | /usr/bin/python3 -c '
import sys, json
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
for w in ws:
    if w.get("sub-layer") not in ("normal", None): print(w["id"])' 2>/dev/null \
  | while read -r id; do yabai -m window "$id" --sub-layer normal 2>/dev/null; done
}
# Every name a canonical (sequence) app may appear under in a window list, one per
# line: both its state-key (e.g. "Fusion") and its open_name (e.g. "Autodesk
# Fusion"), since yabai's `app` field can use either spelling. Used by
# pin_loose_above and passed to scene_restore (SLOT_CANON_NAMES) so a canon app is
# never misread as a loose floater whichever spelling it shows up as.
canon_open_names() {
  local a o; for a in "${APPS[@]}"; do
    echo "$a"; o=$(open_name "$a"); [[ "$o" != "$a" ]] && echo "$o"
  done
}

# The Fusion companion windows (config/fusion_companions), one per line. They ride
# with Fusion's slot: floaters there, buried under the scene everywhere else.
fusion_companion_names() {
  grep -v '^[[:space:]]*#' /Users/josh/Code/Scripts/config/fusion_companions 2>/dev/null \
    | grep -v '^[[:space:]]*$' || true
}
# 0 if Fusion (any spelling) is a member of slot $1.
fusion_in_slot() {
  local a; for a in Fusion "$(open_name Fusion)"; do is_member "$1" "$a" && return 0; done
  return 1
}

# Every name an app RECORDED AS A FLOATER (literal "x,y,w,h" position) anywhere may
# appear under in a window list — state-key and open_name — one per line, deduped.
# A recorded floater is kept on top regardless of its current SIZE, so a floater
# that happens to be tile-sized (e.g. Finder filling a quarter) is still a floater,
# not mistaken for a snapped window.
floater_open_names() {
  awk -F'|' '$3 ~ /,/{print $2}' "$MEM" 2>/dev/null | sort -u | while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    echo "$a"; o=$(open_name "$a"); [[ "$o" != "$a" ]] && echo "$o"
  done
}

# The mirror of the above: every name an app RECORDED AS SNAPPED (a tile-NAME
# position, i.e. not literal geometry) in any slot may appear under. Read from $MEM,
# not from a window query, on purpose — membership is global, so this answers for
# every space at once and does not shrink to whatever happens to be on the current
# one. That matters because it drives borders' whitelist below: computing it per
# space would drop a border from every app snapped elsewhere and put it back on the
# next swipe.
#
# `full` tiles are left out: a window filling the screen needs no line, and some
# (Photoshop) don't reach the screen's top/bottom, so the line left a coloured margin
# there. An app snapped full in one slot and half in another still gets one (app-level).
snapped_open_names() {
  awk -F'|' '$3 !~ /,/ && $3 != "full"{print $2}' "$MEM" 2>/dev/null | sort -u | while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    echo "$a"; o=$(open_name "$a"); [[ "$o" != "$a" ]] && echo "$o"
  done
}

# ── JankyBorders: only snapped windows get a line ─────────────────────────────
# borders filters by APP NAME only — no per-window rule — so "floaters get no
# border" has to be expressed as a list of apps, recomputed whenever membership
# changes. We push a WHITELIST (default-deny) rather than extending the blacklist:
# a blacklist would have to name every app on the machine that might ever float,
# which is unmaintainable and was exactly the bug — ExpressVPN and anything else
# nobody had listed got a border. Whitelisted = recorded at a tile position
# somewhere, minus config/borders_exclude (see that file; subtracting it here is
# what guarantees no app is ever in both lists).
#
# Consequences worth knowing, both inherent to borders being app-level:
#   * An app with BOTH a snapped window and a floating one (Finder tiled plus a Get
#     Info panel) is whitelisted, so the panel gets a border too.
#   * An app snapped by hand is whitelisted only once the reconcile has RECORDED it
#     (window_event.sh, on drag end) — a beat after it lands, not during the drag.
BORDERS_WL_CACHE=/tmp/.borders_whitelist
BORDERS_EXCLUDE=/Users/josh/Code/Scripts/config/borders_exclude
borders_sync() {
  [[ -n "$SLOT_DRYRUN" ]] && return
  command -v borders >/dev/null 2>&1 || return 0
  # NEVER push at a borders that isn't running: `borders <args>` with nothing up
  # SPAWNS a fresh instance carrying only the args we pass — no width, no colour,
  # no blacklist — which is worse than no line at all. Same rule borders_theme.sh
  # follows, and the reason both only ever UPDATE an instance yabairc created.
  #
  # pgrep is NECESSARY BUT NOT SUFFICIENT (2026-09-22): it answers "process exists",
  # while a push hands off only once borders has bound its mach service, a beat later.
  # The boot pin runs ~4s after launch so it is usually clear, but a yabai reload can
  # land inside that gap — so the push is also verified AFTERWARDS, below.
  local pid; pid=$(pgrep -x borders 2>/dev/null | head -1)
  [[ -z "$pid" ]] && return 0
  local want
  want=$(snapped_open_names \
         | grep -vxF -f <(sed 's/#.*//' "$BORDERS_EXCLUDE" 2>/dev/null \
                          | sed '/^[[:space:]]*$/d') \
         | paste -sd, -)
  # An EMPTY whitelist is inactive to borders, i.e. everything gets a line again —
  # and with `full` tiles excluded, "nothing half-snapped" is common (every slot
  # full-screen). Push a name no app has instead, so default-deny holds.
  [[ -z "$want" ]] && want="_no_app_"
  #
  # The cache is keyed on borders' PID, not just the list. A yabai restart (or any
  # hand restart) kills borders and relaunches it from yabairc with the BLACKLIST
  # ONLY — the whitelist is ours to push. Caching the list alone would then find it
  # unchanged and skip the push, leaving the new instance with no whitelist at all,
  # i.e. a border on everything, silently, until membership next happened to change.
  local stamp="$pid:$want"
  [[ "$stamp" == "$(cat "$BORDERS_WL_CACHE" 2>/dev/null)" ]] && return 0
  # Push, then CHECK IT HANDED OFF: a delivered push exits at once, one that became a
  # duplicate server runs forever — that is the only reliable tell that the mach service
  # wasn't up (see the pgrep note above). All of it in the background, so a slot op never
  # waits 0.5s on the border. The cache is written only on success, so a push that had to
  # be killed is retried by the next op rather than being recorded as delivered.
  {
    borders whitelist="$want" >/dev/null 2>&1 &
    bp=$!
    sleep 0.5
    if kill -0 "$bp" 2>/dev/null; then
      kill "$bp" 2>/dev/null
    else
      printf '%s' "$stamp" > "$BORDERS_WL_CACHE"
    fi
  } >/dev/null 2>&1 &
}

# Enforce the floater layer invariant in one window query: floaters on top,
# snapped windows beneath them. Three-way priority per on-screen window:
#   1. RECORDED floater (its app is a literal-geometry member somewhere) → `above`,
#      even if its current size matches a tile. Recorded intent beats geometry, so
#      a tile-sized floater (Finder in a quarter) is still kept on top — this is
#      what makes "summon it → it appears in front" reliable.
#   2. CANON app, or an unrecorded TILE-sized window → snapped → pulled off `above`
#      back to `normal` if stuck there. A snapped window must NEVER be sticky (else
#      it competes with real floaters — the "in front of one app but not the other
#      for a moment" stagger).
#   3. Anything else (unrecorded, non-canon, non-tile) → a loose floater → `above`,
#      so a single-app activate or stray reveal can never bury it (the Wispr case).
# `below` windows are left untouched — they are a reveal's parked covers and
# yanking them up would collapse the stagger-free composite. Cheap (one window
# query); no-op without the scripting addition.
#
# Scope: current space by default (the hot-path calls). `pin_loose_above all`
# reconciles EVERY space's windows in one pass — used by the `pin` op at yabai
# startup / SA reload, when `yabai -m config window_shadow on` has just
# re-shadowed every window on every space and waiting for each space to be
# visited would leave stale shadows behind.
pin_loose_above() {
  [[ -n "$SLOT_DRYRUN" ]] && return
  # Keep borders' whitelist in step with membership, BEFORE the SA gate: it needs
  # neither the scripting addition nor anything this function computes, and riding
  # along here is how it hears about every change — this is the one call every op
  # that snaps, reveals, reclassifies or prunes a member already makes.
  borders_sync
  sa_ready || return 0
  local sw sh; read -r sw sh < <(screen_dims)
  [[ -z "$sw" ]] && return
  local qargs=(--windows --space)
  [[ "$1" == "all" ]] && qargs=(--windows)
  local canon floaters
  canon=$(canon_open_names)
  floaters=$(floater_open_names)
  # Fusion's companion windows are floaters only where Fusion itself is shown.
  local companions="" cur; cur=$(get_current)
  fusion_in_slot "$cur" || companions=$(fusion_companion_names)
  yabai -m query "${qargs[@]}" 2>/dev/null | /usr/bin/python3 -c '
import sys, json
canon    = set(l for l in sys.argv[1].split("\n") if l)
floaters = set(l for l in sys.argv[4].split("\n") if l)
buried   = set(l for l in sys.argv[5].split("\n") if l)   # companions of a Fusion not in this slot
sw, sh = int(sys.argv[2]), int(sys.argv[3])
sys.path.insert(0, "/Users/josh/Code/Scripts/slots"); import zoomtiles as zt
def is_tile(f):   # a tile today, or at another UI Zoom level (a window last shown there)
    return bool(zt.tile_of((f["x"], f["y"], f["w"], f["h"]), sw, sh, None, sys.argv[6]))
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
for w in ws:
    if w.get("is-minimized"): continue
    f = w.get("frame") or {}
    if not f: continue
    sub = w.get("sub-layer"); app = w.get("app")
    # Classify floater vs snapped ONCE; the same verdict drives sub-layer and shadow.
    if app in buried:                            # Fusion companion, Fusion not here → under
        floater = False
        if sub != "below": print(w["id"], "sublayer", "below")
    elif app in floaters:                        # recorded floater → always on top
        floater = True
        if sub != "above": print(w["id"], "sublayer", "above")
    elif app in canon or is_tile(f):             # snapped → never sticky
        floater = False
        if sub == "above": print(w["id"], "sublayer", "normal")
    else:                                        # unrecorded loose window → on top
        floater = True
        if sub != "above": print(w["id"], "sublayer", "above")
    # Drop shadow tracks the same split. Global window_shadow is ON (yabairc), so
    # every window keeps its native shadow — instantly rendered at composite time.
    # We therefore only ever STRIP shadow from snapped tiles; floaters are never
    # toggled, so their shadow never suffers the post-composite recompute lag (late /
    # half-rendered until dragged). desired has-shadow == floater, so a True floater
    # is left alone and a False (snapped) window is toggled flat. has-shadow is a bool
    # in the query; only toggle on disagreement (the SA exposes no absolute shadow
    # set, just --toggle), which keeps this idempotent across reconciles.
    # Remap (Control Room) draws its own 1px edge in CSS; a shadowed window also gets
    # the macOS 1px rim right beside it, doubling the line — so it stays flat even floating.
    # A window sitting on a tile reads as snapped, whatever slots recorded it as: flat.
    want = floater and app != "Remap" and not is_tile(f)
    have = w.get("has-shadow")
    # The verdict goes to shadow_guard (bin/shadow_guard.m), the one process that
    # toggles: --toggle is relative, and two pins toggling the same window at once
    # put its shadow straight back. Only without the guard do we toggle here.
    print(w["id"], "want", int(want), int(f["x"]), int(f["y"]), int(f["w"]), int(f["h"]))
    if isinstance(have, bool) and have != want: print(w["id"], "shadow")
' "$canon" "$sw" "$sh" "$floaters" "$companions" "$SDIR" 2>/dev/null \
  | { local guard=""   # pid file can be swept by macOS's /tmp cleaner: pgrep backs it up
      { kill -0 "$(cat /tmp/shadow_guard.pid 2>/dev/null)" 2>/dev/null || pgrep -qx shadow_guard; } && guard=1
      local wants=""
      while read -r id kind val rest; do
      case "$kind" in
        sublayer) yabai -m window "$id" --sub-layer "$val" 2>/dev/null ;;
        want)     wants+="$id $val $rest"$'\n' ;;
        shadow)   [[ -z "$guard" ]] && yabai -m window "$id" --toggle shadow 2>/dev/null ;;
      esac
      done
      # Whole-file swap: the guard never reads half a list. A current-space pass
      # keeps the other spaces' verdicts.
      if [[ -n "$guard" ]]; then
        { [[ "$1" != all ]] && awk 'NR==FNR { mine[$1]; next } !($1 in mine)' \
            <(printf '%s' "$wants") /tmp/.shadow_want 2>/dev/null
          printf '%s' "$wants"; } > /tmp/.shadow_want.$$ && mv -f /tmp/.shadow_want.$$ /tmp/.shadow_want
        notifyutil -p com.callis.shadowguard
      fi
    }
}

# ── effects: window ops (activate/restore/move/quit/hide/close) ─────────────
do_activate() {               # raise a single app (floaters kept on top)
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY activate $1"; return; }
  unstick_sublayers
  activate_app "$(open_name "$1")" 2>/dev/null
  pin_loose_above             # floaters back on top; snapped/raised window beneath
}

# Raise a FLOATER on top without disturbing the revealed scene beneath it.
# Unlike do_activate this must NOT run unstick_sublayers: the snapped windows
# under the floater are revealed by parking their cover windows on the `below`
# sub-layer, and unsticking would yank those covers back to `normal` — collapsing
# the reveal so the wrong window (whatever then sits topmost of an overlapping
# tile) shows once the floater is moved away. We only re-assert the floater layer
# (`pin_loose_above`) and activate; the snapped scene underneath is untouched.
raise_floater() {
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY raise_floater $1"; return; }
  # Pin the floater layer to `above` FIRST, via yabai sub-layer (synchronous with
  # the SA): the floater composites above every normal/below snapped window in a
  # single frame, so the activate below is only for keyboard focus and can't
  # re-stagger the z-order. Activating first instead would raise it gradually —
  # above some snapped apps a beat before others (the "takes a moment" stagger).
  spaces_on && floater_to_all_desktops "$1"
  pin_loose_above
  activate_app "$(open_name "$1")" 2>/dev/null
  pin_loose_above             # re-assert in case the activation shuffled anything
}

# Native spaces: a floater lives on every desktop (sticky — realize_plan keeps it so
# on each flip), but a window can still be stranded on one desktop (opened there, or
# unstuck while it was a snapped member). Activation doesn't follow it — macOS's
# switch-on-activate is off — so the app took focus with its window out of sight.
# Make the app's stranded windows sticky. Detached: the raise above isn't held for
# the ~40 ms window-server read; when nothing is stranded (the usual case) it does
# nothing, otherwise the window appears a beat after the focus.
floater_to_all_desktops() {
  local app="$1"
  ( local ids id
    ids=$("$HOME/bin/space_query" json 2>/dev/null | jq -r --arg a "$app" '
      ([.spaces[] | select(.active == 1 or .active == true) | .id]) as $act
      | .windows[] | select(.app == $a and (.spaces | length) == 1
                            and ((.spaces[0]) as $s | $act | index($s) | not)) | .id')
    [[ -z "$ids" ]] && exit 0
    for id in $ids; do yabai -m window "$id" --toggle sticky; done
    log "floater $app: windows $(echo $ids) were on another desktop → sticky"
    activate_app "$(open_name "$app")"
  ) </dev/null >/dev/null 2>&1 &
}
do_restore() {                # restore a slot's arrangement
  local slot="$1"
  if spaces_on; then realize_slot "$slot"; return; fi   # native spaces: flip to its desktop
  local args=() app pos z
  # members_of yields members back→front in captured z-order. Feed scene_restore
  # in exactly that order so the on-screen stacking is reproduced as it was left,
  # and the frontmost-captured window (the LAST arg) takes keyboard focus.
  #
  # No app-specific reordering. Forcing a particular app to the front/back (the old
  # "SketchUp last → focus" / "Fusion first → no focus" heuristics) inverts any
  # scene where something was deliberately captured on top of it — e.g. a Finder
  # window over SketchUp would get buried because SketchUp was promoted to front.
  # Exact restore wins over the heuristic; if a slot wants SketchUp on top, it was
  # captured on top and lands there naturally.
  while IFS='|' read -r app pos z; do
    [[ -z "$app" ]] && continue
    args+=("$(open_name "$app"):$pos")
  done < <(members_of "$slot")

  # Sticky floaters: a floating window (literal geom) lives on EVERY space, so
  # inject any global floater that isn't already a member of this slot. The slot's
  # own focus is its last member (members_of is z-ascending); pull it aside, append
  # the injected floaters, then restore the focus arg last so it still takes
  # keyboard focus. scene_restore tiers floaters to the `above` sub-layer no matter
  # the arg order, so they render on top regardless. (No-op when no floaters exist.)
  local nmem=${#args[@]} memargs=() i fa fg
  memargs=("${args[@]}"); args=()
  for ((i=0; i<nmem-1; i++)); do args+=("${memargs[$i]}"); done
  while IFS='|' read -r fa fg; do
    [[ -z "$fa" || -z "$fg" ]] && continue
    is_member "$slot" "$fa" && continue          # already represented in this slot
    args+=("$(open_name "$fa"):$fg")
  done < <(global_floaters)
  [[ $nmem -gt 0 ]] && args+=("${memargs[$((nmem-1))]}")   # focus member goes last

  [[ ${#args[@]} -eq 0 ]] && return
  if [[ -n "$SLOT_DRYRUN" ]]; then log "DRY restore $slot: ${args[*]}"; return; fi

  # Single member, no scripting addition: a plain activate is fine (and there's
  # no sub-layer to lower with). With the SA loaded we DON'T early-return —
  # scene_restore reveals even a solo app by lowering its covers, because plain
  # activation is not atomic (it raises the app gradually, so the multi-window
  # group it replaces recedes one window at a time — the reverse of the pop-in).
  if [[ ${#args[@]} -eq 1 ]] && ! sa_ready; then
    local a="${args[0]%%:*}"; do_activate "$(normalize "$a")"
    return
  fi

  # scene_restore freezes the display, positions the windows, then (SA loaded)
  # reveals the target by LOWERING every window covering it into yabai's `below`
  # sub-layer in one pass — atomic, no activate-fight — and unfreezes to a single
  # composite. Handles 1..N members. Backgrounded so do_restore returns at once.
  local sw sh; read -r sw sh < <(screen_dims)
  # SCENE_DEBUG left off: the per-run log work is pure overhead on the switch path.
  # Re-add `SCENE_DEBUG=1` here to capture /tmp/scene_restore.log when diagnosing.
  #
  # pin_loose_above runs AFTER the restore completes (same background job, so it
  # never races the reveal): scene_restore places windows and tiers sub-layers but
  # never touches shadows, so a window restored fresh (app relaunch, new window)
  # would keep its native shadow on a snapped tile until some other op pinned.
  local bury=""; fusion_in_slot "$slot" || bury="$(fusion_companion_names)"
  { SLOT_CANON_NAMES="$(canon_open_names)" SLOT_BURY_NAMES="$bury" \
      scene_restore "$sw" "$sh" "${args[@]}" >/dev/null 2>/dev/null
    pin_loose_above
    # Re-stamp the op guard: the reveal's own window moves and activations land
    # up to a second or two after the op started, and window_event.sh /
    # app_focused.sh must read them as ours, not as the user's.
    touch /tmp/.slot_op_ts 2>/dev/null
  } &
}
do_move() {                   # move one window to a position (snap)
  local app="$1" pos="$2"
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY move $app → $pos"; return; }
  local x y w h; read -r x y w h < <(pos_rect "$pos")
  [[ -z "$x" ]] && return
  # A tile on the top edge: push the app's title bar (settings `titlebar`, e.g.
  # Photoshop's 22px strip) above the screen. Readers clamp, so it's still the tile.
  if [[ "$y" == 0 ]]; then local tb; tb=$(settings_titlebar "$app"); (( tb > 0 )) && { y=$((-tb)); h=$((h+tb)); }; fi
  local se; se="$(open_name "$app")"
  # Target the app's MAIN document window, not "first window". An app like Fusion
  # keeps its palettes (Browser, Sketch Palette, …) as separate windows that can
  # sit at the front of the process's window list — snapping "first window" would
  # resize a palette instead of the document. AXMain is unique to the real main
  # window (palettes are never main); fall back to a standard window, then to the
  # first window if the app exposes neither.
  osascript 2>/dev/null <<APPLESCRIPT
tell application "System Events"
  tell (first process whose name is "$se")
    try
      try
        set theWin to first window whose value of attribute "AXMain" is true
      on error
        try
          set theWin to first window whose subrole is "AXStandardWindow"
        on error
          set theWin to first window
        end try
      end try
      set position of theWin to {$x, $y}
      set size of theWin to {$w, $h}
    end try
  end tell
end tell
APPLESCRIPT
}
do_quit() {
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY quit $1"; return; }
  osascript -e "tell application \"$(open_name "$1")\" to quit" 2>/dev/null
}
# Hide an app (all its windows leave the screen) without quitting it. Used when
# removing an app from one slot while it stays a member of another. scene_restore
# unhides it again when its other slot is restored.
do_hide() {
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY hide $1"; return; }
  osascript -e "tell application \"System Events\" to set visible of (first process whose name is \"$(open_name "$1")\") to false" 2>/dev/null
}
# Total number of open windows an app owns (across ALL spaces). >1 means hiding
# the whole process would yank windows out of other groups, so winclose acts on
# just the front window instead.
app_window_count() {
  [[ -n "$SLOT_DRYRUN" ]] && { echo "${SLOT_WINCOUNT:-1}"; return; }
  osascript -e "tell application \"System Events\" to count windows of (first process whose name is \"$(open_name "$1")\")" 2>/dev/null
}
# Close ONLY the frontmost window of an app (native close, via its close button),
# leaving the app and its other windows untouched. Used by winclose for
# multi-window apps (e.g. Finder) so other groups aren't disturbed.
do_close_front_window() {
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY close-front-window $1"; return; }
  osascript -e "tell application \"System Events\" to tell (first process whose name is \"$(open_name "$1")\") to click (first button of front window whose subrole is \"AXCloseButton\")" 2>/dev/null
}

# ── native spaces mode (config/slots_spaces) ─────────────────────────────────
# Each slot is bound to its own macOS desktop, so a switch is a window-server
# space flip (~25ms) instead of re-stacking every window on one space (~0.8s).
# The slot model above is unchanged; only how a slot is SHOWN differs:
#   realize_slot = move the members' windows onto the slot's desktop (usually
#   they're already there — only a window shared between slots, like Claude
#   beside Safari and beside Chrome, ever travels), fix their tiles, flip to the
#   desktop, focus the top member. Floaters are made sticky (on every desktop) and
#   snapped windows non-sticky, so floaters need no per-switch work.
# Bindings live in $SPB ("slot|desktop-uuid"); a binding whose slot left the
# sequence is simply ignored, which returns its desktop to the free pool. yabai
# 7.1.22 can't create desktops on macOS 26 (`space --create` is a silent no-op), so
# new ones come from Mission Control's "add desktop" button (mc_add_desktop) —
# visible, so slots/spaces.sh tops up a pool once and binding prefers free ones.
# Dry runs never take this path (the test suites exercise the legacy reveal), unless
# a test sets SLOT_SPACES.
SPACES_FLAG=/Users/josh/Code/Scripts/config/slots_spaces
SPB="$SDIR/slot_spaces"
# /usr/bin/python3 is an xcrun shim that costs an extra ~10ms per start; on the
# switch path call the interpreter it forwards to.
PY_FAST=/Library/Developer/CommandLineTools/usr/bin/python3
[[ -x "$PY_FAST" ]] || PY_FAST=/usr/bin/python3
spaces_on() {
  if [[ -n "$SLOT_DRYRUN" ]]; then [[ -n "$SLOT_SPACES" ]]; return; fi
  [[ -f "$SPACES_FLAG" ]]
}

# Add one desktop through Mission Control (see above). Returns once yabai sees it.
mc_add_desktop() {
  local before after i
  before=$(yabai -m query --spaces 2>/dev/null | jq 'length')
  open -a "Mission Control"
  osascript >/dev/null 2>&1 <<'OSA'
tell application "System Events" to tell process "Dock"
  repeat 40 times
    try
      click (first button of group 2 of group 1 of group 1 whose description is "add desktop")
      exit repeat
    end try
    delay 0.05
  end repeat
end tell
OSA
  sleep 0.3
  # Close Mission Control only if it is up — `open -a` toggles, so blindly sending it
  # when the open never happened would leave Mission Control showing.
  osascript -e 'tell application "System Events" to tell process "Dock" to exists group 1' 2>/dev/null \
    | grep -q true && open -a "Mission Control"
  for (( i=0; i<30; i++ )); do
    after=$(yabai -m query --spaces 2>/dev/null | jq 'length')
    [[ "$after" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ && $after -gt $before ]] && { log "spaces: added a desktop ($before → $after)"; return 0; }
    sleep 0.1
  done
  log "spaces: mc_add_desktop failed (still $after)"; return 1
}

# Top up the free desktops so every live slot that has none can get one, plus
# SPARE for new slots — all the Mission Control flashes happen here, once.
spaces_pool() {                 # [spare]
  local spare="${1:-2}" need i
  need=$(yabai -m query --spaces 2>/dev/null | /usr/bin/python3 -c '
import sys, json
seq = [l for l in sys.argv[1].split("\n") if l]; spare = int(sys.argv[3])
sp = json.load(sys.stdin)
desk = set(s["uuid"] for s in sp if not s.get("is-native-fullscreen") and s.get("display") == 1)
bound = {}
try:
    for l in open(sys.argv[2]):
        p = l.strip().split("|")
        if len(p) == 2 and p[0] in seq and p[1] in desk: bound[p[0]] = p[1]
except FileNotFoundError: pass
free = len(desk - set(bound.values()))
print(max(0, len(seq) - len(bound) + spare - free))
' "$(seq_read)" "$SPB" "$spare" 2>/dev/null)
  [[ "$need" =~ ^[0-9]+$ ]] || { log "spaces: pool query failed"; return 1; }
  log "spaces: pool needs $need more desktop(s)"
  for (( i=0; i<need; i++ )); do mc_add_desktop || return 1; sleep 0.3; done
}

# The live slot bound to the active desktop, or nothing.
# The active desktop's uuid is kept in ACTIVE_DESK by whoever changes it: realize_slot
# after its flip, slots/space_event.sh after macOS switches on its own. Reading a
# file costs nothing; asking costs a window-server connection (~40ms) — only done
# when the file is missing.
ACTIVE_DESK="$SDIR/.slot_active_desk"
active_desk() {
  local u; u=$(cat "$ACTIVE_DESK" 2>/dev/null)
  if [[ -z "$u" ]]; then u=$(space_query active 2>/dev/null); u="${u#* }"; [[ -n "$u" ]] && echo "$u" > "$ACTIVE_DESK"; fi
  echo "$u"
}
slot_of_active_space() {
  local uuid; uuid=$(active_desk)
  [[ -z "$uuid" ]] && return
  local s u
  while IFS='|' read -r s u; do
    [[ "$u" == "$uuid" ]] && grep -qxF "$s" "$SEQ" 2>/dev/null && { echo "$s"; return; }
  done < "$SPB" 2>/dev/null
}

# Show SLOT on its desktop. See the section comment. One window-server snapshot
# (~/bin/space_query) + one python pass (slots/realize_plan.py) bind the desktop
# and plan every move; the moves land on the (hidden) target desktop before the
# flip, so the flip shows the finished scene.
#
# Nothing here READS through yabai, and nothing asks yabai to focus a window:
# yabai serves one request at a time and both of those go through the apps'
# Accessibility, which a busy Fusion holds for 15s+ — every switch after it then
# queued behind (2026-10-10, "it stops, then catches up 10s later"). yabai is
# used only for the scripting-addition writes: move a window to a desktop, sticky,
# and the flip. macOS focuses the top window of the desktop it flips to.
realize_slot() {
  local slot="$1"
  if [[ -n "$SLOT_DRYRUN" ]]; then log "DRY realize $slot: $(members_of "$slot" | cut -d'|' -f1,2 | tr '\n' ' ')"; return; fi
  local sw sh
  if [[ -s "$DIMS_CACHE" ]]; then read -r sw sh < "$DIMS_CACHE"; else read -r sw sh < <(screen_dims); fi
  # Fast path: flip first, from caches the last plan wrote (the slot's desktop
  # index; the window it chose for each app), and plan after — the plan then only
  # catches drift. A member shared with another slot (Claude) has its cached window
  # moved over first. A floater member needs nothing (sticky, never moved, never
  # cached) — counting it sent every slot holding Control Room down the slow path.
  # Any cache miss → the planned path below.
  local flipped_to=""
  local fast fuuid fwids; read -r fast fuuid fwids < <(awk -F'|' -v s="$slot" '
    FILENAME ~ /slot_space_idx$/ { if ($1==s) { idx=$2; u=$3 }; next }
    FILENAME ~ /slot_winids$/    { wid[$1]=$2; next }
    $1==s { if ($3 !~ /,/) mine[$2]=1; next } { other[$2]=1 }
    END { if (idx == "") exit
          for (a in mine) if (a in other) { if (!(a in wid)) exit; ws = ws " " wid[a] }
          print idx, u ws }' "$MEM" "$SDIR/slot_space_idx" "$SDIR/slot_winids" 2>/dev/null)
  if [[ "$fast" =~ ^[0-9]+$ ]]; then
    local fw; for fw in $fwids; do yabai -m window "$fw" --space "$fast" 2>/dev/null; done
    yabai -m space --focus "$fast" 2>/dev/null; flipped_to="$fast"
    [[ -n "$fuuid" ]] && echo "$fuuid" > "$ACTIVE_DESK"
    # Flipped: the plan only catches drift now, so it runs off the switch path
    # (~150ms the caller — and the next swipe — no longer waits for).
    _realize_planned "$slot" "$sw" "$sh" "$fast" >/dev/null 2>&1 &
    return
  fi
  _realize_planned "$slot" "$sw" "$sh" ""
}
# The planned half of realize_slot: snapshot, plan, moves, flip (unless already
# flipped to FLIPPED_TO), then focus/drift fixes in the background.
_realize_planned() {            # slot sw sh flipped_to
  local slot="$1" sw="$2" sh="$3" flipped_to="$4"
  local plan try
  for try in 1 2; do
    plan=$(space_query json 2>/dev/null \
      | "$PY_FAST" -S /Users/josh/Code/Scripts/slots/realize_plan.py "$slot" "$SDIR" "$sw" "$sh" 2>/dev/null)
    [[ "$plan" == NOFREE* && $try == 1 ]] || break
    mc_add_desktop || break                     # no free desktop: add one, plan again
  done
  local tgt cur tuuid; read -r tgt cur tuuid <<< "${plan%%$'\n'*}"
  [[ "$tgt" =~ ^[0-9]+$ ]] || { log "spaces: no desktop for $slot (${plan:0:40}) — realize skipped"; return 1; }
  local ops=""; [[ "$plan" == *$'\n'* ]] && ops="${plan#*$'\n'}"
  local kind a b c d e post=""
  while read -r kind a b c d e; do              # before the flip: onto the hidden desktop
    case "$kind" in
      sticky) yabai -m window "$a" --toggle sticky 2>/dev/null ;;
      space)  if ! yabai -m window "$a" --space "$b" 2>/dev/null; then   # unmovable: follow the window
                local rb; rb=$(space_query json 2>/dev/null | "$PY_FAST" -S /Users/josh/Code/Scripts/slots/realize_plan.py --rebind "$slot" "$SDIR" "$a" 2>/dev/null)
                [[ -n "$rb" ]] && { read -r tgt tuuid <<< "$rb"; log "rebind $slot → desktop $tgt (window $a unmovable)"; }
              fi ;;
      evict)  yabai -m window "$a" --space "$b" 2>/dev/null ;;
      ?*)     post+="$kind $a $b $c $d $e"$'\n' ;;
    esac
  done <<< "$ops"
  if [[ "$flipped_to" != "$tgt" ]] && [[ -n "$flipped_to" || "$tgt" != "$cur" ]]; then
    yabai -m space --focus "$tgt" 2>/dev/null
  fi
  echo "$tuuid" > "$ACTIVE_DESK"
  log "realize $slot on desktop $tgt (from $cur): ${ops//$'\n'/;}"
  # After the flip, off the switch path: focus a pair's other member, re-set a
  # drifted tile (non-CAD only — the planner never emits a frame op for one).
  [[ -n "$post" ]] && {
    while read -r kind a b c d e; do
      case "$kind" in
        activate) activate_app "$a" ;;
        frame)    yabai -m window "$a" --move abs:"$b":"$c"; yabai -m window "$a" --resize abs:"$d":"$e" ;;
      esac
    done <<< "$post"
    touch /tmp/.slot_op_ts
  } >/dev/null 2>&1 &
}

# ── effects: membership & geometry queries ───────────────────────────────────
# Owner of the topmost on-screen window exactly filling a slot position's
# rectangle (excluding the given app). Empty if nothing tiles it perfectly.
window_at_pos() {                 # pos excludeApp → owner name | ""
  [[ -n "$SLOT_DRYRUN" ]] && return
  local x y w h; read -r x y w h < <(pos_rect "$1")
  [[ -z "$x" ]] && return
  win_at "$x" "$y" "$w" "$h" "$(open_name "$2")" 2>/dev/null
}

# focus app of a slot = the top-of-z member (last line of members_of)
focus_of() {                    # one awk, not members_of|tail|cut — it's on the switch path
  awk -F'|' -v s="$1" '$1==s && (!n++ || $4+0 > z) {z=$4+0; a=$2} END{if (n) print a}' "$MEM" 2>/dev/null
}
# Is app A a member of slot S?
is_member() { awk -F'|' -v s="$1" -v a="$2" '$1==s&&$2==a{f=1} END{exit !f}' "$MEM" 2>/dev/null; }
# Is app A a member of ANY slot?
is_member_anywhere() { awk -F'|' -v a="$1" '$2==a{f=1} END{exit !f}' "$MEM" 2>/dev/null; }
# Is app A recorded as a FLOATER (literal "x,y,w,h" pos) in any slot?
is_floater_member_anywhere() { awk -F'|' -v a="$1" '$2==a && $3 ~ /,/{f=1} END{exit !f}' "$MEM" 2>/dev/null; }
is_snapped_anywhere() { awk -F'|' -v a="$1" '$2==a && $3 !~ /,/{f=1} END{exit !f}' "$MEM" 2>/dev/null; }
# A slot other than CUR where A is `full` — A's own space (snapping a floater to
# full gives it one; see op_snap). Empty if none.
full_slot_elsewhere() {         # app cur → slot
  awk -F'|' -v a="$1" -v c="$2" '$2==a && $3=="full" && $1!=c {print $1; exit}' "$MEM" 2>/dev/null
}

# Every app that is a FLOATER (literal "x,y,w,h") in any slot, one "app|geom" line
# each (deduped by app). A floating window is "sticky": shown on every space, so
# do_restore injects these into every slot. Geometry is the synced current spot —
# lastpos (kept in sync across spaces) when present, else the recorded floater pos.
global_floaters() {
  local a g
  awk -F'|' '$3 ~ /,/{print $2}' "$MEM" 2>/dev/null | sort -u | while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    g=$(lastpos "$a")
    [[ "$g" == *,* ]] || g=$(awk -F'|' -v a="$a" '$2==a && $3 ~ /,/{print $3; exit}' "$MEM" 2>/dev/null)
    [[ -n "$g" ]] && echo "$a|$g"
  done
}
# Geometry of app A as a sticky floater (lastpos if it's a literal rect, else its
# first recorded floating pos). Empty if A isn't a floater anywhere.
floater_geom() {
  local g; g=$(lastpos "$1")
  [[ "$g" == *,* ]] && { echo "$g"; return; }
  awk -F'|' -v a="$1" '$2==a && $3 ~ /,/{print $3; exit}' "$MEM" 2>/dev/null
}
# Is app A a SNAPPED member of slot S — i.e. recorded at one of the 7 tiles
# (full / left / right / corner), not as a floating window at literal "x,y,w,h"
# geometry? The app hotkey (navapp) only jumps to a space where the app is snapped;
# a loose floater is raised in the current space instead of being chased.
is_snapped_member() {           # slot app → 0 if A occupies a tile in slot
  awk -F'|' -v s="$1" -v a="$2" '
    $1==s && $2==a &&
    ($3=="full"||$3=="left"||$3=="right"||
     $3=="top-left"||$3=="top-right"||$3=="bottom-left"||$3=="bottom-right") {f=1}
    END{exit !f}' "$MEM" 2>/dev/null
}

# How many SNAPPED members slot S has, ignoring any app in the trailing args
# (the apps that just died). Floaters (literal "x,y,w,h") never count. Used by
# app_terminated to decide if a quit emptied a space of every tiled app.
snapped_survivors() {           # slot deadApp...
  local s="$1"; shift
  local dead="|"; local a; for a in "$@"; do dead="$dead$a|"; done
  awk -F'|' -v s="$s" -v dead="$dead" '
    $1==s &&
    ($3=="full"||$3=="left"||$3=="right"||
     $3=="top-left"||$3=="top-right"||$3=="bottom-left"||$3=="bottom-right") {
      if (index(dead, "|" $2 "|") == 0) c++
    }
    END{print c+0}' "$MEM" 2>/dev/null
}

# True if positions a and b share any screen area. Handles tile names and literal
# "x,y,w,h" geometry: if either side is a literal rect, fall back to a real
# rectangle-intersection test (the tile lookup table only knows the 7 tile names).
pos_overlaps() {
  local a="$1" b="$2"
  if [[ "$a" == *,* || "$b" == *,* ]]; then
    local ax ay aw ah bx by bw bh
    read -r ax ay aw ah < <(pos_rect "$a")
    read -r bx by bw bh < <(pos_rect "$b")
    [[ -z "$ax" || -z "$bx" ]] && return 1
    (( ax < bx+bw && bx < ax+aw && ay < by+bh && by < ay+ah )) && return 0
    return 1
  fi
  [[ "$a" == "$b" ]] && return 0
  [[ "$a" == "full" || "$b" == "full" ]] && return 0
  [[ "$a" == "left"  && ( "$b" == "top-left"  || "$b" == "bottom-left"  ) ]] && return 0
  [[ "$a" == "right" && ( "$b" == "top-right" || "$b" == "bottom-right" ) ]] && return 0
  [[ "$b" == "left"  && ( "$a" == "top-left"  || "$a" == "bottom-left"  ) ]] && return 0
  [[ "$b" == "right" && ( "$a" == "top-right" || "$a" == "bottom-right" ) ]] && return 0
  return 1
}

# Remove existing slot members whose position overlaps newpos. Called before
# adding a new app so that app is unambiguously the sole occupant of that area.
remove_overlapping_members() {  # slot newpos
  local slot="$1" newpos="$2" app pos z
  while IFS='|' read -r app pos z; do
    [[ -z "$app" ]] && continue
    pos_overlaps "$newpos" "$pos" && {
      remove_member "$slot" "$app"
      log "evict_overlap: $app at $pos overlaps incoming $newpos → removed from slot $slot"
    }
  done < <(members_of "$slot")
}

# Geometries of CAD apps' AUXILIARY windows — palettes, dialogs, helper windows:
# every window whose subrole is NOT AXStandardWindow. One "x|y|w|h" per line.
#
# These are the poison. A CAD app like Fusion keeps its palettes as sticky panels
# that float across EVERY space (canJoinAllSpaces). win_list (CGWindowList, on-screen
# only) therefore reports them on whatever space you happen to be leaving, with the
# same owner ("Fusion") as the real canvas but no way to tell them apart by name. The
# leaving-space failsafe then records "Fusion is here" from a palette-only sighting,
# at the palette's 25px-tall geometry — onto a space where Fusion's canvas does not
# live. The one-app-one-position / floater-sync machinery then smears that bogus
# geometry across every space, and Fusion's real space ends up with nothing.
#
# yabai's `subrole` is the discriminator: the document window is AXStandardWindow;
# palettes are AXDialog (or another non-standard subrole). We collect the aux
# geometries here and strip them from win_list_raw below, so a palette is never
# adopted as a member anywhere. SLOT_CAD_AUX overrides for tests (no yabai).
#
# ONE wrinkle: a window yabai has not AX-observed (has-ax-reference=false — the
# Fusion/SketchUp Qt observation race, see fusion_observe_heal.sh) reports
# subrole='' even when it IS the main canvas. An empty subrole therefore only
# counts as aux for SMALL windows (Fusion's 8x16 helper); a large unobserved
# window is treated as the canvas — never filtered, or the failsafe would evict
# the CAD app from its own space the moment it reconciles (seen live with an
# unobserved SketchUp main window). 600px = fusion_observe_heal's canvas test.
#
# TWO sources, because yabai alone is no longer enough. yabai's window list only
# contains windows it has AX-observed; Fusion's sticky palettes (Sketch Palette,
# Browser, Comments …) are NSPanels that yabai frequently NEVER observes, so they
# are simply ABSENT from `yabai -m query --windows` — there is no subrole to read
# and nothing to strip. That gap was harmless while the canvas was the only
# AXStandardWindow (subrole alone told canvas from palette), but the Maximize
# Viewport add-in made the canvas borderless → it reports AXDialog just like a
# palette, so subrole no longer discriminates and the unobserved-palette gap
# reopened the Fusion-vanishes bug. Fix: ALSO derive aux geometries straight from
# CGWindowList (the very list the failsafe consumes via win_list), where the
# canvas is the single big Fusion window (>600w,>400h) and every smaller Fusion
# window is a palette/helper → aux. Union the two sources. 600px stays the canvas
# test in both. SLOT_WINLIST overrides the CGWindowList source (and suppresses the
# ── effects: CAD aux filtering / win_list_raw ────────────────────────────────
# real yabai query) for hermetic tests.
_CAD_AUX_CACHE=""; _CAD_AUX_DONE=""
cad_aux_geoms() {
  if [[ -n "$_CAD_AUX_DONE" ]]; then printf '%s' "$_CAD_AUX_CACHE"; return; fi
  _CAD_AUX_DONE=1
  if [[ -n "${SLOT_CAD_AUX+x}" ]]; then _CAD_AUX_CACHE="$SLOT_CAD_AUX"; printf '%s' "$_CAD_AUX_CACHE"; return; fi
  [[ -n "$SLOT_DRYRUN" && -z "${SLOT_WINLIST+x}" ]] && { printf ''; return; }

  # Source 1 — yabai's AX-observed windows (only consulted with a live yabai, i.e.
  # not when SLOT_WINLIST mocks the window list). Catches observed palettes/dialogs.
  local yb_aux=""
  if [[ -z "${SLOT_WINLIST+x}" ]]; then
    yb_aux="$(yabai -m query --windows 2>/dev/null | SLOTS_CAD_NAMES="$CAD_MATCH_NAMES" /usr/bin/python3 -c '
import os, sys, json
cad = set(n for n in (os.environ.get("SLOTS_CAD_NAMES") or "").split("\n") if n)
try: ws = json.load(sys.stdin)
except Exception: sys.exit(0)
for w in ws:
    if w.get("app") not in cad: continue
    if w.get("subrole") == "AXStandardWindow": continue    # the real document window (title bar on)
    f = w.get("frame") or {}
    if not f: continue
    # The canvas is the BIG window — never aux — WHATEVER its subrole. It is
    # AXStandardWindow with the title bar on, but AXDialog when the Maximize
    # Viewport add-in makes the window borderless (no title bar → macOS reports
    # AXDialog), and '' while yabai has not yet AX-observed it (the Qt race).
    # Size is the reliable discriminator: palettes are small, the canvas fills a
    # tile (>600 wide, >400 tall). Without this, a borderless canvas is mistaken
    # for a palette and stripped, erasing Fusion from its own space.
    if f.get("w", 0) > 600 and f.get("h", 0) > 400:
        continue
    print("%d|%d|%d|%d" % (round(f["x"]), round(f["y"]), round(f["w"]), round(f["h"])))
' 2>/dev/null)"
  fi

  # Source 2 — CGWindowList (win_list), which DOES contain the unobserved sticky
  # palettes. Same canvas test: keep the one big Fusion window, flag every smaller
  # Fusion window as aux. This is what actually closes the gap; Source 1 is kept so
  # an observed large-ish auxiliary dialog still gets caught by its subrole.
  local cg_src cg_aux
  if [[ -n "${SLOT_WINLIST+x}" ]]; then cg_src="$SLOT_WINLIST"; else cg_src="$(win_list 2>/dev/null)"; fi
  cg_aux="$(printf '%s\n' "$cg_src" | SLOTS_CAD_NAMES="$CAD_MATCH_NAMES" /usr/bin/python3 -c '
import os, sys
cad = set(n for n in (os.environ.get("SLOTS_CAD_NAMES") or "").split("\n") if n)
for line in sys.stdin:
    p = line.rstrip("\n").split("|")
    if len(p) != 5: continue
    owner, x, y, w, h = p
    if owner not in cad: continue
    try: x, y, w, h = int(x), int(y), int(w), int(h)
    except ValueError: continue
    if w > 600 and h > 400: continue   # the canvas — never aux
    print("%d|%d|%d|%d" % (x, y, w, h))
' 2>/dev/null)"

  # Union the two sources, drop blanks and duplicates, preserve order.
  _CAD_AUX_CACHE="$(printf '%s\n%s\n' "$yb_aux" "$cg_aux" | awk 'NF && !seen[$0]++')"
  printf '%s' "$_CAD_AUX_CACHE"
}

# Drop CAD auxiliary (palette/dialog/helper) windows from a "owner|x|y|w|h" stream,
# matching a CAD-app line against the aux geometries within a small tolerance. Only
# CAD-owned lines are ever dropped, so a same-sized non-CAD window is never touched.
#
# The multi-line values (aux geoms, CAD names) are passed via the ENVIRONMENT, not
# `awk -v`: BSD awk hard-errors on a newline inside a -v value ("newline in string"),
# which used to make this whole filter exit empty whenever a CAD app had two or more
# aux windows up — win_list_raw then fed the failsafe NOTHING and every reconcile
# silently no-opped ("failsafe: no visible tiles") until the palettes went away.
filter_cad_aux() {
  local aux; aux="$(cad_aux_geoms)"
  [[ -z "$aux" ]] && { cat; return; }
  SLOTS_AUX="$aux" SLOTS_CAD_NAMES="$CAD_MATCH_NAMES" awk -F'|' '
    function abs(v){ return v<0?-v:v }
    BEGIN{
      nc=split(ENVIRON["SLOTS_CAD_NAMES"],CN,"\n"); for(c=1;c<=nc;c++) if(CN[c]!="") CAD[CN[c]]=1
      m=split(ENVIRON["SLOTS_AUX"],L,"\n")
      for(i=1;i<=m;i++){ if(L[i]=="")continue; split(L[i],g,"|"); na++; AX[na]=g[1];AY[na]=g[2];AW[na]=g[3];AH[na]=g[4] }
    }
    { if($1 in CAD) for(i=1;i<=na;i++)
        if(abs($2-AX[i])<=2 && abs($3-AY[i])<=2 && abs($4-AW[i])<=2 && abs($5-AH[i])<=2) next
      print }'
}

# On-screen windows front-to-back as "owner|x|y|w|h", with CAD palettes stripped.
# SLOT_WINLIST overrides the source for tests (set, even empty, to bypass the real
# tool); filter_cad_aux still applies so tests can exercise palette stripping.
win_list_raw() {
  { if [[ -n "${SLOT_WINLIST+x}" ]]; then printf '%s\n' "$SLOT_WINLIST"
    else win_list 2>/dev/null; fi
  } | filter_cad_aux
}

# True if rectangle "tx ty tw th" is *entirely* hidden by the union of the cover
# rectangles fed on stdin (one "x y w h" per line). Exact: it compresses the
# target + clipped cover edges into a grid and checks every cell centre lies
# ── effects: tile/geometry helpers ───────────────────────────────────────────
# inside some cover. Empty cover input → not covered. One awk pass, no loops in
# bash. (left+right tiles together fully cover a `full` window beneath, etc.)
# Cover rects are padded by `tol` before clipping: pos_rect insets left-tiles 1px
# for the JankyBorders seam, so two real snapped tiles never pixel-perfectly tile
# the screen — without this slack a genuine full window behind them is never
# judged covered and lingers as a phantom member forever (the 1px seam bug).
rect_fully_covered() {           # "tx ty tw th"  +  stdin: cover rects
  local tol=8
  awk -v t="$1" -v tol="$tol" '
    function asortish(arr, n,   i, j, tmp) {
      for (i = 0; i < n; i++) for (j = i+1; j < n; j++)
        if (arr[j] < arr[i]) { tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp }
    }
    BEGIN {
      split(t, a, " "); tx = a[1]; ty = a[2]; tr = a[1]+a[3]; tb = a[2]+a[4]
      nx = 0; xs[nx++] = tx; xs[nx++] = tr
      ny = 0; ys[ny++] = ty; ys[ny++] = tb
      nc = 0
    }
    {
      cx1 = $1-tol; cy1 = $2-tol; cx2 = $1+$3+tol; cy2 = $2+$4+tol   # pad, then clip cover to target
      if (cx1 < tx) cx1 = tx; if (cx2 > tr) cx2 = tr
      if (cy1 < ty) cy1 = ty; if (cy2 > tb) cy2 = tb
      if (cx1 >= cx2 || cy1 >= cy2) next                   # no overlap with target
      CX1[nc] = cx1; CY1[nc] = cy1; CX2[nc] = cx2; CY2[nc] = cy2; nc++
      xs[nx++] = cx1; xs[nx++] = cx2; ys[ny++] = cy1; ys[ny++] = cy2
    }
    END {
      if (nc == 0) { print "NO"; exit }
      asortish(xs, nx); asortish(ys, ny)
      for (i = 0; i < nx-1; i++) {
        if (xs[i] == xs[i+1]) continue
        mx = (xs[i] + xs[i+1]) / 2
        for (j = 0; j < ny-1; j++) {
          if (ys[j] == ys[j+1]) continue
          my = (ys[j] + ys[j+1]) / 2
          cov = 0
          for (k = 0; k < nc; k++)
            if (mx >= CX1[k] && mx <= CX2[k] && my >= CY1[k] && my <= CY2[k]) { cov = 1; break }
          if (!cov) { print "NO"; exit }
        }
      }
      print "YES"
    }'
}

# Swipe-away failsafe: rebuild the slot's membership from what is *visibly* on
# screen. Walking front-to-back, every window joins the slot unless it is fully
# covered by the union of the windows above it (true union coverage — a fullscreen
# window on top makes the space just that window; left+right together hide a full
# window beneath). A window that matches one of the 7 tiles within tolerance is
# recorded by tile name; anything else (floaters, odd sizes) is recorded at its
# exact "x,y,w,h" geometry so it returns to the same spot on swipe-back. System UI
# surfaces are skipped (neither member nor coverer). This is the one place that
# reconciles the recorded space with reality.
# app → 0 if it's one of the canonical sequence apps (APPS). Canon apps are only
# ever used snapped, so they are NEVER reclassified as floaters.
is_canon_app() {                # app (state key) → 0 if in APPS
  [[ "$(canon_index "$1")" -ge 0 ]]
}

# The tile a canon app belongs on. A canon app is NEVER a floater (user, 2026-10-20:
# it only ever came loose by mistake — a slip of the hand or the software), so
# wherever it would be recorded loose it is recorded here instead, and snapped back.
# First choice that doesn't overlap SLOT's other snapped members: where it is snapped
# in SLOT, its lastpos, any tile it holds elsewhere, then the biggest free tile; if
# none is free, the first of those (the coverage rule then applies). Never empty.
canon_tile() {                  # app [slot] → tile name
  local a="$1" s="$2" c first="" others="" o ok
  [[ -n "$s" ]] && others=$(awk -F'|' -v s="$s" -v a="$a" '$1==s && $2!=a && $3!~/,/{print $3}' "$MEM" 2>/dev/null)
  while IFS= read -r c; do
    is_tile_name "$c" || continue
    [[ -z "$first" ]] && first="$c"
    ok=1
    while IFS= read -r o; do [[ -n "$o" ]] && pos_overlaps "$c" "$o" && { ok=; break; }; done <<< "$others"
    [[ -n "$ok" ]] && { echo "$c"; return; }
  done < <(
    [[ -n "$s" ]] && awk -F'|' -v s="$s" -v a="$a" '$1==s && $2==a{print $3}' "$MEM" 2>/dev/null
    lastpos "$a"
    awk -F'|' -v a="$a" '$2==a{print $3}' "$MEM" 2>/dev/null
    printf '%s\n' full left right top-left top-right bottom-left bottom-right)
  echo "${first:-full}"
}

# Rewrite every canon app recorded loose (a literal "x,y,w,h" member or lastpos —
# state from before canon apps were barred from floating, or a stray write) onto its
# tile, so it is never injected as a sticky floater, never raised as one, and its
# hotkey jumps to its space again. Each slot's copy gets that slot's canon_tile.
unfloat_canon() {
  local s a p t
  while IFS='|' read -r s a p; do
    [[ -z "$a" ]] || ! is_canon_app "$a" && continue
    t=$(canon_tile "$a" "$s")
    mem_keep -v s="$s" -v a="$a" -v t="$t" -v OFS='|' '$1==s && $2==a && $3 ~ /,/ { $3=t } 1'
    log "unfloat_canon: $a in $s was loose at $p → $t"
  done < <(awk -F'|' '$3 ~ /,/{print $1"|"$2"|"$3}' "$MEM" 2>/dev/null)
  while IFS='|' read -r a p; do
    [[ -n "$a" ]] && is_canon_app "$a" && set_lastpos "$a" "$(canon_tile "$a")"
  done < <(awk -F'|' '$2 ~ /,/' "$LP" 2>/dev/null)
}

# Put a canon app that was dragged/resized loose back on TILE. Backgrounded by the
# reconcile. Waits for the mouse button to come up first (a pause mid-drag fires the
# reconcile; yanking the window out from under the hand would fight it), then
# re-reads: if the app is on a tile by then (dropped onto one by hand), leave it —
# the reconcile that drop fires records it there.
canon_snap_back() {             # app tile
  local a="$1" t="$2" i
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY snapback $a → $t"; return; }
  unset SLOT_WINLIST; _CAD_AUX_DONE=""         # forked from the reconcile: read the screen afresh
  for (( i=0; i<200; i++ )); do
    [[ "$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSEvent.pressedMouseButtons' 2>/dev/null)" == 0 ]] && break
    sleep 0.1
  done
  # A UI Zoom glide resizes every window: let it land first, so the re-read and the
  # move both use the new zoom's tiles (zoom_wait comes with the UI Zoom fix).
  if declare -F zoom_wait >/dev/null; then zoom_wait || return; fi
  is_tile_name "$(app_dock_pos "$a")" && return
  touch /tmp/.slot_op_ts 2>/dev/null           # our own move: window_event ignores it
  log "snapback: canon $a was loose → $t"
  do_move "$a" "$t"
}

# Intersect a window rect with the screen: "x y w h" → "x y w h", zero-sized if it
# lies entirely off-screen. What is off the edge is not on screen, so it can neither
# be a reason to call a window untiled nor a reason to call the window under it
# hidden — the two questions the failsafe asks of every rect.
#
# This exists because of Fusion. Its window intermittently comes back at
# -1712,0,3440,1440 — the frame of a 3440x1440 display, centred on and overflowing a
# 1728x1117 one. Raw, that rect matches no tile, so Fusion was recorded as a loose
# floater; a floater is not a jump target, so the Fusion hotkey stopped teleporting to
# Fusion's slot and merely raised it where you stood ("navapp Fusion: floater → raise
# only in current slot" in slots.log). Worse, nothing on screen can fully cover a rect
# that is bigger than the screen, so Fusion was never dropped by the coverage walk and
# accumulated as a member of every other slot, to be re-raised on every scene restore.
# Clamped, the same window reads as `full`, which is what it visibly is.
clamp_to_screen() {             # x y w h → "x y w h" (intersection with the screen)
  local x="$1" y="$2" w="$3" h="$4"
  local sw sh; read -r sw sh < <(screen_dims)
  [[ -z "$sw" ]] && { echo "$x $y $w $h"; return; }
  local x2=$((x+w)) y2=$((y+h))
  (( x  < 0  )) && x=0
  (( y  < 0  )) && y=0
  (( x2 > sw )) && x2=$sw
  (( y2 > sh )) && y2=$sh
  local cw=$((x2-x)) ch=$((y2-y))
  (( cw < 0 )) && cw=0
  (( ch < 0 )) && ch=0
  echo "$x $y $cw $ch"
}

# Geometry → tile name (one of the 7) if it matches a tile within tolerance, else
# empty. The single source of truth for "is this window snapped to a tile?" — used
# by the failsafe reconcile and the live floater classifier alike, so they can
# never disagree.
#
# UI Zoom (ui_zoom.sh § Screen zoom) changes the screen tiles are cut from, and its
# glide re-fits only the windows ON SCREEN: every other desktop's windows keep the
# tiles of the zoom they were last shown at until their slot is revealed (realize
# re-sets drifted tiles). Read against today's tiles they were "loose" — Remap
# recorded as a floater at 0,0,1563,654 (full at 220%) while the screen was 100%
# (2026-10-20). So a rect that is no tile now but IS one at another zoom level reads
# as that tile (zoom_tile_for_geom). RAW (args 5–8, the unclamped rect) is what a
# window sized for a LOWER zoom is matched by: clamped, it is cut to the screen.
tile_for_geom() {               # x y w h [raw x y w h] → tile name | ""
  local t; t=$(tile_for_geom_now "$1" "$2" "$3" "$4")
  [[ -z "$t" && -s "$SDIR/.screen_zoom" ]] && t=$(zoom_tile_for_geom "${5:-$1}" "${6:-$2}" "${7:-$3}" "${8:-$4}")
  [[ -n "$t" ]] && echo "$t"
}
# The same at every UI Zoom level, 100–300% in its 5% steps (distance zoom snaps to
# them too). Bigger tiles first: a top-left quarter at z IS the full tile at 2z, and
# a stale full screen is far likelier than a stale quarter. One awk, only for a rect
# that matched no tile now. The unzoomed screen is today's × the zoom (±1 px).
# slots/zoomtiles.py is the Python twin (realize_plan, slotd, pin_loose_above).
zoom_tile_for_geom() {          # x y w h → tile name at some zoom level | ""
  local sw sh z; read -r sw sh < <(screen_dims); z=$(cat "$SDIR/.screen_zoom" 2>/dev/null)
  [[ -z "$sw" || -z "$z" ]] && return
  awk -v x="$1" -v y="$2" -v w="$3" -v h="$4" -v sw="$sw" -v sh="$sh" -v z="$z" '
    function d(a, b) { return a > b ? a - b : b - a }
    BEGIN {
      nw = int(sw * z + 0.5); nh = int(sh * z + 0.5)
      split("full left right top-left top-right bottom-left bottom-right", T, " ")
      for (k = 1; k <= 7; k++) for (p = 100; p <= 300; p += 5) {
        W = int(nw * 100 / p); H = int(nh * 100 / p); hw = int(W / 2); hh = int(H / 2); lw = hw - 1
        if (k == 1) { rx = 0;  ry = 0;  rw = W;  rh = H }
        if (k == 2) { rx = 0;  ry = 0;  rw = lw; rh = H }
        if (k == 3) { rx = hw; ry = 0;  rw = hw; rh = H }
        if (k == 4) { rx = 0;  ry = 0;  rw = lw; rh = hh }
        if (k == 5) { rx = hw; ry = 0;  rw = hw; rh = hh }
        if (k == 6) { rx = 0;  ry = hh; rw = lw; rh = hh }
        if (k == 7) { rx = hw; ry = hh; rw = hw; rh = hh }
        if (d(x, rx) <= 8 && d(y, ry) <= 8 && d(w, rw) <= 8 && d(h, rh) <= 8) { print T[k]; exit }
      }
    }'
}
# Is UI Zoom's screen glide moving windows right now? ui_zoom.sh holds its press lock
# from the press until the glide lands (distance_zoom reads it the same way), and
# rewrites $SDIR/.screen_zoom as it lands; a second after that the apps have drawn
# their last size. Mid-glide every tiled window on screen is between two tile sizes
# (a floater to any reader) and screen_dims still names the old zoom — a reconcile
# then is what recorded windows loose. Never in dry runs (no ui_zoom there).
zoom_busy() {
  [[ -n "$SLOT_DRYRUN" || ! -f "$SDIR/.screen_zoom" ]] && return 1
  /usr/bin/lockf -k -s -t 0 /tmp/.ui_zoom.lock /usr/bin/true || return 0
  local now ts; now=$(date +%s); ts=$(stat -f %m "$SDIR/.screen_zoom" 2>/dev/null || echo 0)
  (( now - ts <= 1 ))
}
zoom_wait() {                   # [tenths] → 0 once no glide is moving windows (default ≤3 s)
  local i
  for (( i=0; i<${1:-30}; i++ )); do zoom_busy || return 0; sleep 0.1; done
  ! zoom_busy
}
tile_for_geom_now() {           # x y w h → tile name at today's screen | ""
  local x="$1" y="$2" w="$3" h="$4" tol=8
  local sw sh; read -r sw sh < <(screen_dims)
  [[ -z "$sw" ]] && return
  local hw=$((sw/2)) hh=$((sh/2)) lw=$((sw/2-1))   # left-edge tiles inset 1px right (see pos_rect)
  local rects="full 0 0 $sw $sh
left 0 0 $lw $sh
right $hw 0 $hw $sh
top-left 0 0 $lw $hh
top-right $hw 0 $hw $hh
bottom-left 0 $hh $lw $hh
bottom-right $hw $hh $hw $hh"
  local rn rx ry rw rh
  while read -r rn rx ry rw rh; do
    if (( x-rx>=-tol && x-rx<=tol && y-ry>=-tol && y-ry<=tol && \
          w-rw>=-tol && w-rw<=tol && h-rh>=-tol && h-rh<=tol )); then
      echo "$rn"; return
    fi
  done <<< "$rects"
}

# Current on-screen geometry of app A as a literal "x,y,w,h", or empty if it has
# no window on screen. Used to register a freshly-summoned loose window as a
# floater at exactly where it already sits (so it is never resized).
live_geom() {                   # app (state key) → "x,y,w,h" | ""
  [[ -n "$SLOT_DRYRUN" ]] && return
  local a="$1" owner x y w h
  while IFS='|' read -r owner x y w h; do
    [[ "$(normalize "$owner")" == "$a" ]] && { echo "$x,$y,$w,$h"; return; }
  done < <(win_list_raw)
}

# Best position for app A from its CURRENT on-screen windows: its tile-matching
# (docked) window if it has one, else the frontmost window's literal "x,y,w,h"
# geometry. Empty in dry-run. Lets placeapp open an app at the size it actually
# launched ("come in however it comes in") instead of forcing it to a full tile.
app_dock_pos() {                # app (state key) → tile | "x,y,w,h" | ""
  [[ -n "$SLOT_DRYRUN" ]] && return
  local a="$1" owner x y w h p loose=""
  while IFS='|' read -r owner x y w h; do
    [[ "$(normalize "$owner")" == "$a" ]] || continue
    p=$(tile_for_geom "$x" "$y" "$w" "$h")
    [[ -n "$p" ]] && { echo "$p"; return; }
    [[ -z "$loose" ]] && loose="$x,$y,$w,$h"
  done < <(win_list_raw)
  [[ -n "$loose" ]] && echo "$loose"
}

# True if POS is one of the 7 tile names (a real snapped home), as opposed to a
# literal "x,y,w,h" floater geometry or empty.
is_tile_name() {                # pos → 0 if a tile name
  case "$1" in
    full|left|right|top-left|top-right|bottom-left|bottom-right) return 0 ;;
    *) return 1 ;;
  esac
}

# Rebuild the leaving slot's membership from what is *visibly* on screen.
#
# ⚠️  THE FUSION-VANISHES TRAP — read before touching this function. The recurring
#   "I put Fusion on a space, swipe away, come back, the space is empty" bug lives
#   here. Its cause is NOT in this loop — it is in the INPUT. win_list_raw feeds us
#   on-screen windows, and Fusion's palettes are sticky AXDialog panels that float
#   on EVERY space (canJoinAllSpaces). They report under owner "Fusion", same as the
#   real canvas — so a palette-only sighting on a foreign space looks exactly like
#   "Fusion is snapped here" and gets recorded at the palette's 25px geometry, while
#   the real canvas (AXStandardWindow) — living on another space — is recorded
#   nowhere. The fix is the subrole-based filter in win_list_raw (cad_aux_geoms /
#   filter_cad_aux): palettes never reach this loop. See TEST 15h/15i.
#
#   Do NOT try to re-solve this here with a geometry/size heuristic ("skip thin
#   windows", "skip non-tile CAD windows"): the canvas can legitimately be any size,
#   and that path is exactly how this kept getting "fixed" without being fixed.
#   subrole (queried from yabai in win_list_raw) is the ONLY reliable discriminator.
#
# Mechanics: walking front-to-back, every window of an app ALREADY recorded in this
# slot stays unless it is fully covered by the union of the member windows above it.
# A window of any other app is invisible to this reconcile — it neither joins nor
# covers: only the explicit ops (snap, activate/focus.sh, navapp, placeapp) commit an
# app to a space, so something merely clicked onto the screen never sticks. The one
# exception is an app that is already a FLOATER somewhere, sitting loose — floaters
# are sticky, so it is recorded here too. A window matching one of the 7 tiles
# within tolerance is recorded by tile name; anything else at its exact "x,y,w,h" so
# it returns to the same spot on swipe-back. System UI surfaces and the just-summoned
# ── effects: adoption & restore helpers ──────────────────────────────────────
# nav target (exclude) are skipped. This is the one place that reconciles the recorded
# space with on-screen reality.
failsafe_adopt_snapped() {
  local cur="$1" exclude="$2"
  [[ -n "$SLOT_DRYRUN" && -z "${SLOT_WINLIST+x}" ]] && return
  unfloat_canon
  if display_unsettled; then log "failsafe: display changed <${DISPLAY_SETTLE}s ago, slot $cur unchanged"; return; fi
  if zoom_busy; then log "failsafe: UI Zoom glide in progress, slot $cur unchanged"; return; fi
  # Native spaces: reconcile from the slot's OWN desktop, whatever is on screen. The
  # on-screen list belongs to whichever desktop is showing — 3ds Max's, or another
  # slot's when "current" lags a native switch — and reading it emptied slots
  # (2026-10-10: Fusion and Chrome lost their slots, then got duplicates).
  if spaces_on && [[ -z "${SLOT_WINLIST+x}" ]]; then
    local du; du=$(awk -F'|' -v s="$cur" '$1==s{print $2; exit}' "$SPB" 2>/dev/null)
    [[ -z "$du" ]] && { log "failsafe: $cur has no desktop yet, unchanged"; return; }
    local SLOT_WINLIST                          # dynamic scope: win_list_raw/cad_aux read it
    SLOT_WINLIST=$(space_query winlist "$du" 2>/dev/null) || { log "failsafe: $cur's desktop unreadable, unchanged"; return; }
    _CAD_AUX_DONE=""
  fi
  local sw sh; read -r sw sh < <(screen_dims)
  [[ -z "$sw" ]] && return
  local owner x y w h pos norm visible="" higher="" saw="" present=""
  # The apps this slot already holds — the only ones the reconcile may keep.
  local members; members=" $(awk -F'|' -v s="$cur" '$1==s{printf "%s ", $2}' "$MEM" 2>/dev/null)"
  local wl; wl=$(win_list_raw)

  while IFS='|' read -r owner x y w h; do
    [[ -z "$owner" ]] && continue
    norm=$(normalize "$owner")
    is_system_surface "$norm" && continue        # transient overlay → ignore entirely
    grep -qxF "$norm" <<< "${COHERENCE_APPS:-}" && continue   # 3ds Max: never a slot member
    # The navigation target (just summoned by goto_app's ensure_app_window, possibly
    # ON TOP of the space we're leaving) is neither a member of this space nor a
    # coverer of it — it belongs to where we're navigating TO. Skip it entirely, or
    # its fresh window would evict the real occupant beneath it (the "open Podcasts,
    # lose Notes, get two spaces" bug).
    [[ -n "$exclude" && "$norm" == "$exclude" ]] && continue
    saw=1; present="$present $norm "
    # Drop only if fully hidden by the union of the (real) windows above it.
    # The ON-SCREEN part of the window answers both questions below: whether anything
    # above hides it, and which tile (if any) it sits on.
    local cx cy cw ch
    read -r cx cy cw ch < <(clamp_to_screen "$x" "$y" "$w" "$h")
    (( cw <= 0 || ch <= 0 )) && continue          # entirely off-screen → not in this scene
    if [[ -n "$higher" ]] && [[ "$(printf '%s' "$higher" | rect_fully_covered "$cx $cy $cw $ch")" == YES ]]; then
      continue
    fi
    # Classify: matches a tile within tol → tile name; else record the window at its
    # exact "x,y,w,h" geometry so it returns to the same spot on swipe-back. Canon
    # and non-canon alike — a canon app is brought back however it actually sits, NOT
    # coerced to a full tile. (That old coercion turned every auxiliary window of a
    # multi-window app like Fusion — palettes, helper windows — into a phantom
    # full-screen member, which is what let Fusion take over every space.)
    # Classified on the clamped rect; RECORDED at the raw one, so a window
    # deliberately hanging off an edge comes back exactly where it was rather than
    # being pulled onto the screen.
    pos=$(tile_for_geom "$cx" "$cy" "$cw" "$ch" "$x" "$y" "$w" "$h")
    [[ -z "$pos" ]] && pos="$x,$y,$w,$h"
    # A CAD app's window that sits on no tile and covers under 45% of the screen is a
    # dialog / helper window (Fusion's 860x536 ones pass the aux filter's "canvas"
    # size test), never the document. Recording it made Fusion a global floater.
    # (Only when the app has a BIGGER window on screen: a lone small CAD window is a
    # deliberate floater and is kept — test 15e.)
    if [[ "$pos" == *,* && " $CAD_APPS " == *" $norm "* ]] && (( cw * ch * 100 < sw * sh * 45 )) \
       && printf '%s\n' "$wl" | awk -F'|' -v o="$owner" -v a=$(( cw * ch )) \
            '$1==o && $4*$5>a {f=1} END{exit !f}'; then
      continue
    fi
    # Not committed to this space (clicked/Dock-opened/dragged in) → leave it out
    # entirely, as a member AND as a coverer, so it can't evict real members either.
    # A loose window of an existing floater is the exception (floaters are sticky) —
    # never a canon app's, which is never a floater.
    if [[ "$members" != *" $norm "* ]]; then
      [[ "$pos" == *,* ]] && ! is_canon_app "$norm" && is_floater_member_anywhere "$norm" || continue
    fi
    higher="$higher$cx $cy $cw $ch"$'\n'         # this window can cover ones below
    visible="$visible$pos|$norm"$'\n'
  done <<< "$wl"

  # One member per app, preferring its tile-matching (docked) window over any loose
  # one, keeping front-to-back order. A multi-window app (Fusion's main canvas plus
  # its palettes and helper windows) thus records ONCE at its real home, instead of
  # each extra window landing as its own member — the duplication that, combined with
  # the old canon→full coercion, metastasised Fusion across every space.
  #
  # NOTE: this dedup only helps when the canvas AND its palettes are on screen
  # TOGETHER (it then keeps the tiled canvas, drops the rest). It does NOTHING for the
  # palette-ALONE case — a palette floating on a space the canvas isn't on, where the
  # palette is the only "Fusion" window and dedup has nothing better to choose. That
  # case (the real Fusion-vanishes bug) is handled upstream by win_list_raw's filter,
  # not here. See the ⚠️ block on this function.
  local deduped
  deduped=$(printf '%s' "$visible" | grep -v '^$' | awk -F'|' '
    function istile(p){return p=="full"||p=="left"||p=="right"||p=="top-left"||p=="top-right"||p=="bottom-left"||p=="bottom-right"}
    { app=$2; pos=$1
      if(!(app in idx)){ idx[app]=++n; order[n]=app; chosen[app]=pos; tiled[app]=istile(pos) }
      else if(istile(pos) && !tiled[app]){ chosen[app]=pos; tiled[app]=1 } }
    END{ for(i=1;i<=n;i++) print chosen[order[i]] "|" order[i] }')

  # Guard against a transient empty read: never wipe a slot to nothing. (A read that
  # DID see windows, none of them this slot's, means its members really are gone.)
  [[ -z "${deduped//[$'\n']/}" && -z "$saw" ]] && { log "failsafe: no visible tiles, slot $cur unchanged"; return; }

  # Native spaces: a member with NO window on this desktop at all is usually not
  # gone but BORROWED — Claude, shared by the Safari and Chrome slots, was just
  # moved to the slot being switched to. Keep it (at its old spot, beneath the
  # visible members) while the app still has a window on some desktop. (Covered ≠
  # absent: a member seen but hidden under another still drops, as before.)
  local kept="" ka kp kz kn kns
  if spaces_on; then
    while IFS='|' read -r ka kp kz; do
      [[ -z "$ka" || "$present" == *" $ka "* ]] && continue
      kns=(); while IFS= read -r kn; do kns+=("$kn"); done < <(settings_alt_names "$ka")
      space_query has "${kns[@]}" 2>/dev/null && kept+="$kp|$ka"$'\n'
    done < <(members_of "$cur")
  fi

  # A canon app is never a floater: one that reads loose (no window of it on a tile)
  # is recorded on its tile — read now, while the slot still holds where it was — and
  # snapped back there once the hand lets go.
  local canon_fix="" cf_pos cf_app cf_t
  while IFS='|' read -r cf_pos cf_app; do
    [[ "$cf_pos" == *,* ]] && is_canon_app "$cf_app" || continue
    cf_t=$(canon_tile "$cf_app" "$cur")
    canon_fix+="$cf_app|$cf_t"$'\n'
    deduped=$(printf '%s\n' "$deduped" | awk -F'|' -v a="$cf_app" -v t="$cf_t" -v OFS='|' '$2==a{$1=t} 1')
  done <<< "$deduped"
  [[ -n "$canon_fix" ]] && kept=$(printf '%s' "$kept" | SLOTS_FIX="$canon_fix" awk -F'|' '
    BEGIN{ n=split(ENVIRON["SLOTS_FIX"], L, "\n"); for(i=1;i<=n;i++){ split(L[i], p, "|"); if(p[1]!="") fix[p[1]]=1 } }
    !($2 in fix)')

  # Rebuild membership to exactly this set, re-adding back-to-front so the frontmost
  # visible window ends up top of z-order (focus on swipe-back).
  remove_app_everywhere_in_slot "$cur"
  while IFS='|' read -r pos norm; do
    [[ -z "$norm" ]] && continue
    set_member "$cur" "$norm" "$pos"            # borrowed members first: lowest z
  done < <(printf '%s' "$kept")
  while IFS='|' read -r pos norm; do
    [[ -z "$norm" ]] && continue
    set_member "$cur" "$norm" "$pos"
    set_lastpos "$norm" "$pos"
  done < <(printf '%s\n' "$deduped" | tail -r)
  log "failsafe: slot $cur ← $(printf '%s' "$deduped" | tr '\n' ' ')${kept:+ (kept, on another desktop: $(printf '%s' "$kept" | tr '\n' ' '))}"
  _CAD_AUX_DONE=""                              # the aux cache may be this desktop's, not the screen's
  while IFS='|' read -r cf_app cf_t; do
    [[ -z "$cf_app" ]] && continue
    if [[ -n "$SLOT_DRYRUN" ]]; then canon_snap_back "$cf_app" "$cf_t"
    else canon_snap_back "$cf_app" "$cf_t" </dev/null >/dev/null 2>&1 & disown; fi
  done <<< "$canon_fix"
}

# Reconcile each app's recorded position across spaces, after SLOT has been brought
# in line with what's actually on screen. The leaving space is authoritative, but
# the two window kinds are treated differently:
#   - SNAPPED member (a tile): one app, one tile across spaces — drop the app from
#     every OTHER slot that holds it at a different position, so a tiled window
#     never shows up in conflicting spots in different spaces.
#   - FLOATING member (literal "x,y,w,h"): the user drags/resizes these freely, so
#     a moved floater must NOT be evicted from its other spaces. Instead propagate
#     its new geometry to those spaces so they all remember where it now sits.
# A slot emptied by a snapped eviction is left in place (empty spaces are preserved).
prune_other_positions() {       # slot whose positions win
  local slot="$1" app pos z
  while IFS='|' read -r app pos z; do
    [[ -z "$app" ]] && continue
    if [[ "$pos" == *,* ]]; then
      sync_app_pos_except   "$app" "$pos" "$slot"   # floater: keep & sync geometry
    else
      remove_app_diffpos_except "$app" "$pos" "$slot"   # snapped: one tile across spaces
    fi
  done < <(members_of "$slot")
}

# Record a floating window's CURRENT on-screen geometry and propagate it to every
# space that holds it (and to lastpos), so peeling/closing it here — or summoning
# it later — never yanks it to a stale spot. Only fires for apps already recorded
# as a floater somewhere; snapped/tiled apps are left untouched (their position is
# governed by tiles + the one-app-one-position rule). No-op under dryrun or when the
# window isn't found on screen.
refresh_floater_geom() {        # app (state key)
  [[ -n "$SLOT_DRYRUN" ]] && return
  is_floater_member_anywhere "$1" || return
  local a="$1" owner x y w h geom=""
  while IFS='|' read -r owner x y w h; do
    [[ "$(normalize "$owner")" == "$a" ]] && { geom="$x,$y,$w,$h"; break; }
  done < <(win_list_raw)
  [[ -z "$geom" ]] && return
  mem_keep -v a="$a" -v g="$geom" -v OFS='|' '$2==a && $3 ~ /,/ { $3=g } 1'   # all floating copies
  set_lastpos "$a" "$geom"
  log "refresh_floater_geom: $a → $geom (synced across spaces)"
}

# ── operations ────────────────────────────────────────────────────────────────
op_init() {
  [[ -s "$SEQ" ]] && return
  : > "$MEM"; : > "$LP"; : > "$SEQ"
  # One reliable enumeration of running regular apps (matches old simple_nav).
  local running_raw=""
  if [[ -z "$SLOT_DRYRUN" ]]; then
    running_raw=$(osascript -e \
      'tell application "System Events" to get name of every process whose background only is false' \
      2>/dev/null | tr ',' '\n' | sed 's/^ *//')
  fi
  local app slot first="" frontslot="" front; front=$(front_app)
  for app in "${APPS[@]}"; do
    if [[ -z "$SLOT_DRYRUN" ]]; then
      app_running "$app" "$running_raw" || continue
    fi
    slot=$(next_slot)
    seq_append "$slot"
    set_member "$slot" "$app" full
    set_lastpos "$app" full
    [[ -z "$first" ]] && first="$slot"
    [[ "$app" == "$front" ]] && frontslot="$slot"
  done
  set_current "${frontslot:-$first}"
  log "init: seq=($(seq_read | tr '\n' ' ')) current=$(get_current)"
}

op_nav() {
  local dir="${1:?+1/-1}"
  seq_array
  local n=${#SEQ_ARR[@]}; [[ $n -eq 0 ]] && { log "nav: empty seq"; return 1; }
  local cur; cur=$(get_current)
  local d=${dir#+}
  if spaces_on; then
    # Native spaces: the leaving-space reconcile is the slow part of a swipe, and
    # the flip doesn't need it — it runs after (reconcile_left).
    local here; here=$(slot_of_active_space)
    if [[ -z "$here" ]]; then
      # On a desktop that is no slot's (3ds Max's full-screen space, a spare): a
      # swipe goes back to the current slot rather than past it.
      log "nav $dir: off-slot desktop → back to $cur"
      do_restore "$cur"
      local f; f=$(focus_of "$cur"); switched "$f" "$f"; return
    fi
    [[ "$here" != "$cur" ]] && { goto_slot "$cur" "$here"; cur="$here"; }   # a native switch we missed
  else
    failsafe_adopt_snapped "$cur"                # reconcile the slot we're leaving
    prune_other_positions "$cur"                 # one app, one position across spaces
  fi
  local prevfocus; prevfocus=$(focus_of "$cur")  # after reconcile = frontmost visible

  # Navigate from the current space to its neighbour in the sequence (wrapping).
  # Duplicate spaces are left intact — we no longer collapse an identical older
  # copy when swiping away.
  local from="$cur" tgt=""
  local idx; idx=$(seq_index "$cur"); [[ "$idx" -lt 0 ]] && idx=0
  tgt="${SEQ_ARR[$(( ( (idx + d) % n + n ) % n ))]}"

  if [[ "$tgt" == "$from" ]]; then               # only one space left → nowhere to go
    set_current "$from"
    log "nav $dir: staying on $from"
    do_restore "$from"
    echo "$prevfocus|$prevfocus"; return
  fi

  goto_slot "$from" "$tgt"
  local newfocus; newfocus=$(focus_of "$tgt")
  # CAD apps always take focus when present — ensures cad_handoff fires correctly
  local cad_in_tgt; cad_in_tgt=$(awk -F'|' -v s="$tgt" -v cads=" $CAD_APPS " \
    '$1==s && index(cads, " " $2 " ") {print $2; exit}' "$MEM" 2>/dev/null)
  [[ -n "$cad_in_tgt" ]] && newfocus="$cad_in_tgt"
  # Sticky floater keeps focus across the swipe: if the app you were actually
  # working in (the real keyboard-focused app, not just whatever floats on top) is
  # a floating window, keep it focused on arrival too — it stays "active in the new
  # space" as the user expects — overriding the CAD grab above. Using front_app
  # (not focus_of, which is always the on-top floater) honours the "*if* it's
  # active" condition: typing in the snapped app underneath won't trigger this.
  # (Native spaces: realize_plan.py applies this rule itself from the window query
  # it already has — floaters are on every desktop — so skip the ~40ms lookup.)
  local active=""; spaces_on || active=$(front_app)
  if [[ -n "$active" ]] && is_floater_member_anywhere "$active"; then
    local fg; fg=$(floater_geom "$active")
    [[ -n "$fg" ]] && { set_member "$tgt" "$active" "$fg"; newfocus="$active"; }
  fi
  log "nav $dir: $from($prevfocus) → $tgt($newfocus)"
  do_restore "$tgt"
  switched "$prevfocus" "$newfocus"
  spaces_on && reconcile_left "$from"
}

# Native spaces: the leaving-space reconcile, run AFTER the flip — in this mode the
# failsafe reads the slot's OWN desktop (space_query winlist), shown or not, so it
# can run whenever. It is handed to a background `reconcile_slot` that starts a
# moment later, so this op releases the lock now: a quick second swipe no longer
# waits ~0.5s behind the first one's bookkeeping. EXCLUDE as for
# failsafe_adopt_snapped.
reconcile_left() {              # slot [exclude]
  ( sleep "${SLOT_RECONCILE_DELAY:-1}"
    exec bash /Users/josh/Code/Scripts/slots/slotlib.sh reconcile_slot "$1" "$2" ) >/dev/null 2>&1 &
}
# Runs WITHOUT the op lock (see dispatch): the slow part — reading the desktop and
# rebuilding membership — works on a copy of the state, and the lock is taken only
# for the few ms it takes to swap the result in, so it never holds up a switch. If
# a switch changed the state meanwhile, the result is dropped (the next leave of
# that slot reconciles it again).
op_reconcile_slot() {           # slot [exclude] — the deferred half of reconcile_left
  seq_read | grep -qxF "$1" || return 0           # destroyed meanwhile
  # Unlocked here, so it can wait out a UI Zoom glide (the swipe it follows may have
  # left mid-glide, still resizing this slot's windows) rather than skip the sync.
  zoom_wait
  local t; t=$(mktemp -d "${TMPDIR:-/tmp}/slotrec.XXXXXX") || return 0
  cp "$MEM" "$t/m0" 2>/dev/null; cp "$t/m0" "$t/m" 2>/dev/null
  cp "$LP" "$t/l0" 2>/dev/null || : > "$t/l0"; cp "$t/l0" "$t/l"
  cp "$ZC" "$t/z" 2>/dev/null
  local rmem="$MEM" rlp="$LP" rzc="$ZC"
  MEM="$t/m"; LP="$t/l"; ZC="$t/z"
  failsafe_adopt_snapped "$1" "$2"
  prune_other_positions "$1"
  MEM="$rmem"; LP="$rlp"; ZC="$rzc"
  if ! cmp -s "$t/m" "$t/m0" || ! cmp -s "$t/l" "$t/l0"; then
    slot_lock
    if cmp -s "$MEM" "$t/m0" && { cmp -s "$LP" "$t/l0" || [[ ! -s "$LP" && ! -s "$t/l0" ]]; }; then
      mv "$t/m" "$MEM"; mv "$t/l" "$LP"; [[ -f "$t/z" ]] && cp "$t/z" "$ZC"
      # Emptied and not on screen → drop it, so its desktop goes back to the free
      # pool (empty slots kept their desktops until none was left for a new slot).
      # A grid cell is a fixed space: it keeps its place and its desktop.
      if [[ "$(slot_member_count "$1")" -eq 0 && "$1" != "$(get_current)" ]] \
         && [[ " $(grid_py cells 2>/dev/null) " != *" $1 "* ]]; then
        seq_remove "$1"; log "reconcile_slot $1: emptied → removed from the sequence"
      fi
    else
      log "reconcile_slot $1: state changed meanwhile — result dropped"
    fi
    slot_unlock
  fi
  rm -rf "$t"
}

# Focus app A in its space. If A is already snapped in the CURRENT space, just bring
# it to the front there — no jump. Otherwise jump to the next slot in the sequence
# (after the current one, wrapping) that has A snapped, restore it, and focus A. If A
# is snapped in no slot but exists as a floater, raise it in the current space. If A
# is in no slot at all, echo "|" so the caller can fall back (e.g. activate/launch).
op_navapp() {
  local A; A=$(normalize "${1:?app}")
  unfloat_canon                                   # a canon app is never a floater
  grid_navapp "$A" && return                      # the grid places it: its cell
  seq_array
  local n=${#SEQ_ARR[@]}; [[ $n -eq 0 ]] && { echo "|"; return; }
  local cur; cur=$(get_current); local idx; idx=$(seq_index "$cur")
  [[ "$idx" -lt 0 ]] && idx=0

  # Already snapped in the CURRENT space → just focus it here; never teleport to
  # another space that also holds it. The forward walk below deliberately skips the
  # current slot, so without this an app assigned to the current space would jump
  # away to its next occurrence instead of simply coming to the front. We test the
  # RECORDED membership (not what's merely on screen): an app genuinely assigned here
  # stays put, while one only summoned on top of this space to jump elsewhere is left
  # to the jump path below (with its leaving-space reconcile that excludes the target).
  if is_snapped_member "$cur" "$A"; then
    failsafe_adopt_snapped "$cur"                  # reconcile current — A is a real member, not excluded
    local prevfocus; prevfocus=$(focus_of "$cur")
    local posA; posA=$(awk -F'|' -v s="$cur" -v a="$A" '$1==s&&$2==a{print $3; exit}' "$MEM" 2>/dev/null)
    fill_layout_companions "$cur" "$A" "$posA"
    set_member "$cur" "$A" "$posA"                 # (re-)assert A and bump to top-of-z = focus target
    log "navapp $A: already snapped in current $cur → focus in place (no jump)"
    do_restore "$cur"
    switched "$prevfocus" "$A"
    return
  fi

  # Walk forward from the slot after current, wrapping, for the first where A is
  # SNAPPED (occupies a tile). A floating window — recorded at literal "x,y,w,h"
  # geometry, never a tile name — is deliberately NOT a jump target: the hotkey
  # only teleports you to a space where the app has a real docked home, it doesn't
  # chase a loose floater around the sequence.
  #
  # A layout with same-tile alternatives (Claude + Safari|Chrome) first prefers a
  # space whose contested tiles already hold the most recently used alternative;
  # failing that, the space it lands on gets that alternative swapped in below.
  local i j tgt="" tidx=-1 picks p w alts ok
  picks=$(layout_alt_picks "$A")
  if [[ -n "$picks" ]]; then
    for (( i=1; i<=n; i++ )); do
      j=$(( (idx + i) % n ))
      is_snapped_member "${SEQ_ARR[$j]}" "$A" || continue
      ok=1
      while IFS='|' read -r p w alts; do
        [[ "$(alt_at "${SEQ_ARR[$j]}" "$p" "$alts")" == "$w" ]] || ok=""
      done <<< "$picks"
      [[ -n "$ok" ]] && { tgt="${SEQ_ARR[$j]}"; tidx=$j; break; }
    done
  fi
  if [[ -z "$tgt" ]]; then
    # Every slot where A is snapped, in one awk (not one per slot — this is the
    # app-hotkey path), then the first of them after current.
    local snapped_in; snapped_in=" $(awk -F'|' -v a="$A" '$2==a &&
      ($3=="full"||$3=="left"||$3=="right"||$3=="top-left"||$3=="top-right"||$3=="bottom-left"||$3=="bottom-right") {printf "%s ", $1}' "$MEM" 2>/dev/null)"
    for (( i=1; i<=n; i++ )); do
      j=$(( (idx + i) % n ))
      if [[ "$snapped_in" == *" ${SEQ_ARR[$j]} "* ]]; then tgt="${SEQ_ARR[$j]}"; tidx=$j; break; fi
    done
  fi

  # No space has A snapped. If A exists anywhere as a floater, just bring it to the
  # front of the CURRENT space — no jump, no new space, no snap. If A is in no slot
  # at all, report "unassigned" so goto_app can placeapp it into its own new space.
  if [[ -z "$tgt" ]]; then
    # A is snapped in NO space. A non-canon app is a floater: just bring it to the
    # front of the CURRENT space — no jump, no new space, no snap. A canon app is
    # never a floater, so one snapped nowhere falls through to placeapp below.
    if ! is_canon_app "$A"; then
      # Reconcile the current space with reality before raising A into it — same
      # reason as op_activate: the do_restore below would otherwise replay a stale
      # snapshot, re-tiling nudged windows and burying any unadopted window in the
      # `below` sub-layer. (The do_activate branch is a plain raise and unaffected,
      # but reconciling first keeps prevfocus and state honest in both branches.)
      failsafe_adopt_snapped "$cur"
      local prevfocus; prevfocus=$(focus_of "$cur")
      # Register/bump A in the current slot at its live geometry (so it reads as
      # front and becomes sticky), then raise that one window in place. Never snap
      # a non-canon app to a tile — that's the resize-to-full bug.
      local fg; fg=$(floater_geom "$A"); [[ "$fg" == *,* ]] || fg=$(live_geom "$A")
      [[ "$fg" == *,* ]] && { set_member "$cur" "$A" "$fg"; set_lastpos "$A" "$fg"; refresh_floater_geom "$A"; }
      log "navapp $A: floater → raise only in current slot $cur (scene untouched)"
      raise_floater "$A"
      switched "$prevfocus" "$A"
      return
    fi
    log "navapp $A: not a member of any slot"; echo "|"; return
  fi

  spaces_on || failsafe_adopt_snapped "$cur" "$A"   # reconcile the slot we're leaving (ignore the just-summoned target); spaces: after the flip
  local prevfocus; prevfocus=$(focus_of "$cur")  # after reconcile = frontmost visible
  # Bump A to top-of-z in the target so do_restore/scene_restore focuses it.
  local posA; posA=$(awk -F'|' -v s="$tgt" -v a="$A" '$1==s&&$2==a{print $3; exit}' "$MEM" 2>/dev/null)
  [[ -n "$picks" ]] && apply_alt_picks "$tgt" "$picks"
  fill_layout_companions "$tgt" "$A" "$posA"
  set_member "$tgt" "$A" "$posA"
  goto_slot "$cur" "$tgt"
  log "navapp $A: $cur[$idx] → $tgt[$tidx], focusing $A"
  do_restore "$tgt"
  switched "$prevfocus" "$A"
  spaces_on && reconcile_left "$cur" "$A"
}

# Snap front app A into the current slot at POS. `full` is just a position like
# any other: since it overlaps every other position, remove_overlapping_members
# clears the slot, leaving A as the sole (fill-screen) member. No dedicated
# fullscreen slot, no pending state — fill-screen stays in the current space.
op_snap() {
  local pos="${1:?position}"
  local A; A=$(focused_app)             # the focused window, not whatever floats on top
  [[ -z "$A" ]] && { log "snap: no front app"; return 1; }
  local cur; cur=$(get_current)

  # A FLOATER (snapped in no space) snapped to full gets a space of its own, inserted
  # after the current one — the current space keeps its members, so the app hotkey
  # still finds them there (Control Room filling the screen no longer replaces the
  # Claude pair it was summoned over). Only when the current space holds some other
  # snapped app; alone, it just fills the current space as below.
  if [[ "$pos" == full ]] && ! is_snapped_anywhere "$A" && [[ -n "$cur" ]] \
     && (( $(snapped_survivors "$cur" "$A") > 0 )); then
    local prevfocus; prevfocus=$(focus_of "$cur")
    remove_app_everywhere "$A"
    local ns; ns=$(next_slot)
    set_member "$ns" "$A" full
    set_lastpos "$A" full
    seq_insert_after "$cur" "$ns"
    goto_slot "$cur" "$ns"
    log "snap full: floater $A → own new slot $ns after $cur (seq now $(seq_read | tr '\n' ' '))"
    do_move "$A" full
    do_restore "$ns"
    switched "$prevfocus" "$A"
    return
  fi

  # Snapping ALWAYS produces a snapped, NON-sticky tile member — even if A was a
  # floater. A window in a snapped position is treated like any canon snapped
  # window: it's recorded at the tile name (so the app hotkey jumps to its space),
  # it participates in the coverage rule, and it sits on the `normal` layer beneath
  # the floaters (never sticky-on-top). do_move + do_activate below put it on the
  # normal sub-layer; if it was a sticky floater, pin_loose_above un-sticks it.
  remove_app_everywhere "$A"                 # drop any prior floater membership/geometry
  remove_overlapping_members "$cur" "$pos"   # evict anything overlapping POS (full = all)
  set_member "$cur" "$A" "$pos"
  set_lastpos "$A" "$pos"
  remove_app_diffpos_except "$A" "$pos" "$cur"
  destroy_empty_slots
  set_current "$cur"
  log "snap $pos: $A in slot $cur"
  do_move "$A" "$pos"
  do_activate "$A"                           # pin_loose_above keeps it below the floaters
}

# Duplicate the current space into a NEW slot inserted one to the right, and make
# that the current slot. The new slot is an exact copy of the current one (same
# members, positions, relative z-order), so the screen is unchanged — no window
# is moved, activated, or restored. The user then edits this fresh copy however
# they like; the original is left intact and reappears on swipe-back.
op_fullnew() {
  local cur; cur=$(get_current)
  [[ -z "$cur" ]] && { log "fullnew: no current slot"; return 1; }
  local focus; focus=$(focus_of "$cur")
  local ns; ns=$(next_slot)
  # Copy members in z ascending order (members_of is already sorted that way) so
  # each set_member assigns a fresh, increasing z — preserving the original
  # stacking, and thus the same top-of-z focus app.
  local app pos z
  while IFS='|' read -r app pos z; do
    [[ -z "$app" ]] && continue
    set_member "$ns" "$app" "$pos"
  done < <(members_of "$cur")
  seq_insert_after "$cur" "$ns"               # new space one to the right
  set_current "$ns"
  log "fullnew: duplicated $cur → $ns (now current), $(slot_member_count "$ns") member(s)"
  echo "$focus|$focus"                          # focus unchanged → cad_handoff no-ops
}

# Back to the space we were on before this one (prev_slot), keeping this one —
# remap_open.sh's toggle-off when Control Room is on its own space: hiding it there
# would leave an empty desktop (and the leave-reconcile would empty its slot).
op_back() {
  local cur; cur=$(get_current); local prev; prev=$(get_prev)
  if [[ -z "$prev" || "$prev" == "$cur" ]] || ! seq_read | grep -qxF "$prev"; then
    log "back: no previous slot to return to"; return 1
  fi
  spaces_on || failsafe_adopt_snapped "$cur"
  local prevfocus; prevfocus=$(focus_of "$cur")
  goto_slot "$cur" "$prev"
  local newfocus; newfocus=$(focus_of "$prev")
  log "back: $cur($prevfocus) → $prev($newfocus)"
  do_restore "$prev"
  switched "$prevfocus" "$newfocus"
  spaces_on && reconcile_left "$cur"
}

op_activate() {
  local A; A=$(normalize "${1:?app}")
  local cur; cur=$(get_current)
  unfloat_canon                                   # a canon app is never a floater
  # A has its own space (full there) and isn't on this one → go to that space, as
  # the app hotkey would. Joining here at its last position (full) would wipe this
  # space — Control Room summoned over the Claude pair used to replace it.
  if ! awk -F'|' -v s="$cur" -v a="$A" '$1==s&&$2==a{f=1} END{exit !f}' "$MEM" 2>/dev/null \
     && [[ -n "$(full_slot_elsewhere "$A" "$cur")" ]]; then
    log "activate $A: has its own space → navapp"
    op_navapp "$A"
    return
  fi
  # Reconcile the current space with what's actually on screen BEFORE imposing any
  # recorded layout. do_restore below replays the slot's stored members; without
  # this it replays a STALE snapshot — re-tiling windows the user has since nudged
  # and pushing any window the slot never adopted into yabai's `below` sub-layer,
  # where it vanishes behind everything (reads as "summoning Finder destroyed /
  # moved the other windows in the space"). Adopting first makes the summoned app
  # raise INTO the live scene instead of replacing it, matching nav/navapp/placeapp
  # which already reconcile the space they touch.
  failsafe_adopt_snapped "$cur"
  local prevfocus; prevfocus=$(focus_of "$cur")

  # The failsafe just reconciled the current space, so A's recorded position here
  # (if any) reflects how it actually sits on screen: a tile if it's snapped, a
  # literal "x,y,w,h" if it's loose.
  local pos; pos=$(awk -F'|' -v s="$cur" -v a="$A" '$1==s&&$2==a{print $3; exit}' "$MEM" 2>/dev/null)

  # Not a member here, but already sitting on a tile (clicked onto the screen, which
  # the reconcile no longer commits) → this summon is the explicit act that commits
  # it: join at that tile, evicting what it overlaps (coverage rule).
  if [[ -z "$pos" ]]; then
    local lg; lg=$(live_geom "$A")
    if [[ "$lg" == *,* ]]; then
      local tp; tp=$(tile_for_geom $(clamp_to_screen ${lg//,/ }))
      if [[ -n "$tp" ]]; then
        remove_overlapping_members "$cur" "$tp"
        pos="$tp"; set_lastpos "$A" "$tp"
      fi
    fi
  fi

  # SNAPPED member of the current slot (a tile) → reveal at that tile, bumping it
  # to the top of z so the reveal focuses it. Canon and non-canon snapped windows
  # alike take this path.
  if is_tile_name "$pos"; then
    set_member "$cur" "$A" "$pos"            # bump A to top-of-z = restore focus target
    set_current "$cur"
    log "activate $A: snapped member of $cur at $pos, revealing"
    do_restore "$cur"
    switched "$prevfocus" "$A"
    return
  fi

  # FLOATER: any non-canon app (a canon one never is — unfloat_canon). Bringing
  # it forward must ONLY raise that one window — never do_restore (which would
  # re-tile the snapped scene and inject the other sticky floaters). Register it at
  # its current geometry so it sticks; if we can't read a geometry (it's hidden /
  # off-screen) just raise it and let the next reconcile adopt it — but NEVER snap
  # a non-canon app to a tile, which is the resize-to-full bug.
  if ! is_canon_app "$A"; then
    local fg; fg=$(floater_geom "$A"); [[ "$fg" == *,* ]] || fg=$(live_geom "$A")
    if [[ "$fg" == *,* ]]; then
      set_member "$cur" "$A" "$fg"; set_lastpos "$A" "$fg"
      refresh_floater_geom "$A"
    fi
    destroy_empty_slots
    set_current "$cur"
    log "activate $A: floater → raise in place${fg:+ at $fg} (scene untouched)"
    raise_floater "$A"
    switched "$prevfocus" "$A"
    return
  fi

  # CANON app not yet on this space → it joins the current space at its LAST tile
  # (canon_tile: never loose). Only an app with no recorded history at all falls back
  # to full. A genuinely full window still overlaps everything, so it simply fills
  # this space rather than getting one of its own. (Coverage rule applies.)
  local lp; lp=$(lastpos "$A"); is_tile_name "$lp" || lp=$(canon_tile "$A")
  remove_overlapping_members "$cur" "$lp"
  set_member "$cur" "$A" "$lp"               # top-of-z = restore focus target
  destroy_empty_slots
  set_current "$cur"
  log "activate $A: canon joined slot $cur at $lp"
  do_restore "$cur"                          # layered reveal instead of bare activation
  switched "$prevfocus" "$A"
}

op_close() {
  local A; A=$(front_app)
  [[ -z "$A" ]] && return 1
  local cur; cur=$(get_current)
  # A's position in the CURRENT space, so we can adopt whatever it was covering.
  local posA; posA=$(awk -F'|' -v s="$cur" -v a="$A" '$1==s&&$2==a{print $3; exit}' "$MEM" 2>/dev/null)
  remove_app_everywhere "$A"
  clear_lastpos "$A"
  do_quit "$A"
  # The current space is NEVER destroyed by closing — only the deliberate
  # `destroy` removes a slot. Keep current put and restore it; if A was its only
  # member the slot survives (empty, or adopting whatever is revealed below).
  do_restore "$cur"
  # Adopt whatever is now revealed in A's vacated rectangle, so what's on screen
  # behind the closed app becomes the space.
  if [[ -n "$posA" ]]; then
    local revealed; revealed=$(window_at_pos "$posA" "$A")
    revealed=$(normalize "$revealed")
    if [[ -n "$revealed" ]] && ! is_member "$cur" "$revealed"; then
      set_member "$cur" "$revealed" "$posA"
      set_lastpos "$revealed" "$posA"
      log "close: $revealed revealed at $posA → adopted into slot $cur"
    fi
  fi
  local newfocus; newfocus=$(focus_of "$cur")
  log "close $A: space $cur preserved, focus=$newfocus"
  echo "$A|$newfocus"
}

# Destroy the current slot: drop all its members and remove it from the
# sequence. Apps that were ONLY in this slot become unassigned (still running,
# just untracked); apps also in other slots keep those memberships. Nothing is
# quit or hidden. We then land on a neighbour and restore it (like close).
op_destroy() {
  local cur; cur=$(get_current)
  [[ -z "$cur" ]] && return 1
  local prevfocus; prevfocus=$(focus_of "$cur")
  remove_app_everywhere_in_slot "$cur"        # solo apps fall out of all slots = unassigned
  destroy_empty_slots                         # removes cur from seq, moves current to a neighbour
  local nf; nf=$(focus_of "$(get_current)")
  log "destroy $cur: members dropped, current now $(get_current) focus=$nf"
  do_restore "$(get_current)"
  echo "$prevfocus|$nf"
}

# An app quit by ANY means (Dock quit, ⌘Q, crash) — not just our `close` script.
# Wired to yabai's application_terminated signal (via slots/app_terminated.sh).
#
# Two jobs:
#   1. Prune every recorded member whose app is no longer running, so a quit app
#      never lingers as a phantom member (which is what made a swiped-away space
#      adopt the previous space's window and duplicate it).
#   2. Destroy any space the quit reduced to a BARE FULL-SCREEN SHELL: the quit app
#      was that space's `full` member and no other SNAPPED app survives there.
#      Floaters don't count — they're sticky/global and live on every space anyway.
#      A space whose quit app was only a side/corner tile, or that still has another
#      snapped app, is left as-is (just minus the dead member).
# If a destroyed space is the current one, land on a neighbour and restore it, and
# emit PREV|NEW so the wrapper can run the CAD handoff. Emits nothing to act on
# otherwise.
op_app_terminated() {
  [[ -s "$MEM" ]] || return
  # One reliable enumeration of running regular apps (same source as op_init).
  # Tests inject the list via SLOT_RUNNING instead of hitting AX.
  local running_raw
  if [[ -n "${SLOT_RUNNING+x}" ]]; then
    running_raw="$SLOT_RUNNING"
  else
    running_raw=$(osascript -e \
      'tell application "System Events" to get name of every process whose background only is false' \
      2>/dev/null | tr ',' '\n' | sed 's/^ *//')
  fi
  # An AX hiccup (empty list) must NOT be read as "everything quit" — bail.
  [[ -z "$running_raw" ]] && return

  # Dead = recorded apps that are no longer running.
  local dead=() a
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    app_running "$a" "$running_raw" || dead+=("$a")
  done < <(awk -F'|' '{print $2}' "$MEM" 2>/dev/null | sort -u)
  [[ ${#dead[@]} -eq 0 ]] && return

  local cur; cur=$(get_current)

  # Decide which slots to destroy BEFORE mutating membership: a dead app sat at
  # `full` there and no snapped app survives once the dead apps are removed.
  # A grid cell is never destroyed: it stays put (current too), so Toggle there
  # brings the quit app back instead of flipping the cell current fell to.
  local kill_slots=() s cells; cells=" $(grid_py cells 2>/dev/null) "
  seq_array
  for s in "${SEQ_ARR[@]}"; do
    [[ "$cells" == *" $s "* ]] && continue
    local had_full=0
    for a in "${dead[@]}"; do
      [[ "$(awk -F'|' -v s="$s" -v a="$a" '$1==s&&$2==a{print $3;exit}' "$MEM" 2>/dev/null)" == "full" ]] \
        && had_full=1
    done
    [[ $had_full -eq 1 && "$(snapped_survivors "$s" "${dead[@]}")" -eq 0 ]] && kill_slots+=("$s")
  done

  # Prune the dead apps from every slot and forget their last-positions.
  for a in "${dead[@]}"; do remove_app_everywhere "$a"; clear_lastpos "$a"; done
  log "app_terminated: pruned dead apps [${dead[*]}]"

  [[ ${#kill_slots[@]} -eq 0 ]] && return     # nothing reduced to a bare full shell

  # Where to land if we're destroying the space we're on (compute while it's still
  # in the sequence so neighbour/last-space logic works).
  local cur_killed=0 land="" prevfocus=""
  if printf '%s\n' "${kill_slots[@]}" | grep -qxF "$cur"; then
    cur_killed=1
    prevfocus=$(focus_of "$cur")
    land=$(land_after_destroy "$cur")
  fi

  for s in "${kill_slots[@]}"; do
    remove_app_everywhere_in_slot "$s"        # drop any leftover floater rows for this slot
    seq_remove "$s"
    log "app_terminated: destroyed bare full-screen slot $s"
  done

  [[ $cur_killed -eq 0 ]] && return           # a background space died; current is untouched

  # The landing slot may itself have been destroyed (e.g. two full apps quit at
  # once); fall back to the first surviving slot.
  if [[ -z "$land" ]] || ! seq_read | grep -qxF "$land"; then
    land=$(seq_read | head -1)
  fi
  [[ -z "$land" ]] && { set_current ""; return; }   # nothing left at all
  set_current "$land"
  local nf; nf=$(focus_of "$land")
  log "app_terminated: current $cur destroyed, landed on $land focus=$nf"
  do_restore "$land"
  echo "$prevfocus|$nf"
}

# Window-close that respects slot membership (bind this to your Cmd-W).
# It NEVER closes/quits a window — it just removes the front app from the CURRENT
# space and hides it (moves it off-screen), so it reads as "closed" here while
# staying open everywhere else and whatever was behind it comes forward:
#   - app a member of the current slot: remove it from THIS slot only and hide
#     it. If it was also in other slots it stays a (visible) member there; if it
#     was only here it becomes unassigned but keeps running. Either way the
#     window is preserved, not closed. If a window underneath exactly tiles the
#     vacated rectangle, that app is adopted into the slot in its place.
#   - app frontmost but NOT a member of the current slot (a true floating window,
#     or a window whose app is tracked in a different slot): just hide it. There's
#     no slot membership to peel out, but it still leaves this space (kept open,
#     never closed), even if it ends up assigned to no slot at all.
# Emit a winclose result, first honouring an optional refocus app: if set and it
# isn't the app we just peeled, re-raise it so focus returns to where it was.
finish_winclose() {             # peeledApp refocusApp newFocus
  local A="$1" refocus="$2" nf="$3"
  if [[ -n "$refocus" && "$refocus" != "$A" ]]; then
    do_activate "$refocus"; nf="$refocus"
  fi
  echo "$A|$nf"
}

op_winclose() {
  # Operate on the app named in $1 if given (see remove_app.sh), else the front
  # app (the Cmd-W case). Either way it's peeled out of the current space, never
  # closed/quit.
  local A; A="${1:-$(front_app)}"
  [[ -z "$A" ]] && { echo "|"; return; }   # system/unmanaged surface — never close, nothing to hide
  # Arg-driven (remove_app.sh): the target may not be frontmost, so remember who
  # really is and re-raise them after the peel — hiding the named app shouldn't
  # steal focus from the app the user was actually working in. (Empty in the
  # Cmd-W case, where the target IS the front app and refocus would be a no-op.)
  local refocus=""; [[ -n "$1" ]] && refocus="$(front_app)"
  local cur; cur=$(get_current)
  local prevfocus; prevfocus=$(focus_of "$cur")
  local posA; posA=$(awk -F'|' -v s="$cur" -v a="$A" '$1==s&&$2==a{print $3; exit}' "$MEM" 2>/dev/null)

  # Sticky floater: a floating window lives on EVERY space, so "removing" it peels
  # it from all of them at once and hides it (kept open, never closed) — matching
  # its global presence rather than just this space. Once it's a floater nowhere,
  # do_restore stops injecting it, so it stays gone until snapped/opened again.
  if is_floater_member_anywhere "$A"; then
    remove_app_everywhere "$A"
    clear_lastpos "$A"
    do_hide "$A"
    do_restore "$cur"
    local nf; nf=$(focus_of "$cur")
    log "winclose: $A is a sticky floater → removed from ALL spaces and hidden"
    finish_winclose "$A" "$refocus" "$nf"; return
  fi

  # Full-screen group: A fills the whole space (its sole `full` member). Closing
  # it here destroys the entire group and swipes to the space we came from last
  # (else the adjacent one) — like a deliberate `destroy` aimed back the way we
  # came. A is NOT closed: it just becomes unassigned from this space (still
  # running, still a member of any other space) and is left behind, covered by
  # the space we land on. The only exception is when this is the sole remaining
  # space — there's nowhere to go, so fall through to the normal peel below
  # (spaces are never destroyed down to nothing).
  if [[ "$posA" == "full" ]]; then
    local tgt; tgt=$(land_after_destroy "$cur")
    if [[ -n "$tgt" ]]; then
      remove_app_everywhere_in_slot "$cur"        # drop the group's members
      seq_remove "$cur"
      set_current "$tgt"
      local nf; nf=$(focus_of "$tgt")
      log "winclose: $A was full-screen → destroyed group $cur, landed on $tgt (focus=$nf)"
      do_restore "$tgt"
      echo "$A|$nf"; return
    fi
  fi

  # Multi-window app (Finder etc.): the slot model is app-keyed — a group that
  # contains this app is stored as ONE member name no matter how many of its
  # windows are tiled there. So we must NOT touch slot state: removing the member
  # would look like the slot emptied and destroy_empty_slots would wipe the whole
  # space (taking the group's other windows with it). Just close the one front
  # window natively and leave every bit of slot state — and the space — intact.
  # Whatever was behind the closed window comes forward on its own.
  if [[ "$(app_window_count "$A")" -gt 1 ]] 2>/dev/null; then
    do_close_front_window "$A"
    local nf; nf=$(front_app)
    log "winclose: $A is multi-window — closed front window only; slot state untouched"
    finish_winclose "$A" "$refocus" "$nf"; return
  fi

  # Before this window leaves the space, snapshot where the user actually has it now
  # and sync that to every space that holds it (floaters only — snapped/tiled apps
  # are a no-op). Keeps the other spaces from yanking it to a stale spot later.
  refresh_floater_geom "$A"

  if [[ -z "$posA" ]]; then
    # App is frontmost but not a recorded member of the current slot (floating
    # window, or its app belongs to a different slot). Never close it — just hide
    # it so it leaves this space and whatever is behind comes forward. It keeps
    # running (and stays a member of any other slot it belongs to). State here is
    # untouched; restore the current slot so focus settles on what's revealed.
    do_hide "$A"
    do_restore "$cur"
    local nf; nf=$(focus_of "$cur")
    log "winclose: $A not a member of $cur — hidden (kept open), not closed"
    finish_winclose "$A" "$refocus" "$nf"; return
  fi

  # Member of the current slot → peel it out of THIS space and hide it. The
  # window is kept open (never closed/quit); it stays in any other slots. The
  # current space is NEVER destroyed by closing a window — only the deliberate
  # `destroy` does that — so even if A was this slot's only member the slot
  # survives (it just goes empty, or adopts whatever A was covering).
  remove_member "$cur" "$A"
  do_hide "$A"
  do_restore "$cur"

  # Adopt whatever is now revealed in A's vacated rectangle so what's on screen
  # behind the closed window becomes the space. If nothing tiles it, the slot
  # simply loses A (possibly going empty) but stays in the sequence.
  local revealed; revealed=$(window_at_pos "$posA" "$A")
  revealed=$(normalize "$revealed")
  if [[ -n "$revealed" ]] && ! is_member "$cur" "$revealed"; then
    set_member "$cur" "$revealed" "$posA"
    set_lastpos "$revealed" "$posA"
    log "winclose: $revealed revealed at $posA → adopted into slot $cur"
  fi

  local nf; nf=$(focus_of "$cur")
  log "winclose $A: removed from $cur (kept open, space preserved), focus=$nf"
  finish_winclose "$A" "$refocus" "$nf"
}

# ── the grid (slots/grid.py; MODEL.md § The grid) ─────────────────────────────
# Fixed spaces on a 3×3 grid, swiped between in four directions. grid.py decides
# (which cell, which apps); these apply it. Mirrored in slotd.py (grid_seed …).
grid_py() { SLOT_STATE_DIR="$SDIR" /usr/bin/python3 /Users/josh/Code/Scripts/slots/grid.py "$@"; }

# Running process names for a swipe's no-launch rules: $SLOT_RUNNING, else live; exit 1
# when unknown (a dry run without SLOT_RUNNING, or it empty) → nothing skipped.
grid_procs() {
  if [[ -n "${SLOT_RUNNING+x}" ]]; then [[ -n "$SLOT_RUNNING" ]] && printf '%s\n' "$SLOT_RUNNING"; return; fi
  [[ -z "$SLOT_DRYRUN" ]] && ps -axco comm= 2>/dev/null
}

grid_seed() {                  # slot [focus] [nolaunch] → the cell's picks at their tiles, focus on top
  local slot="$1" focus="$2" nolaunch="$3" rows a p q z s cells hit out procs keep
  rows=$(grid_py seed "$slot" "$focus"); [[ -n "$rows" ]] || return 1
  out=$(grid_py outside "$slot")
  # A swipe (NOLAUNCH): a pick that isn't open is left out, its tile empty (2026-11-15).
  if [[ -n "$nolaunch" && -z "$out" ]] && procs=$(grid_procs); then
    keep=""; while IFS='|' read -r a p; do app_running "$a" "$procs" && keep+="$a|$p"$'\n'; done <<< "$rows"
    rows="${keep%$'\n'}"; [[ -n "$rows" ]] || return 1
  fi
  [[ -z "$out" ]] &&                               # residents behind 3ds Max: never launched
    while IFS='|' read -r a p; do ensure_running "$a"; done <<< "$rows"
  seq_read | grep -qxF "$slot" || { seq_append "$slot"; log "grid: $slot back in the sequence"; }
  while IFS='|' read -r a p z; do                  # whatever else sits on those tiles leaves
    [[ -z "$a" || "$p" == *,* ]] && continue
    grep -qxF "$a|$p" <<< "$rows" && continue
    hit=0; while IFS='|' read -r _ q; do pos_overlaps "$q" "$p" && hit=1; done <<< "$rows"
    (( hit )) && remove_member "$slot" "$a"
  done < <(members_of "$slot")
  cells=" $(grid_py cells) "
  while IFS='|' read -r a p; do                    # one app, one place: off the off-grid slots
    while IFS='|' read -r s q; do
      [[ -z "$s" || "$cells" == *" $s "* || "$q" == *,* ]] && continue
      remove_member "$s" "$a"; log "grid: $a left off-grid $s"
      if [[ "$(slot_member_count "$s")" -eq 0 && "$s" != "$(get_current)" ]]; then
        seq_remove "$s"; log "grid: off-grid $s emptied → removed from the sequence"
      fi
    done < <(app_slots "$a")
  done <<< "$rows"
  while IFS='|' read -r a p; do set_member "$slot" "$a" "$p"; set_lastpos "$a" "$p"; done <<< "$rows"
}

grid_here() {                  # → sets GCUR (current, followed to the active desktop) + GHERE
  GCUR=$(get_current); GHERE=""
  if spaces_on; then
    GHERE=$(slot_of_active_space)
    [[ -n "$GHERE" && "$GHERE" != "$GCUR" ]] && { goto_slot "$GCUR" "$GHERE"; GCUR="$GHERE"; }
    # On no slot's desktop while current's cell shows 3ds Max: that's Max's Space.
    [[ -z "$GHERE" && -n "$(grid_py outside "$GCUR")" ]] && GHERE="$GCUR"
  else
    GHERE="$GCUR"; failsafe_adopt_snapped "$GCUR"; prune_other_positions "$GCUR"
  fi
}

# TGT's cell shows an outside app (3ds Max): current becomes TGT, Max's own Space
# is shown (app_resolve.sh's open_coherence), the cell's desktop and residents stay
# as they are. Not on its Space yet → 1, the residents are shown. Mirrors slotd's
# grid_outside.
grid_outside() {               # cur here tgt prevfocus why → 0 if handled
  local a; a=$(grid_py outside "$3"); [[ -n "$a" ]] || return 1
  if [[ -z "$SLOT_DRYRUN" ]]; then
    # Until it sits full screen on its own Space the cell shows its residents and
    # the app is opened in the background (as slotd's grid_outside).
    local fs; fs=$(space_query json 2>/dev/null | jq -r --arg a "$a" \
      '. as $r | ([.windows[] | select(.app == $a and (.spaces | length) == 1)] | max_by(.w * .h) | .spaces[0]) as $id
       | [$r.spaces[] | select(.id == $id) | .fullscreen][0] // empty')
    # Ready → this flips to its Space; not running → launches it. A starting one
    # is left to its own launch (coherence_fullscreen waits for the window).
    if [[ "$fs" == 1 ]] || { ! pgrep -q WinAppHelper && ! pgrep -qf 'coherence_fullscreen.sh|open_coherence'; }; then
      ( exec -a open_coherence /bin/bash -c 'source /Users/josh/Code/Scripts/app_resolve.sh; resolve_app "$0"
        /Users/josh/Code/Scripts/max/vm.sh ensure; open_coherence' "$a" ) </dev/null >/dev/null 2>&1 &
    fi
    [[ "$fs" == 1 && ! -e /tmp/.vm_paused_by_slots ]] || { log "$5: $a not ready — showing $3"; return 1; }
  fi
  goto_slot "$1" "$3"
  log "$5: $1($4) → $3($a, its own desktop)"
  switched "$4" "$a"
  [[ -n "$2" && "$3" != "$1" ]] && spaces_on && reconcile_left "$1"
  return 0
}

grid_go() {                    # cur here tgt focus why [nolaunch]
  local cur="$1" here="$2" tgt="$3" focus="$4" why="$5" prevfocus newfocus cad
  prevfocus=$(focus_of "$cur")
  grid_seed "$tgt" "$focus" "$6" || { log "$why: grid cell $tgt is empty"; echo "$prevfocus|$prevfocus"; return; }
  grid_outside "$cur" "$here" "$tgt" "$prevfocus" "$why" && return 0
  newfocus="$focus"
  if [[ -z "$newfocus" ]]; then
    newfocus=$(focus_of "$tgt")
    cad=$(awk -F'|' -v s="$tgt" -v cads=" $CAD_APPS " '$1==s && index(cads, " " $2 " ") {print $2; exit}' "$MEM" 2>/dev/null)
    [[ -n "$cad" ]] && newfocus="$cad"
  fi
  goto_slot "$cur" "$tgt"
  log "$why: $cur($prevfocus) → $tgt($newfocus)"
  do_restore "$tgt"
  switched "$prevfocus" "$newfocus"
  # Control Room not shown in its cell: put away, or it covers the pick (op_gridtoggle).
  [[ -z "$SLOT_DRYRUN" ]] && grid_py unshown "$tgt" | grep -qx Remap && pkill -USR2 -x Remap
  [[ -n "$here" && "$tgt" != "$cur" ]] && spaces_on && reconcile_left "$cur" "$focus"
  return 0
}

op_swipe() {                   # left|right|up|down
  local d="${1:?direction}" tgt procs a run=""
  grid_here
  # Cells none of whose shown apps is open are skipped (grid.py live), never launched.
  if procs=$(grid_procs); then
    while IFS= read -r a; do [[ -n "$a" ]] && app_running "$a" "$procs" && run+="$a"$'\n'; done < <(grid_py apps)
    tgt=$(GRID_RUNNING="${run%$'\n'}" grid_py swipe "$([[ -n "$GHERE" ]] && echo "$GCUR")" "$d")
  else
    tgt=$(grid_py swipe "$([[ -n "$GHERE" ]] && echo "$GCUR")" "$d")
  fi
  if [[ -z "$tgt" ]]; then
    local f; f=$(focus_of "$GCUR"); log "swipe $d: nothing that way from $GCUR"; echo "$f|$f"; return
  fi
  grid_go "$GCUR" "$GHERE" "$tgt" "" "swipe $d" nolaunch
}

op_gridtoggle() {              # flip the current cell's alternatives (focused position first)
  grid_here
  local f; f=$(focus_of "$GCUR")
  if [[ -z "$GHERE" ]] || ! grid_py has "$GCUR"; then
    log "gridtoggle: ${GCUR:-this desktop} is not a grid cell — nothing to toggle"; echo "$f|$f"; return
  fi
  local shown focus r p old new dead=() a procs
  shown=$(grid_py seed "$GCUR" | cut -d'|' -f1)
  focus=$(members_of "$GCUR" | awk -F'|' 'NR==FNR{s[$1]=1; next} ($1 in s){a=$1} END{print a}' <(echo "$shown") -)
  if [[ -z "$SLOT_DRYRUN" ]]; then             # a quit pick comes back first (grid.toggle)
    procs=$(ps -axco comm= 2>/dev/null)
    while IFS= read -r a; do [[ -n "$a" ]] && ! app_running "$a" "$procs" && dead+=("$a"); done <<< "$shown"
  fi
  r=$(grid_py toggle "$GCUR" "$focus" "${dead[@]}")
  [[ -z "$r" ]] && { log "gridtoggle: $GCUR has nothing to toggle"; echo "$focus|$focus"; return; }
  IFS='|' read -r p old new <<< "$r"
  grid_seed "$GCUR" "$new"
  grid_outside "$GCUR" "$GCUR" "$GCUR" "$old" "gridtoggle $p" && return
  set_current "$GCUR"
  log "gridtoggle: $GCUR $p $old → $new"
  do_restore "$GCUR"
  switched "$old" "$new"
  # Control Room's window sits on the `above` sub-layer (RemapApp floatAbove; yabai
  # can't reach it), so nothing sharing its tile can be raised over it: toggled away
  # it is put away (SIGUSR2, its ✕), toggled to it is summoned (SIGUSR1).
  if [[ -z "$SLOT_DRYRUN" && "$old" != "$new" ]]; then
    if [[ "$new" == Remap ]]; then pkill -USR1 -x Remap
    elif [[ "$old" == Remap ]]; then pkill -USR2 -x Remap; fi
  fi
}

grid_navapp() {                # app → 0 (and switched) if the grid places it
  local r; r=$(grid_py pick "$1"); [[ -n "$r" ]] || return 1
  grid_here
  grid_go "$GCUR" "$GHERE" "${r%%|*}" "$1" "navapp $1 (grid)"
}

# ── placement (give an unassigned app its own new space) ──────────────────────
# Splice a brand-new fill-screen space for an app that lives in NO slot, sitting
# it next to its canonical neighbour in the APPS sequence. See goto_app.sh.

canon_index() {                # app → its index in APPS (canonical order), or -1
  local a="$1" i=0 x
  for x in "${APPS[@]}"; do [[ "$x" == "$a" ]] && { echo "$i"; return; }; i=$((i+1)); done
  echo -1
}

# Seq indices (ascending) of the slots that currently contain app A. Reads the
# live sequence; repopulates SEQ_ARR as a side effect (caller re-reads if needed).
occ_indices() {                # app → "i j k …" (space separated, may be empty)
  local a="$1"; seq_array
  local s i=0 out=()
  for s in "${SEQ_ARR[@]}"; do is_member "$s" "$a" && out+=("$i"); i=$((i+1)); done
  echo "${out[*]}"
}

ringdist() {                   # a b n → shorter cyclic distance between indices
  local a=$1 b=$2 n=$3
  local d=$(( ((a-b)%n+n)%n )) d2=$(( ((b-a)%n+n)%n ))
  (( d2<d )) && d=$d2; echo "$d"
}

# Anchor occurrence for a neighbour app, on a given side. Echoes "tier idx":
#   tier 0 = exclusive (app in exactly one slot), 1 = shared (several slots)
#   idx    = seq index of the occurrence the new space should abut
# For a SIDE=after neighbour (a predecessor) we want the occurrence with the
# largest *forward* gap to the next occurrence — i.e. the forward edge of the
# biggest empty arc — so the new space lands just after it, outside any cluster
# and in the larger gap. SIDE=before (a successor) is the mirror: largest
# *backward* gap. With one occurrence the gap is the whole ring, so the sole slot
# is the anchor; with a consecutive block the biggest gap sits at the block's
# outer edge — one rule covers exclusive, consecutive and gapped alike.
neighbour_anchor() {           # app side(after|before) → "tier idx" or ""
  local a="$1" side="$2"
  local occ=($(occ_indices "$a")); local m=${#occ[@]}
  [[ $m -eq 0 ]] && return
  local tier=1; [[ $m -eq 1 ]] && tier=0
  if [[ $m -eq 1 ]]; then echo "$tier ${occ[0]}"; return; fi
  seq_array; local n=${#SEQ_ARR[@]}
  local k best=-1 bestgap=-1 g nbr
  for ((k=0;k<m;k++)); do
    if [[ "$side" == "after" ]]; then nbr=${occ[$(((k+1)%m))]}; g=$(( ((nbr-occ[k])%n+n)%n ))
    else                              nbr=${occ[$(((k-1+m)%m))]}; g=$(( ((occ[k]-nbr)%n+n)%n )); fi
    (( g>bestgap )) && { bestgap=$g; best=${occ[k]}; }
  done
  echo "$tier $best"
}

# Given up to two candidate anchors ("tier idx" each, with their sides) and the
# current seq index, pick the better — exclusive beats shared, then nearest to
# current — and set PLACE_AFTER (slot id to insert after) / PLACE_HEAD.
choose_anchor() {              # panchor pside sanchor sside cidx
  local pa="$1" ps="$2" sa="$3" ss="$4" cidx="$5"
  seq_array; local n=${#SEQ_ARR[@]}
  local cands=() t i
  if [[ -n "$pa" ]]; then read -r t i <<< "$pa"; cands+=("$t $(ringdist "$i" "$cidx" "$n") $i $ps"); fi
  if [[ -n "$sa" ]]; then read -r t i <<< "$sa"; cands+=("$t $(ringdist "$i" "$cidx" "$n") $i $ss"); fi
  [[ ${#cands[@]} -eq 0 ]] && return 1
  local best; best=$(printf '%s\n' "${cands[@]}" | sort -k1,1n -k2,2n | head -1)
  local _t _d idx side; read -r _t _d idx side <<< "$best"
  if [[ "$side" == "after" ]]; then PLACE_AFTER="${SEQ_ARR[$idx]}"
  elif (( idx == 0 )); then PLACE_HEAD=1
  else PLACE_AFTER="${SEQ_ARR[$((idx-1))]}"; fi
  return 0
}

# Decide where the new space for X goes. Sets PLACE_AFTER (slot to insert after)
# or PLACE_HEAD=1. Priority: (1) strictly between X's predecessor and successor
# when their two spaces are already adjacent; (2) the single best neighbour
# anchor (predecessor→after, successor→before); (3) search canonically outward
# for the nearest present app; (4) append at the end.
place_decide() {               # X
  local X="$1"; PLACE_AFTER=""; PLACE_HEAD=""
  seq_array; local n=${#SEQ_ARR[@]}; local N=${#APPS[@]}
  local cur cidx; cur=$(get_current); cidx=$(seq_index "$cur"); [[ "$cidx" -lt 0 ]] && cidx=0
  local ci; ci=$(canon_index "$X")
  if [[ "$ci" -ge 0 ]]; then
    local P="${APPS[$(((ci-1+N)%N))]}" S="${APPS[$(((ci+1)%N))]}"
    # (1) between predecessor & successor if their spaces are adjacent
    local pocc=($(occ_indices "$P")) socc=($(occ_indices "$S"))
    seq_array
    local p s bestd=2147483647 bestp=-1 d
    for p in "${pocc[@]}"; do for s in "${socc[@]}"; do
      if (( s == (p+1)%n )); then
        d=$(ringdist "$p" "$cidx" "$n"); (( d<bestd )) && { bestd=$d; bestp=$p; }
      fi
    done; done
    if (( bestp >= 0 )); then PLACE_AFTER="${SEQ_ARR[$bestp]}"; return; fi
    # (2) single best neighbour anchor
    local pa sa; pa=$(neighbour_anchor "$P" after); sa=$(neighbour_anchor "$S" before)
    if [[ -n "$pa" || -n "$sa" ]]; then choose_anchor "$pa" after "$sa" before "$cidx" && return; fi
    # (3) search outward along the canonical sequence
    local r Pi Si pa2 sa2
    for ((r=2;r<=N/2;r++)); do
      Pi=$(( ((ci-r)%N+N)%N )); Si=$(( (ci+r)%N ))
      pa2=$(neighbour_anchor "${APPS[$Pi]}" after)
      sa2=$(neighbour_anchor "${APPS[$Si]}" before)
      if [[ -n "$pa2" || -n "$sa2" ]]; then choose_anchor "$pa2" after "$sa2" before "$cidx" && return; fi
    done
  fi
  # (4) nothing canonical to anchor to → append at the end
  seq_array; PLACE_AFTER="${SEQ_ARR[$((${#SEQ_ARR[@]}-1))]}"
}

# ── custom-default-layout helpers (placeapp pairing) ──────────────────────────
# layout_for APP        → the spec string for the layout APP is the primary of, or ""
# spec_pos SPEC APP     → APP's tile position within SPEC, or ""
# owners_of APP         → primaries (config order) of every layout APP is a companion in
# app_fits_at APP POS   → 0 if APP can join a space at POS: it is in no slot, or every
#                         slot it is in already records it at POS (never elsewhere).
layout_for() {                 # app → spec | ""
  local app="$1" e
  for e in "${PLACE_LAYOUTS[@]}"; do [[ "${e%%|*}" == "$app" ]] && { echo "${e#*|}"; return; }; done
}
spec_pos() {                   # spec app → pos | ""
  local spec="$1" app="$2" tok IFS=';'
  for tok in $spec; do [[ "${tok%:*}" == "$app" ]] && { echo "${tok##*:}"; return; }; done
}
owners_of() {                  # app → primary names (one per line, config order)
  local app="$1" e prim spec tok found
  for e in "${PLACE_LAYOUTS[@]}"; do
    prim="${e%%|*}"; spec="${e#*|}"
    [[ "$prim" == "$app" ]] && continue          # primary, not a companion, here
    found=""; IFS=';'; for tok in $spec; do [[ "${tok%:*}" == "$app" ]] && found=1; done; unset IFS
    [[ -n "$found" ]] && echo "$prim"
  done
}
app_fits_at() {                # app pos → 0 if app may join a space at pos
  local app="$1" want="$2" _s p
  while IFS='|' read -r _s p; do
    [[ -z "$p" ]] && continue
    [[ "$p" != "$want" ]] && return 1            # already snapped somewhere else
  done < <(app_slots "$app")
  return 0
}

# Recency of slot switches — the tie-break when a layout lists several apps at the
# SAME tile (e.g. Claude:left + Safari:right + Google Chrome:right = "whichever
# browser I used last"). Every user switch (nav/navapp/activate/placeapp) moves the
# app it lands on to the top of $MRU.
mru_touch() {                  # app → move to the front of $MRU
  local a="$1"; [[ -z "$a" ]] && return
  { echo "$a"; grep -vxF -- "$a" "$MRU" 2>/dev/null; } | head -50 > "$MRU.tmp" && mv "$MRU.tmp" "$MRU"
}
# The same-tile choice again, for spaces that ALREADY exist: for each tile of APP's
# layout that lists several alternatives (other than APP's own tile), echo
# "pos|winner|app,app,…" — the winner by pick_recent among those that fit, then the
# full alternative list. Empty when APP has no layout or no contested tile.
layout_alt_picks() {           # app → "pos|winner|alts" lines
  local A="$1" spec; spec=$(layout_for "$A"); [[ -z "$spec" ]] && return
  local toks=() tok app pos xpos="" poss=() p alts cands
  IFS=';' read -r -a toks <<< "$spec"
  for tok in "${toks[@]}"; do
    app="${tok%:*}"; pos="${tok##*:}"
    [[ "$app" == "$A" ]] && xpos="$pos"
    [[ " ${poss[*]} " == *" $pos "* ]] || poss+=("$pos")
  done
  for p in "${poss[@]}"; do
    [[ "$p" == "$xpos" ]] && continue
    alts=(); cands=()
    for tok in "${toks[@]}"; do
      app="${tok%:*}"; pos="${tok##*:}"
      [[ "$pos" == "$p" && "$app" != "$A" ]] || continue
      alts+=("$app"); app_fits_at "$app" "$pos" && cands+=("$app")
    done
    (( ${#alts[@]} > 1 && ${#cands[@]} )) || continue
    echo "$p|$(pick_recent "${cands[@]}")|$(IFS=,; echo "${alts[*]}")"
  done
}
# Which of APP's alternatives sits at POS in SLOT, or "" if none of them does.
alt_at() {                     # slot pos alts(csv) → app | ""
  local s="$1" p="$2" alts=",$3," a
  while IFS='|' read -r a; do
    [[ "$alts" == *",$a,"* ]] && { echo "$a"; return; }
  done < <(awk -F'|' -v s="$s" -v p="$p" '$1==s && $3==p {print $2}' "$MEM" 2>/dev/null)
}
# Put each contested tile's winner into SLOT, replacing whichever alternative is
# there now. Only touches a tile already holding an alternative (the space is
# recognisably that layout); a space arranged some other way is left alone.
apply_alt_picks() {            # slot picks (from layout_alt_picks)
  local s="$1" p w alts occ
  while IFS='|' read -r p w alts; do
    [[ -z "$p" ]] && continue
    occ=$(alt_at "$s" "$p" "$alts")
    [[ -z "$occ" || "$occ" == "$w" ]] && continue
    ensure_running "$w"
    remove_member "$s" "$occ"
    set_member "$s" "$w" "$p"
    set_lastpos "$w" "$p"
    log "layout alt: $s $p $occ → $w (switched to more recently)"
  done <<< "$2"
}

# Re-pair a layout space that lost its companion. A companion that quits (Claude
# auto-updating overnight) is pruned from every space by appterm, and nothing ever
# put it back — so Safari's and Chrome's spaces came back Claude-less for good. When
# navapp lands on a space where A sits at its layout tile, every OTHER tile of A's
# layout that no member covers gets its companion back, chosen and fitted exactly as
# placeapp would (app_fits_at + pick_recent). A tile something else already covers is
# left alone.
fill_layout_companions() {     # slot A A's-pos-in-slot
  local s="$1" A="$2" apos="$3" spec; spec=$(layout_for "$A"); [[ -z "$spec" ]] && return
  [[ "$(spec_pos "$spec" "$A")" == "$apos" ]] || return   # space isn't arranged as A's layout
  local toks=() tok app pos poss=() p cands m mpos taken w
  IFS=';' read -r -a toks <<< "$spec"
  for tok in "${toks[@]}"; do pos="${tok##*:}"; [[ " ${poss[*]} " == *" $pos "* ]] || poss+=("$pos"); done
  for p in "${poss[@]}"; do
    [[ "$p" == "$apos" ]] && continue
    taken=""
    while IFS='|' read -r m mpos _; do
      [[ -n "$m" && "$m" != "$A" ]] && pos_overlaps "$p" "$mpos" && { taken=1; break; }
    done < <(members_of "$s")
    [[ -n "$taken" ]] && continue
    cands=()
    for tok in "${toks[@]}"; do
      app="${tok%:*}"; pos="${tok##*:}"
      [[ "$pos" == "$p" && "$app" != "$A" ]] && app_fits_at "$app" "$pos" && cands+=("$app")
    done
    (( ${#cands[@]} )) || continue
    w=$(pick_recent "${cands[@]}")
    ensure_running "$w"
    set_member "$s" "$w" "$p"
    set_lastpos "$w" "$p"
    log "layout refill: $s $p ← $w (companion missing from $A's space)"
  done
}

switched() {                   # prev new → report "prev|new" (the switch ops' output) + note new
  echo "$1|$2"; mru_touch "$2"
}
# Pick one app from several contenders for the same tile: running beats not running
# (so a quit browser isn't relaunched over an open one), then most recently switched
# to, then config order. Contenders are already filtered to ones that fit.
pick_recent() {                # app… → the winner
  (( $# == 1 )) && { echo "$1"; return; }
  # `ps -c`, not System Events — this runs on the hotkey path (~30ms vs ~0.5s).
  # (pgrep -x misses some apps, e.g. Claude, so match the ps list instead.)
  local running_raw="" a best="" bestk="" i=0 r rank k
  if [[ -n "${SLOT_RUNNING+x}" ]]; then running_raw="$SLOT_RUNNING"
  elif [[ -z "$SLOT_DRYRUN" ]]; then running_raw=$(ps -axco comm= 2>/dev/null); fi
  for a in "$@"; do
    r=0; [[ -n "$running_raw" ]] && { app_running "$a" "$running_raw" || r=1; }
    rank=$(grep -nxF -- "$a" "$MRU" 2>/dev/null | head -1 | cut -d: -f1); [[ -z "$rank" ]] && rank=999
    k=$(printf '%d%04d%04d' "$r" "$rank" "$i"); i=$((i+1))
    if [[ -z "$bestk" ]] || (( 10#$k < 10#$bestk )); then bestk=$k; best=$a; fi
  done
  echo "$best"
}

# Launch app if needed and wait briefly for it to own a window, so do_restore can
# AX-position it. The just-opened primary is already ensured by goto_app.sh; this
# covers companions a layout pulls in (e.g. Claude beside Safari). Best-effort.
ensure_running() {             # state-key app
  local se; se="$(open_name "$1")"
  [[ -n "$SLOT_DRYRUN" ]] && { log "DRY ensure-running $1"; return; }
  # Native spaces: activating a running app jumps to whichever desktop holds its
  # window — realize_slot fetches the window instead, so only launch.
  if spaces_on && app_running "$1" "$(ps -axco comm= 2>/dev/null)"; then return; fi
  open -a "$se" >/dev/null 2>&1
  local i t
  for i in $(seq 1 30); do
    t=$(osascript -e "tell application \"System Events\" to count windows of (first process whose name is \"$se\")" 2>/dev/null)
    [[ "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]] && return
    sleep 0.1
  done
}

# Decide what the new space for the opened app X holds. Sets PLACE_MEMBERS to
# "app|pos" entries with X LAST (so it takes keyboard focus on restore). Three
# outcomes, in order:
#   (A) X is a layout primary  → that layout, dropping companions that don't fit.
#   (B) X is a companion only  → the first layout (config order) whose primary
#                                fits, with X kept as focus at its companion tile.
#   (C) neither / nothing fits → X solo at full (the plain placeapp default).
# A layout collapses to "X|full" whenever no partner is pulled in, so a lone Safari
# fills the screen rather than sitting half-width with an empty left.
place_layout() {               # X → sets PLACE_MEMBERS
  local X="$1"; PLACE_MEMBERS=()
  # Solo default: bring X in at whatever size it actually opened (its docked tile if
  # it launched onto one, else its current geometry), rather than forcing it full —
  # so reopening a quit canon app gives it its own space "however it comes in". Falls
  # back to full when its geometry can't be read (no window yet / dry-run tests).
  # A canon app is never a floater: opened loose, it comes in at full.
  local solo; solo=$(app_dock_pos "$X"); [[ -n "$solo" ]] || solo="full"
  [[ "$solo" == *,* ]] && is_canon_app "$X" && solo="full"
  local spec; spec=$(layout_for "$X")
  if [[ -z "$spec" ]]; then                       # (B) X is a companion elsewhere?
    local owner ppos
    while IFS= read -r owner; do
      [[ -z "$owner" ]] && continue
      ppos=$(spec_pos "$(layout_for "$owner")" "$owner")
      if app_fits_at "$owner" "$ppos"; then spec=$(layout_for "$owner"); break; fi
    done < <(owners_of "$X")
  fi
  if [[ -z "$spec" ]]; then PLACE_MEMBERS=("$X|$solo"); return; fi   # (C) or no fit
  # Build from the chosen spec: companions that fit go first, X last (focus). Several
  # apps at one tile are alternatives, not a stack: X wins its own tile outright,
  # otherwise the fitting contender switched to most recently (pick_recent) takes it.
  local toks=() tok app pos others=() xpos="" poss=() p cands
  IFS=';' read -r -a toks <<< "$spec"
  for tok in "${toks[@]}"; do
    app="${tok%:*}"; pos="${tok##*:}"
    [[ "$app" == "$X" ]] && xpos="$pos"
    [[ " ${poss[*]} " == *" $pos "* ]] || poss+=("$pos")
  done
  for p in "${poss[@]}"; do
    [[ "$p" == "$xpos" ]] && continue
    cands=()
    for tok in "${toks[@]}"; do
      app="${tok%:*}"; pos="${tok##*:}"
      [[ "$pos" == "$p" && "$app" != "$X" ]] && app_fits_at "$app" "$pos" && cands+=("$app")
    done
    (( ${#cands[@]} )) && others+=("$(pick_recent "${cands[@]}")|$p")
  done
  [[ -z "$xpos" ]] && xpos="full"
  if [[ ${#others[@]} -eq 0 ]]; then PLACE_MEMBERS=("$X|$solo")      # nobody fits ⇒ solo
  else PLACE_MEMBERS=("${others[@]}" "$X|$xpos"); fi
}

# Give app X its own NEW space and splice it into the sequence next to its
# canonical neighbour. Assumes X is in no slot (caller checked via navapp). Usually
# a solo fill-screen space; for apps with a custom default layout (PLACE_LAYOUTS)
# it opens as a pair instead (see place_layout). Mirrors navapp's leave-current
# handshake: reconcile the slot we're on, report the focus transition as PREV|X.
op_placeapp() {
  local X; X=$(normalize "${1:?app}")
  seq_array; local n=${#SEQ_ARR[@]}
  local cur; cur=$(get_current)
  # Ignore X in the reconcile: goto_app already launched it (ensure_app_window), so
  # it may be sitting on top of the space we're leaving. Counting it as a coverer
  # would evict that space's real occupant (the "open Podcasts, lose Notes" bug).
  [[ $n -gt 0 ]] && failsafe_adopt_snapped "$cur" "$X"
  local prevfocus; prevfocus=$(focus_of "$cur")
  local ns; ns=$(next_slot)
  place_layout "$X"
  local m app pos
  for m in "${PLACE_MEMBERS[@]}"; do
    app="${m%%|*}"; pos="${m##*|}"
    [[ "$app" == "$X" ]] || ensure_running "$app"   # X is already ensured by goto_app
    set_member "$ns" "$app" "$pos"
    set_lastpos "$app" "$pos"
  done
  seq_array; n=${#SEQ_ARR[@]}          # ns not yet in the sequence
  if [[ $n -eq 0 ]]; then
    seq_write "$ns"
  else
    place_decide "$X"
    if [[ -n "$PLACE_HEAD" ]]; then seq_array; seq_write "$ns" "${SEQ_ARR[@]}"
    else seq_insert_after "$PLACE_AFTER" "$ns"; fi
  fi
  goto_slot "$cur" "$ns"
  log "placeapp $X: new slot $ns [${PLACE_MEMBERS[*]}] spliced ${PLACE_HEAD:+at head}${PLACE_AFTER:+after $PLACE_AFTER} (seq now $(seq_read | tr '\n' ' '))"
  do_restore "$ns"
  switched "$prevfocus" "$X"
}

# The user clicked (or ⌘-Tabbed / Dock-clicked) onto a window a reveal had parked on
# yabai's `below` sub-layer — called by slots/app_focused.sh, which only calls it for
# a below window. Activation alone can't lift a `below` window over the `normal`
# ones, so without this the click focuses the app while whatever was in front stays
# in front. Two outcomes:
#   - The window FILLS the screen and A has a space where it is `full` → that click
#     is "go to A's space": switch there exactly as the hotkey would (reconcile the
#     leaving space, restore the target). Visually nothing moves — A already fills
#     the screen — but the engine now agrees you are on A's space.
#   - Anything else → just lift that window to `normal` and raise it. It is NOT
#     committed to this space (per MODEL.md, a clicked window never is), so a
#     later swipe-away leaves it out.
# GEOM ("x y w h") is the clicked window's frame; WID its yabai id.
op_clicked() {
  local A; A=$(normalize "${1:?app}"); local wid="$2" geom="$3"
  is_system_surface "$A" && return
  local cur; cur=$(get_current)
  local x y w h tile=""
  read -r x y w h <<< "$geom"
  [[ -n "$h" ]] && tile=$(tile_for_geom "$x" "$y" "$w" "$h")
  if [[ -n "$cur" && "$tile" == "full" ]] && ! is_member "$cur" "$A"; then
    seq_array; local n=${#SEQ_ARR[@]} idx i j tgt=""
    idx=$(seq_index "$cur"); [[ "$idx" -lt 0 ]] && idx=0
    for (( i=1; i<=n; i++ )); do
      j=$(( (idx + i) % n ))
      [[ "$(awk -F'|' -v s="${SEQ_ARR[$j]}" -v a="$A" '$1==s&&$2==a{print $3; exit}' "$MEM" 2>/dev/null)" == full ]] \
        && { tgt="${SEQ_ARR[$j]}"; break; }
    done
    if [[ -n "$tgt" ]]; then
      failsafe_adopt_snapped "$cur" "$A"
      local prevfocus; prevfocus=$(focus_of "$cur")
      set_member "$tgt" "$A" full
      goto_slot "$cur" "$tgt"
      log "clicked $A: fills the screen → switch $cur → $tgt"
      do_restore "$tgt"
      switched "$prevfocus" "$A"
      return
    fi
  fi
  log "clicked $A: lift window ${wid:-?} off \`below\` (not committed to $cur)"
  if [[ -z "$SLOT_DRYRUN" && -n "$wid" ]]; then
    yabai -m window "$wid" --sub-layer normal 2>/dev/null
    yabai -m window "$wid" --focus 2>/dev/null
  fi
  echo "|"
}

# Live reconcile — the user moved/resized a window by hand (yabai window_moved /
# window_resized signal). Adopt the current space's real on-screen state and
# re-assert the floater layer; NO window is repositioned and the recorded layout
# is NOT re-imposed — we follow what the user just did. This is exactly the
# switch-away reconciliation, minus the switch. Net effect: drag a snapped window
# loose → it is reclassified as a sticky floater (recorded at literal geometry,
# pinned `above`, shown on every space); snap one to a tile by hand → it becomes a
# non-sticky tile member (pulled to `normal`, a jump target). No focus change.
op_reconcile() {
  local cur; cur=$(get_current)
  [[ -z "$cur" ]] && return
  failsafe_adopt_snapped "$cur"     # rebuild current membership from what's on screen
  prune_other_positions "$cur"      # one app/one tile across spaces; sync floater geom
  pin_loose_above                   # floaters back on top, snapped windows un-stuck
}

# Rebuild the whole slot state from the desktops (slot_reset.sh, "Reset slots" in
# Control Room). Native spaces: every desktop is read off the window server — a slot
# whose desktop is gone is dropped; each desktop's tiled windows become its slot's
# members (a desktop with tiled windows but no slot gets a new one), then the usual
# failsafe pass sorts covered / loose / borrowed windows exactly as a swipe would;
# an app tiled on one desktop leaves every other slot that holds it at another tile.
# The cached desktop indices / window ids go too (a stale index flips the fast path
# to the wrong desktop after Mission Control reorders them). Replaces the old
# restore_state.sh snapshot replay, which wiped every slot not on screen.
op_reset() {
  if ! spaces_on; then op_reconcile; do_restore "$(get_current)"; return; fi
  # Every desktop's windows are read as tiles: not while a UI Zoom glide resizes them.
  zoom_wait || log "reset: UI Zoom still gliding after 3s — reading the windows anyway"
  local sp desks; sp=$(space_query json 2>/dev/null) || { log "reset: window server unreadable"; return 1; }
  desks=$(/usr/bin/python3 -c '
import json, sys
for s in json.load(sys.stdin)["spaces"]:
    if s["display"] == 1 and not s["fullscreen"]: print(s["uuid"])' <<< "$sp")
  [[ -z "$desks" ]] && { log "reset: no desktops read"; return 1; }
  local s u before; before=$(seq_read | tr '\n' ' ')
  # A grid app put in macOS full screen (green button) sits on a Space of its own that
  # nothing below looks at: take it out first so it drops back to a desktop, then
  # re-read. Coherence apps (Max) keep their full-screen Space. (Chrome, 2026-10-28.)
  local fsid fsapp fsn fsout=""
  while IFS='|' read -r fsid fsapp; do
    [[ -n "$fsid" ]] || continue
    fsn=$(normalize "$fsapp"); grep -qxF "$fsn" <<< "${COHERENCE_APPS:-}" && continue
    [[ -n "$(grid_py cell "$fsn")" ]] || continue
    yabai -m window "$fsid" --toggle native-fullscreen 2>/dev/null \
      && { fsout=1; log "reset: $fsn window $fsid out of macOS full screen"; }
  done < <(jq -r '[.spaces[] | select(.fullscreen == 1) | .id] as $f
      | .windows[] | select((.spaces | length) == 1 and (.spaces[0] as $s | any($f[]; . == $s)) and .w * .h > 600 * 400)
      | "\(.id)|\(.app)"' <<< "$sp")
  if [[ -n "$fsout" ]]; then
    sleep 1.5                                   # the exit animation lands it on a desktop
    sp=$(space_query json 2>/dev/null) || { log "reset: window server unreadable"; return 1; }
  fi
  while IFS= read -r u; do [[ -n "$u" ]] && remove_app_everywhere "$u"; done <<< "${COHERENCE_APPS:-}"
  seq_array
  for s in "${SEQ_ARR[@]}"; do                  # slots whose desktop is gone
    u=$(awk -F'|' -v s="$s" '$1==s{print $2; exit}' "$SPB" 2>/dev/null)
    if [[ -z "$u" ]] || ! grep -qxF "$u" <<< "$desks"; then
      remove_app_everywhere_in_slot "$s"; seq_remove "$s"
    fi
  done
  # A grid app's real window stranded on a desktop that is no grid cell's (a free
  # one, or an off-grid slot's) goes back to its cell's desktop BEFORE the desktops
  # are read — else this reset made it a slot of its own and every later reset kept
  # it: Chrome sat alone on a spare desktop, unreachable, for a day (2026-10-21).
  local SLOT_WINLIST owner x y w h norm cx cy cw ch pos tiled phys="" app cells cell id cu ci
  cells=" $(grid_py cells) "
  while IFS='|' read -r id owner u; do
    [[ -n "$u" ]] && grep -qxF "$u" <<< "$desks" || continue  # a regular desktop (not Max's full-screen Space)
    norm=$(normalize "$owner"); grep -qxF "$norm" <<< "${COHERENCE_APPS:-}" && continue
    cell=$(grid_py cell "$norm"); [[ -n "$cell" ]] || continue
    s=$(awk -F'|' -v u="$u" '$2==u{print $1}' "$SPB" 2>/dev/null | head -1)
    [[ -n "$s" && "$cells" == *" $s "* ]] && continue          # on a cell's desktop: its own business
    cu=$(awk -F'|' -v s="$cell" '$1==s{print $2; exit}' "$SPB" 2>/dev/null)
    ci=$(jq -r --arg u "$cu" '.spaces[] | select(.uuid == $u) | .index' <<< "$sp")
    [[ -n "$ci" ]] || continue
    yabai -m window "$id" --space "$ci" 2>/dev/null && log "reset: $norm window $id stranded off-grid → $cell (desktop $ci)"
  done < <(jq -r '(.spaces | map({(.id|tostring): .uuid}) | add) as $u
      | .windows[] | select((.spaces | length) == 1 and .w * .h > 600 * 400)
      | "\(.id)|\(.app)|\($u[.spaces[0]|tostring] // "")"' <<< "$sp")
  while IFS= read -r u; do
    SLOT_WINLIST=$(space_query winlist "$u" 2>/dev/null) || continue
    s=$(awk -F'|' -v u="$u" '$2==u{print $1}' "$SPB" 2>/dev/null | grep -xF -f <(seq_read) | head -1)
    tiled=""
    while IFS='|' read -r owner x y w h; do
      [[ -z "$owner" ]] && continue
      norm=$(normalize "$owner"); is_system_surface "$norm" && continue
      # A Coherence app (3ds Max) has no slot — off its own full-screen Space it
      # sits over a slot's desktop, and adopting it there broke every Max jump.
      grep -qxF "$norm" <<< "${COHERENCE_APPS:-}" && continue
      read -r cx cy cw ch < <(clamp_to_screen "$x" "$y" "$w" "$h")
      (( cw <= 0 || ch <= 0 )) && continue
      pos=$(tile_for_geom "$cx" "$cy" "$cw" "$ch" "$x" "$y" "$w" "$h")
      [[ -n "$pos" && "$tiled" != *"|$norm"$'\n'* ]] && tiled+="$pos|$norm"$'\n'
    done <<< "$SLOT_WINLIST"
    if [[ -z "$s" ]]; then
      [[ -z "$tiled" ]] && continue
      s=$(next_slot); seq_append "$s"
      grep -v -e "^$s|" -e "|$u\$" "$SPB" 2>/dev/null > "$SPB.tmp"; echo "$s|$u" >> "$SPB.tmp"; mv "$SPB.tmp" "$SPB"
    fi
    if [[ -z "$tiled" ]]; then                  # nothing tiled here: the slot is stale
      remove_app_everywhere_in_slot "$s"; continue
    fi
    while IFS='|' read -r pos app; do
      [[ -n "$app" ]] && ! is_member "$s" "$app" && set_member "$s" "$app" "$pos"
    done <<< "$tiled"
    _CAD_AUX_DONE=""
    failsafe_adopt_snapped "$s"
    while IFS='|' read -r pos app; do           # what the failsafe kept on its tile
      [[ -n "$app" ]] && is_member "$s" "$app" && phys+="$s|$app|$pos"$'\n'
    done <<< "$tiled"
  done <<< "$desks"
  unset SLOT_WINLIST; _CAD_AUX_DONE=""
  while IFS='|' read -r s app pos; do           # one app, one tile across slots
    [[ -n "$app" ]] && remove_app_diffpos_except "$app" "$pos" "$s"
  done <<< "$phys"
  destroy_empty_slots
  rm -f "$SDIR/slot_space_idx" "$SDIR/slot_winids" "$ACTIVE_DESK" "$SDIR/prev_slot"
  local here; here=$(slot_of_active_space)
  [[ -n "$here" ]] && set_current "$here"
  log "reset: seq ($before) → ($(seq_read | tr '\n' ' ')), current $(get_current); members: $(cut -d'|' -f1-3 "$MEM" | tr '\n' ' ')"
  pin_loose_above all
  do_restore "$(get_current)"
}

# The app whose window is the topmost SNAPPED one on screen (sits on a tile), or
# nothing. Loose windows (floaters, fresh dialogs) above it are looked through.
# Read-only; toggle_app.sh uses it to tell "the target is already in front".
op_topsnapped() {
  [[ -n "$SLOT_DRYRUN" && -z "${SLOT_WINLIST+x}" ]] && return
  local owner x y w h norm cx cy cw ch
  while IFS='|' read -r owner x y w h; do
    [[ -z "$owner" ]] && continue
    norm=$(normalize "$owner")
    is_system_surface "$norm" && continue
    read -r cx cy cw ch < <(clamp_to_screen "$x" "$y" "$w" "$h")
    (( cw <= 0 || ch <= 0 )) && continue
    [[ -n "$(tile_for_geom "$cx" "$cy" "$cw" "$ch")" ]] && { echo "$norm"; return; }
  done < <(win_list_raw)
}

op_dump() {
  echo "seq:        $(seq_read | tr '\n' ' ')"
  echo "current:    $(get_current)"
  echo "members:"
  if [[ -s "$MEM" ]]; then sort -t'|' -k1,1 -k4,4n "$MEM" | sed 's/^/  /'; fi
  echo "lastpos:"
  [[ -s "$LP" ]] && sed 's/^/  /' "$LP"
}

# ── dispatch ──────────────────────────────────────────────────────────────────
op="${1:-}"; shift || true

# Slots switched off (slots/power.sh): the entry points already step aside; this is
# the backstop for anything that calls slotlib directly (yabairc's startup `pin`,
# dock_did_restart). Read-only ops still answer. Dry runs (the test suites) ignore it.
if [[ -f /Users/josh/Code/Scripts/config/slots_off && -z "$SLOT_DRYRUN" ]]; then
  case "$op" in dump|topsnapped) ;; *) exit 0 ;; esac
fi

# Touch the op-guard so the live window_moved/window_resized handler knows a
# script-driven layout change is in flight (scene_restore and do_move reposition
# windows, which themselves fire those signals). The handler skips events for a
# short cooldown after this timestamp so a reveal never triggers a reconcile that
# fights it. `reconcile` and `dump` touch it too — harmless and loop-proof.
touch /tmp/.slot_op_ts 2>/dev/null

# One op at a time. Every op is a read-modify-write of the state files, and they all
# rewrite through the same "$MEM.tmp" — so two ops running at once (a hotkey pressed
# while window_event's reconcile or app_terminated is mid-flight, or two hotkeys in
# quick succession) could interleave and silently drop members: the "slots just stops
# working until I reset it" state. shlock(1) serialises them: it writes our pid into
# the lock file and clears a lock whose pid is dead by itself, so a killed op never
# wedges the rest. A wait past ~10s goes ahead unlocked (logged) rather than eat the
# hotkey. Read-only ops don't lock. The trap only releases a lock this process owns.
# A holder that is alive but has had the lock 20s+ is hung, not busy (2026-10-07: a
# `yabai -m query` that never got its reply held it 30 min, so every op ate the 10s
# wait) — kill it and its children, then take the lock.
LOCKF="$SDIR/.slot_lock"
kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }
# A user jump (SLOT_GEN/SLOT_DEADLINE from slots/jump_stamp.sh) never queues: past
# its 3s deadline, or once a newer jump was pressed, it is dropped instead.
jump_dropped() {
  [[ -n "$SLOT_GEN" ]] || return 1
  case "$op" in nav|navapp|back|activate|placeapp|swipe|gridtoggle) ;; *) return 1 ;; esac
  [[ "$(cat /tmp/slot_jump_gen 2>/dev/null)" != "$SLOT_GEN" ]] && { log "dropped $op: superseded by a newer jump"; return 0; }
  (( $(date +%s) >= SLOT_DEADLINE )) && { log "dropped $op: past its 3s deadline"; return 0; }
  return 1
}
slot_lock() {
  local i holder age
  for (( i=0; i<200; i++ )); do
    if /usr/bin/shlock -f "$LOCKF" -p $$ 2>/dev/null; then
      trap slot_unlock EXIT
      jump_dropped && exit 0
      unset SLOT_GEN SLOT_DEADLINE      # this op's children are not jumps
      return 0
    fi
    (( i % 5 == 4 )) && jump_dropped && exit 0
    sleep 0.05
  done
  holder=$(cat "$LOCKF" 2>/dev/null)
  age=$(( $(date +%s) - $(stat -f %m "$LOCKF" 2>/dev/null || date +%s) ))
  if [[ "$holder" =~ ^[0-9]+$ && "$holder" != "$$" ]] && (( age >= 20 )); then
    log "lock: $op broke a ${age}s-old lock — killing hung pid $holder"
    kill_tree "$holder"; sleep 0.1; rm -f "$LOCKF"
    /usr/bin/shlock -f "$LOCKF" -p $$ 2>/dev/null && { trap slot_unlock EXIT; return 0; }
  fi
  log "lock: $op waited 10s on pid $holder, running unlocked"
}
slot_unlock() { [[ "$(cat "$LOCKF" 2>/dev/null)" == "$$" ]] && rm -f "$LOCKF"; }
case "$op" in
  dump|topsnapped|reconcile_slot|pinhere|"") ;;        # reconcile_slot locks only its swap-in; pinhere only reads state
  # Best effort, never queued: an op holding the lock re-reads the active desktop
  # itself, and a spacesync that waited out a long op (then ran unlocked) was one of
  # the ways a stall turned into lost slot members.
  spacesync) /usr/bin/shlock -f "$LOCKF" -p $$ 2>/dev/null || exit 0; trap slot_unlock EXIT ;;
  *) slot_lock ;;
esac

# Freeze-frame overlay: only user-initiated SWITCHES get the screenshot-cover (so the
# whole transition is hidden behind a still frame). Background ops (reconcile, winclose,
# appterm, …) must NOT flash a frozen frame, so they leave SCENE_FREEZE unset. Read by
# scene_restore P0a. nav=swipe, navapp/placeapp=jump-to-app, activate=focus, fullnew=new space.
case "$op" in
  nav|navapp|back|activate|placeapp|fullnew|swipe|gridtoggle) export SCENE_FREEZE=1 ;;
esac

# Native spaces: macOS switches desktops on its own too (Dock click, ⌘-Tab, Mission
# Control). Before any op that reads "current", follow it there if the active
# desktop is another slot's. (`spacesync` is just this, from the space_changed signal.)
spaces_follow() {
  spaces_on || return 0
  local here cur; here=$(slot_of_active_space); cur=$(get_current)
  [[ -n "$here" && "$here" != "$cur" ]] || return 0
  goto_slot "$cur" "$here"; log "spacesync: desktop switched natively → current $cur → $here"
}
case "$op" in
  navapp|back|placeapp|snap|fullnew|activate|reconcile|close|winclose|destroy|clicked|spacesync) spaces_follow ;;
esac

case "$op" in
  init)      op_init ;;
  spacesync) ;;                                         # spaces_follow above did it
  spacebind) op_init                                    # slots/spaces.sh on: the current slot keeps this desktop
             u=$(yabai -m query --spaces --space 2>/dev/null | jq -r '.uuid // empty'); c=$(get_current)
             [[ -n "$u" && -n "$c" ]] && { grep -v -e "^$c|" -e "|$u\$" "$SPB" 2>/dev/null > "$SPB.tmp"
                                           echo "$c|$u" >> "$SPB.tmp"; mv "$SPB.tmp" "$SPB"; log "spaces: $c bound to the active desktop"; } ;;
  spacepool) op_init; spaces_pool "$@" ;;               # add desktops so every slot has one (+ spares)
  reconcile_slot) op_reconcile_slot "$@" ;;             # native spaces: a left slot's deferred reconcile
  nav)       op_init; op_nav "$@" ;;
  swipe)     op_init; op_swipe "$@" ;;                  # the grid: left|right|up|down
  gridtoggle) op_init; op_gridtoggle ;;                 # the grid: flip this cell's alternatives
  navapp)    op_init; op_navapp "$@" ;;
  back)      op_init; op_back ;;
  placeapp)  op_init; op_placeapp "$@" ;;
  snap)      op_init; op_snap "$@" ;;
  fullnew)   op_init; op_fullnew "$@" ;;
  activate)  op_init; op_activate "$@" ;;
  reconcile) op_init; op_reconcile ;;
  close)     op_close ;;
  winclose)  op_winclose "$@" ;;
  destroy)   op_init; op_destroy ;;
  appterm)   op_init; op_app_terminated ;;
  reveal)    op_init; do_restore "$(get_current)" ;;   # realize current slot on screen, no reconcile
  reset)     op_init; op_reset ;;                       # rebuild every slot from the desktops (slot_reset.sh)
  pin)       op_init; pin_loose_above all ;;           # re-assert shadows/sub-layers on EVERY space (yabai start / SA reload)
  pinhere)   pin_loose_above ;;                        # slotd's floater raise: the layer pass, after the activation (no lock)
  dump)      op_dump ;;
  topsnapped) op_topsnapped ;;                        # read-only: app of the topmost tiled window
  clicked)   op_init; op_clicked "$@" ;;              # app_focused.sh: a `below` window was clicked
  *) echo "usage: slotlib.sh {init|nav ±1|navapp App|placeapp App|snap POS|fullnew|activate App|reconcile|close|winclose|destroy|reveal|reset|pin|appterm|spacesync|spacebind|dump|topsnapped|clicked App [wid] [\"x y w h\"]}" >&2; exit 1 ;;
esac
