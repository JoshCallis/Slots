#!/bin/bash
# CLI tests for slotlib.sh — pure logic, no windows touched (SLOT_DRYRUN=1).
# Each test runs a fresh state dir and asserts on `dump` output.

set -u
LIB=/Users/josh/Code/Scripts/slots/slotlib.sh
PASS=0; FAIL=0

newdir() { mktemp -d "${TMPDIR:-/tmp}/slottest.XXXXXX"; }

# run <statedir> <front> <op...>
run() {
  local d="$1" front="$2"; shift 2
  SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
    SLOT_APPS="Podcasts Notes Claude Kindle" \
    SLOT_LAYOUTS="${SLOT_LAYOUTS-}" \
    SLOT_FRONT="$front" bash "$LIB" "$@"
}
dump() { SLOT_STATE_DIR="$1" SLOT_DRYRUN=1 bash "$LIB" dump; }

assert() { # desc, actual, expected
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "   expected: [$3]"; echo "   actual:   [$2]"; fi
}

line() { echo "──────────────────────────────────────────"; }

# Helper: which slot is current, and its members "app:pos" by z
cur_members() {
  local d="$1"
  local cur; cur=$(SLOT_STATE_DIR="$d" bash "$LIB" dump | awk '/^current:/{print $2}')
  SLOT_STATE_DIR="$d" awk -F'|' -v s="$cur" '$1==s{print $2":"$3"|"$4}' "$d/slot_members" \
    | sort -t'|' -k2,2n | cut -d'|' -f1 | paste -sd' ' -
}
seq_of() { SLOT_STATE_DIR="$1" bash "$LIB" dump | awk '/^seq:/{$1="";print}' | xargs; }
current_of() { SLOT_STATE_DIR="$1" bash "$LIB" dump | awk '/^current:/{print $2}'; }
pos_in()  { awk -F'|' -v s="$2" -v a="$3" '$1==s&&$2==a{print $3}' "$1/slot_members"; }
slots_with(){ awk -F'|' -v a="$2" '$2==a{print $1}' "$1/slot_members" | sort -u | paste -sd, -; }

echo "TEST 1: init builds one slot per app, current=frontmost"
d=$(newdir); run "$d" "Claude" init >/dev/null
assert "1.seq has 4 slots" "$(seq_of "$d" | wc -w | xargs)" "4"
assert "1.current is Claude's slot members" "$(cur_members "$d")" "Claude:full"
rm -rf "$d"

echo "TEST 2: nav +1 moves to next slot in sequence"
d=$(newdir); run "$d" "Podcasts" init >/dev/null
# seq order = app list order: Podcasts Notes Claude Kindle
run "$d" "Podcasts" nav +1 >/dev/null
assert "2.after nav+1 current=Notes" "$(cur_members "$d")" "Notes:full"
run "$d" "x" nav +1 >/dev/null
assert "2.after nav+1 current=Claude" "$(cur_members "$d")" "Claude:full"
rm -rf "$d"

echo "TEST 3: bringing a NON-fullscreen app forward joins the current slot at its last pos"
d=$(newdir); run "$d" "Claude" init >/dev/null
run "$d" "Notes" snap right >/dev/null            # Notes becomes non-fullscreen (lastpos=right)
run "$d" "Claude" snap left >/dev/null            # current = Claude's slot, Claude:left
run "$d" "x" activate Notes >/dev/null            # Notes is non-fullscreen → joins current at right
assert "3.current has Claude:left and Notes:right" "$(cur_members "$d")" "Claude:left Notes:right"
rm -rf "$d"

echo "TEST 4: fill-screen snap stays in the current slot and clears it (no new slot)"
d=$(newdir); run "$d" "Podcasts" init >/dev/null  # current=Podcasts slot
run "$d" "Podcasts" nav +1 >/dev/null             # current=Notes slot
run "$d" "Notes" snap left >/dev/null             # Notes:left in current
run "$d" "Claude" snap right >/dev/null           # Claude joins current at right
n_before=$(seq_of "$d" | wc -w | xargs)
run "$d" "Notes" snap full >/dev/null             # fill-screen → clears slot to just Notes
assert "4.fill-screen sole member of current slot" "$(cur_members "$d")" "Notes:full"
assert "4.no new slot created" "$(seq_of "$d" | wc -w | xargs)" "$n_before"
rm -rf "$d"

echo "TEST 5: membership — app stays in both slots until snapped to a NEW pos"
d=$(newdir); run "$d" "Claude" init >/dev/null
run "$d" "Claude" snap left >/dev/null            # Claude:left in slot A (current)
A=$(current_of "$d")
run "$d" "x" nav +1 >/dev/null                    # move to a different slot B
B=$(current_of "$d")
run "$d" "x" activate Claude >/dev/null             # bring Claude fwd → joins B at lastpos(left)
assert "5.Claude in both A and B" "$(slots_with "$d" Claude | tr ',' ' ' | wc -w | xargs)" "2"
assert "5.pos in A still left" "$(pos_in "$d" "$A" Claude)" "left"
assert "5.pos in B is left"    "$(pos_in "$d" "$B" Claude)" "left"
# Now snap Claude to right (different) while in B → should leave A
run "$d" "Claude" snap right >/dev/null
assert "5.after resize Claude only in B" "$(slots_with "$d" Claude)" "$B"
assert "5.pos in B now right" "$(pos_in "$d" "$B" Claude)" "right"
rm -rf "$d"

echo "TEST 6: activating an app that has its own full space goes there (current space kept)"
d=$(newdir); run "$d" "Podcasts" init >/dev/null  # each app:full in own slot; current=Podcasts
C=$(current_of "$d")
n_before=$(seq_of "$d" | wc -w | xargs)
run "$d" "x" activate Kindle >/dev/null           # Kindle is full in its own slot → jump there
assert "6.landed on Kindle's space" "$(cur_members "$d")" "Kindle:full"
assert "6.left space keeps Podcasts" "$(pos_in "$d" "$C" Podcasts)" "full"
assert "6.no new slot created" "$(seq_of "$d" | wc -w | xargs)" "$n_before"
assert "6.no pending file exists" "$(cat "$d/pending_fs" 2>/dev/null)" ""
rm -rf "$d"

echo "TEST 7: fullnew duplicates the current space into a new slot one to the right"
d=$(newdir); run "$d" "Podcasts" init >/dev/null
run "$d" "Podcasts" nav +1 >/dev/null             # current = Notes slot
run "$d" "Notes" snap left >/dev/null             # current group: Notes:left ...
run "$d" "Claude" snap right >/dev/null           #             ... + Claude:right
CUR=$(current_of "$d")
ORIG=$(cur_members "$d")                           # Notes:left Claude:right
run "$d" "Claude" fullnew >/dev/null              # duplicate CUR → new slot right after it
NS=$(current_of "$d")
assert "7.landed on a different (new) slot" "$([[ "$NS" != "$CUR" ]] && echo diff)" "diff"
assert "7.new slot is an exact copy of the origin" "$(cur_members "$d")" "$ORIG"
assert "7.origin slot keeps Notes:left" "$(pos_in "$d" "$CUR" Notes)" "left"
assert "7.origin slot keeps Claude:right" "$(pos_in "$d" "$CUR" Claude)" "right"
ci=$(seq_of "$d" | tr ' ' '\n' | grep -n "^$CUR$" | cut -d: -f1)
ni=$(seq_of "$d" | tr ' ' '\n' | grep -n "^$NS$" | cut -d: -f1)
assert "7.new slot sits right after origin" "$ni" "$((ci+1))"
rm -rf "$d"

echo "TEST 7b: fullnew duplicates a solo-full space too (ignores the front app)"
d=$(newdir); run "$d" "Podcasts" init >/dev/null  # Podcasts:full, current=Podcasts
CUR=$(current_of "$d")
n_before=$(seq_of "$d" | wc -w | xargs)
run "$d" "SomethingElse" fullnew >/dev/null       # front app is irrelevant now
NS=$(current_of "$d")
assert "7b.new slot created" "$(seq_of "$d" | wc -w | xargs)" "$((n_before+1))"
assert "7b.landed on the new slot" "$([[ "$NS" != "$CUR" ]] && echo diff)" "diff"
assert "7b.new slot copies Podcasts:full" "$(cur_members "$d")" "Podcasts:full"
assert "7b.origin slot still Podcasts:full" "$(pos_in "$d" "$CUR" Podcasts)" "full"
rm -rf "$d"

echo "TEST 8: close preserves the space (never destroys it) and stays put"
d=$(newdir); run "$d" "Podcasts" init >/dev/null
run "$d" "Podcasts" nav +1 >/dev/null             # current = Notes slot (solo)
NB=$(current_of "$d")
NSLOTS=$(seq_of "$d" | wc -w | xargs)
run "$d" "Notes" close >/dev/null                 # Notes quit → slot empties but SURVIVES
assert "8.Notes gone from all slots" "$(slots_with "$d" Notes)" ""
assert "8.Notes slot still in seq" "$(seq_of "$d" | tr ' ' '\n' | grep -c "^$NB$" | xargs)" "1"
assert "8.seq size unchanged" "$(seq_of "$d" | wc -w | xargs)" "$NSLOTS"
assert "8.current still on Notes slot" "$(current_of "$d")" "$NB"
rm -rf "$d"

echo "TEST 9: winclose removes a multi-slot app from the CURRENT slot only"
d=$(newdir); run "$d" "Claude" init >/dev/null
run "$d" "Claude" snap left >/dev/null            # Claude:left in slot A (current)
A=$(current_of "$d")
run "$d" "x" nav +1 >/dev/null                    # current = slot B (Kindle solo)
run "$d" "Kindle" snap right >/dev/null           # Kindle:right in B (won't overlap Claude:left)
B=$(current_of "$d")
run "$d" "x" activate Claude >/dev/null             # Claude joins B at left → in A and B, no overlap
assert "9.precondition Claude in 2 slots" "$(slots_with "$d" Claude | tr ',' ' ' | wc -w | xargs)" "2"
run "$d" "Claude" winclose >/dev/null             # front=Claude, current=B → leave B only
assert "9.Claude now only in A" "$(slots_with "$d" Claude)" "$A"
assert "9.current still B" "$(current_of "$d")" "$B"
assert "9.B survived (still has Kindle)" "$(seq_of "$d" | tr ' ' '\n' | grep -c "^$B$" | xargs)" "1"
rm -rf "$d"

echo "TEST 10: winclose on a NON-full single-slot app peels it out (kept open); space SURVIVES empty"
d=$(newdir); run "$d" "Podcasts" init >/dev/null
run "$d" "Podcasts" nav +1 >/dev/null             # current = Notes solo slot
run "$d" "Notes" snap left >/dev/null             # half-screen, so NOT a full-screen group
NB=$(current_of "$d")
run "$d" "Notes" winclose >/dev/null
assert "10.Notes gone from all slots" "$(slots_with "$d" Notes)" ""
assert "10.Notes slot still in seq (not destroyed)" "$(seq_of "$d" | tr ' ' '\n' | grep -c "^$NB$" | xargs)" "1"
assert "10.current still on Notes slot" "$(current_of "$d")" "$NB"
# kept open, not forgotten: its last-position survives so re-activating restores it
assert "10.Notes last-position retained" "$(awk -F'|' -v a=Notes '$1==a{print $2}' "$d/app_lastpos")" "left"
rm -rf "$d"

echo "TEST 11: destroy — solo apps go unassigned, shared apps survive, land on neighbour"
d=$(newdir); run "$d" "Claude" init >/dev/null
run "$d" "Claude" snap left >/dev/null            # Claude:left in slot A (current)
A=$(current_of "$d")
run "$d" "x" nav +1 >/dev/null                    # current = Kindle slot
run "$d" "Kindle" snap right >/dev/null           # Kindle:right (solo in B)
B=$(current_of "$d")
run "$d" "x" activate Claude >/dev/null           # Claude joins B at left (now in A and B)
assert "11.pre: Claude in 2 slots" "$(slots_with "$d" Claude | tr ',' ' ' | wc -w | xargs)" "2"
assert "11.pre: Kindle only in B" "$(slots_with "$d" Kindle)" "$B"
run "$d" "x" destroy >/dev/null                   # destroy current (B)
assert "11.Claude survives in A" "$(slots_with "$d" Claude)" "$A"
assert "11.Kindle now unassigned" "$(slots_with "$d" Kindle)" ""
assert "11.B removed from seq" "$(seq_of "$d" | tr ' ' '\n' | grep -c "^$B$" | xargs)" "0"
assert "11.landed on neighbour A" "$(current_of "$d")" "$A"
rm -rf "$d"

# ── swipe-away failsafe (uses SLOT_WINLIST to mock the on-screen window stack) ──
# navwl <statedir> <front> <winlist> <dir>  — run nav with a mocked window list
navwl() {
  local d="$1" front="$2" wl="$3" dir="$4"
  SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
    SLOT_WINLIST="$wl" SLOT_FRONT="$front" bash "$LIB" nav "$dir"
}
# seed <statedir> writes a 1000x800 screen + a 2-slot seq with current=sA
seed() {
  local d="$1"; shift
  printf '1000 800\n' > "$d/screen_dims"
  printf 'sA\nsB\n' > "$d/slot_seq"
  printf 'sA\n' > "$d/current_slot"
  printf 'sB|Podcasts|full|99\n' > "$d/slot_members"
  local z=1 line
  for line in "$@"; do echo "sA|$line|$z" >> "$d/slot_members"; z=$((z+1)); done
}

echo "TEST 12: failsafe drops windows covered by a fullscreen app on top (the fullnew bug)"
d=$(newdir); seed "$d" "Claude|full" "Notes|left" "Kindle|right"   # stale leftovers recorded
WL=$'Claude|0|0|1000|800\nNotes|0|0|500|800\nKindle|500|0|500|800' # Claude full on top
navwl "$d" "Claude" "$WL" +1 >/dev/null
assert "12.sA is just the fullscreen app" "$(pos_in "$d" sA Claude)" "full"
assert "12.covered Notes dropped" "$(pos_in "$d" sA Notes)" ""
assert "12.covered Kindle dropped" "$(pos_in "$d" sA Kindle)" ""
rm -rf "$d"

echo "TEST 13: failsafe re-reads MEMBERS' positions but never adopts a window that isn't one"
# Only the explicit ops commit an app to a space. Kindle (snapped on screen by a click,
# never summoned here) and Floaty (a fresh loose window) must not stick; Notes, a
# member, is re-read at where it actually sits now.
d=$(newdir); seed "$d" "Old|full" "Notes|full"
WL=$'Floaty|120|120|300|200\nNotes|0|0|500|800\nKindle|500|0|500|800'
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "13.Notes re-read at left" "$(pos_in "$d" sA Notes)" "left"
assert "13.stray snapped Kindle NOT adopted" "$(pos_in "$d" sA Kindle)" ""
assert "13.stray loose window NOT adopted" "$(pos_in "$d" sA Floaty)" ""
assert "13.stale Old dropped" "$(pos_in "$d" sA Old)" ""
rm -rf "$d"

echo "TEST 13b: a stray window on top neither joins nor evicts the member it covers"
d=$(newdir); seed "$d" "Notes|full"
WL=$'Safari|0|0|1000|800\nNotes|0|0|1000|800'                       # clicked-in Safari over Notes
navwl "$d" "Safari" "$WL" +1 >/dev/null
assert "13b.Notes still the member" "$(pos_in "$d" sA Notes)" "full"
assert "13b.Safari NOT adopted" "$(pos_in "$d" sA Safari)" ""
rm -rf "$d"

echo "TEST 13c: an existing floater, loose on screen, is still recorded (floaters are sticky)"
d=$(newdir); seed "$d" "Notes|left"
printf 'sB|Floaty|120,120,300,200|98\n' >> "$d/slot_members"
WL=$'Floaty|140|130|300|200\nNotes|0|0|500|800'
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "13c.floater recorded at its live geometry" "$(pos_in "$d" sA Floaty)" "140,130,300,200"
rm -rf "$d"

echo "TEST 13d: a read that sees only strays empties the slot (its members are gone)"
d=$(newdir); seed "$d" "Notes|full"
navwl "$d" "Safari" $'Safari|0|0|1000|800' +1 >/dev/null
assert "13d.gone member dropped" "$(pos_in "$d" sA Notes)" ""
assert "13d.stray not adopted" "$(pos_in "$d" sA Safari)" ""
rm -rf "$d"

echo "TEST 14: failsafe keeps a half-pane only partially covered by a corner on top"
d=$(newdir); seed "$d" "Notes|left" "Podcasts|top-left"
WL=$'Podcasts|0|0|500|400\nNotes|0|0|500|800'                      # top-left over left
navwl "$d" "Podcasts" "$WL" +1 >/dev/null
assert "14.corner kept" "$(pos_in "$d" sA Podcasts)" "top-left"
assert "14.partially-covered half kept at left" "$(pos_in "$d" sA Notes)" "left"
rm -rf "$d"

echo "TEST 15: failsafe leaves the slot untouched on an empty window read"
d=$(newdir); seed "$d" "Claude|full"
navwl "$d" "Claude" "" +1 >/dev/null                              # empty list (set, blank)
assert "15.slot unchanged when nothing read" "$(pos_in "$d" sA Claude)" "full"
rm -rf "$d"

echo "TEST 15b: union coverage — left+right together drop a full window beneath"
d=$(newdir); seed "$d" "Buried|full" "Notes|left" "Kindle|right"
WL=$'Notes|0|0|500|800\nKindle|500|0|500|800\nBuried|0|0|1000|800' # full hidden by L+R above
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "15b.Notes kept at left" "$(pos_in "$d" sA Notes)" "left"
assert "15b.Kindle kept at right" "$(pos_in "$d" sA Kindle)" "right"
assert "15b.union-covered full dropped" "$(pos_in "$d" sA Buried)" ""
rm -rf "$d"

echo "TEST 15b2: union coverage tolerates the real 1px JankyBorders seam between left+right"
d=$(newdir); seed "$d" "Buried|full" "Notes|left" "Kindle|right"
# Real pos_rect insets left tiles 1px (width hw-1) so a border line shows between
# left and right — Notes=[0,499) Kindle=[500,1000), a genuine 1px gap at x=499.
WL=$'Notes|0|0|499|800\nKindle|500|0|500|800\nBuried|0|0|1000|800'
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "15b2.Notes kept at left" "$(pos_in "$d" sA Notes)" "left"
assert "15b2.Kindle kept at right" "$(pos_in "$d" sA Kindle)" "right"
assert "15b2.full behind the seam still dropped" "$(pos_in "$d" sA Buried)" ""
rm -rf "$d"

echo "TEST 15c: placeapp does NOT evict the leaving space's occupant the launched target covers"
# The "open Podcasts, lose Notes, get two spaces" bug: goto_app launches the target
# (Podcasts) BEFORE the engine reconciles the space we're leaving, so the fresh
# window sits full-screen on top of Notes. The leaving-space failsafe must IGNORE
# that target — otherwise it counts Podcasts as a coverer and prunes Notes out of
# its own space. Here sA holds Notes; the winlist shows Podcasts full on top of it.
d=$(newdir)
printf '1000 800\n' > "$d/screen_dims"
printf 'sA\n' > "$d/slot_seq"; printf 'sA\n' > "$d/current_slot"
printf 'sA|Notes|full|1\n' > "$d/slot_members"
printf '1\n' > "$d/slot_counter"; printf '1\n' > "$d/z_counter"
WL=$'Podcasts|0|0|1000|800\nNotes|0|0|1000|800'    # just-launched Podcasts covering Notes
SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" SLOT_APPS="Podcasts Notes Claude Kindle" \
  SLOT_WINLIST="$WL" SLOT_FRONT="Podcasts" bash "$LIB" placeapp Podcasts >/dev/null
assert "15c.Notes survives in its own space" "$(pos_in "$d" sA Notes)" "full"
assert "15c.Podcasts NOT adopted into the leaving space" "$(pos_in "$d" sA Podcasts)" ""
assert "15c.Podcasts got its own new space (s2)" "$(pos_in "$d" s2 Podcasts)" "full"
assert "15c.Notes not duplicated into Podcasts' space" "$(pos_in "$d" s2 Notes)" ""
assert "15c.two spaces now exist" "$(seq_of "$d" | wc -w | xargs)" "2"
rm -rf "$d"

echo "TEST 15d: a multi-window app records ONCE at its docked tile, not one member per window"
# The Fusion-takeover bug: a CAD app shows several layer-0 windows at once — a full
# main canvas plus narrow side palettes and a tiny helper window. Each window used to
# be adopted as its own member (and canon ones coerced to full), so the app
# metastasised a full-screen member onto every space the reconcile touched. Now an
# app is deduped to a single member, preferring its tile-matching (docked) window
# over the loose ones.
# NOTE: dedup only covers the canvas-AND-palettes-together case shown here. The
# palette-ALONE-on-a-foreign-space case (the real Fusion-vanishes bug) is covered by
# TEST 15h, via win_list_raw's subrole filter — not by this dedup.
d=$(newdir); seed "$d" "Old|full" "Fusion|left"
WL=$'Fusion|4|149|300|1237\nFusion|0|0|1000|800\nFusion|-10|-10|8|16'  # palette + main(full) + helper
navwl "$d" "Fusion" "$WL" +1 >/dev/null
assert "15d.Fusion recorded at full (its docked window)" "$(pos_in "$d" sA Fusion)" "full"
assert "15d.exactly one Fusion member" "$(awk -F'|' '$1=="sA"&&$2=="Fusion"' "$d/slot_members" | wc -l | xargs)" "1"
assert "15d.stale Old dropped" "$(pos_in "$d" sA Old)" ""
rm -rf "$d"

echo "TEST 15e: a window matching NO tile is kept at its geometry, never coerced to full"
# Removing the old canon→full coercion: an app sitting at a non-tile size comes back
# at exactly that size on swipe-back, instead of being snapped to a full tile.
# (A non-canon app: a canon one is never a floater — TEST 15e2.)
d=$(newdir); seed "$d" "Old|full" "Preview|full"
WL=$'Preview|120|90|640|480'                                          # lone non-tile window
navwl "$d" "Preview" "$WL" +1 >/dev/null
assert "15e.non-tile window kept at its geometry" "$(pos_in "$d" sA Preview)" "120,90,640,480"
rm -rf "$d"

echo "TEST 15e2: a CANON app found loose goes back on its tile and is snapped back"
# User, 2026-10-20: canon apps only ever come loose by mistake — never floaters.
d=$(newdir); seed "$d" "Old|full" "Fusion|full"
WL=$'Fusion|120|90|640|480'
navwl "$d" "Fusion" "$WL" +1 >/dev/null
assert "15e2.canon recorded at its tile, not its geometry" "$(pos_in "$d" sA Fusion)" "full"
assert "15e2.snapped back to that tile" "$(grep -c 'DRY snapback Fusion → full' "$d/log")" "1"
rm -rf "$d"

echo "TEST 15e3: a canon app RECORDED loose (old state) is rewritten onto a free tile"
# Notes was a floater in a Chrome-right space: it takes the free left, never full
# (which would evict Chrome by the coverage rule), and no copy of it stays loose.
d=$(newdir); seed "$d" "Google Chrome|right" "Notes|0,0,600,400"
printf 'Notes|0,0,600,400\n' > "$d/slot_lastpos"
WL=$'Notes|0|0|600|400\nGoogle Chrome|500|0|500|800'
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "15e3.Notes on the free left tile" "$(pos_in "$d" sA Notes)" "left"
assert "15e3.Chrome kept" "$(pos_in "$d" sA "Google Chrome")" "right"
assert "15e3.no loose canon record left" "$(awk -F'|' '$2=="Notes" && $3 ~ /,/' "$d/slot_members" "$d/slot_lastpos" | wc -l | xargs)" "0"
rm -rf "$d"

echo "TEST 15l: a window overflowing the screen reads as full, not as a loose floater"
# Fusion intermittently comes back at the frame of a display that is no longer
# attached — bigger than the screen, and centred on it, so it overhangs every edge.
# Raw, that rect matches no tile: Fusion was recorded as a floater, and a floater is
# not a jump target, so the Fusion hotkey stopped teleporting to Fusion's slot.
# Clamped to the screen it is exactly what it looks like — full.
d=$(newdir); seed "$d" "Old|full" "Fusion|left"
WL=$'Fusion|-500|-100|2000|1000'                                      # 1000x800 screen
navwl "$d" "Fusion" "$WL" +1 >/dev/null
assert "15l.overflowing window reads full" "$(pos_in "$d" sA Fusion)" "full"
rm -rf "$d"

echo "TEST 15m: an overflowing window can still be fully covered (it is only its on-screen part)"
# The other half of the same bug: nothing on screen can cover a rect BIGGER than the
# screen, so an overflowing window was never dropped by the coverage walk and
# accumulated as a member of every slot, re-raised on every restore.
d=$(newdir); seed "$d" "Old|full" "Notes|left" "Kindle|right" "Fusion|full"
WL=$'Notes|0|0|500|800\nKindle|500|0|500|800\nFusion|-500|-100|2000|1000'
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "15m.Notes kept at left" "$(pos_in "$d" sA Notes)" "left"
assert "15m.overflowing window under L+R dropped" "$(pos_in "$d" sA Fusion)" ""
rm -rf "$d"

echo "TEST 15n: a window hanging off ONE edge is recorded raw, not pulled onto the screen"
# Clamping decides what a window covers and which tile it is on; it must NOT change
# where the window is put back, or a deliberately off-edge window would creep inward
# on every reconcile.
d=$(newdir); seed "$d" "Old|full" "Kindle|full"
WL=$'Kindle|900|100|400|300'                                          # 300px off the right
navwl "$d" "Kindle" "$WL" +1 >/dev/null
assert "15n.off-edge window kept at its raw geometry" "$(pos_in "$d" sA Kindle)" "900,100,400,300"
rm -rf "$d"

echo "TEST 15o: the JankyBorders overlay is never a member and never covers anything"
# borders draws 10px OUTSIDE the window it decorates and sits above it in z, so
# unfiltered it both joined every slot as a floater and fully covered the very tile
# it was drawing around.
d=$(newdir); seed "$d" "Old|full" "Notes|full"
WL=$'borders|-10|-10|1020|820\nNotes|0|0|1000|800'
navwl "$d" "Notes" "$WL" +1 >/dev/null
assert "15o.borders not a member" "$(pos_in "$d" sA borders)" ""
assert "15o.the window it decorates survives" "$(pos_in "$d" sA Notes)" "full"
rm -rf "$d"

echo "TEST 15h: a Fusion palette that floats across spaces is NOT adopted as a member"
# THE Fusion-vanishes bug. Fusion's main canvas lives on another space; only its
# sticky AXDialog palette is on-screen here (palettes carry canJoinAllSpaces, so
# CGWindowList reports them on every space). win_list shows the palette with owner
# "Fusion" — indistinguishable by name from the real canvas. The failsafe must NOT
# record Fusion into this space from a palette-only sighting, or Fusion's real space
# loses it to the one-app-one-position prune and reads as empty. yabai's subrole
# tells us the palette's geometry; here it's supplied via SLOT_CAD_AUX.
d=$(newdir); seed "$d" "Notes|left"
WL=$'Fusion|3203|70|3440|25\nNotes|0|0|500|800'                       # palette floats over Notes
SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
  SLOT_WINLIST="$WL" SLOT_CAD_AUX=$'3203|70|3440|25' SLOT_FRONT="Notes" bash "$LIB" nav +1 >/dev/null
assert "15h.Notes kept at left" "$(pos_in "$d" sA Notes)" "left"
assert "15h.palette NOT adopted as a Fusion member" "$(pos_in "$d" sA Fusion)" ""
rm -rf "$d"

echo "TEST 15i: with the palette flagged, Fusion's real canvas is still adopted"
# Regression guard for 15h: when the canvas IS on this space, stripping the palette
# must still leave the real document window to be recorded — exactly once, at full.
d=$(newdir); seed "$d" "Old|full" "Fusion|left"
WL=$'Fusion|3203|70|3440|25\nFusion|0|0|1000|800'                     # palette + real main(full)
SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
  SLOT_WINLIST="$WL" SLOT_CAD_AUX=$'3203|70|3440|25' SLOT_FRONT="Fusion" bash "$LIB" nav +1 >/dev/null
assert "15i.Fusion canvas adopted at full" "$(pos_in "$d" sA Fusion)" "full"
assert "15i.exactly one Fusion member" "$(awk -F'|' '$1=="sA"&&$2=="Fusion"' "$d/slot_members" | wc -l | xargs)" "1"
rm -rf "$d"

echo "TEST 15j: a Fusion palette is stripped from CGWindowList even when yabai never saw it"
# The reopened Fusion-vanishes bug: Fusion's borderless canvas reports AXDialog (same
# as a palette), and the Sketch Palette is an NSPanel yabai never AX-observes — so it
# is ABSENT from `yabai -m query --windows` and NO SLOT_CAD_AUX can be supplied from
# it. cad_aux_geoms must instead derive the palette geometry from the CGWindowList it
# is about to filter (here mocked via SLOT_WINLIST, with SLOT_CAD_AUX deliberately
# UNSET). Canvas lives elsewhere; only the 250x538 palette floats over Notes here.
d=$(newdir); seed "$d" "Notes|left"
WL=$'Fusion|3186|4|250|538\nNotes|0|0|500|800'                        # palette floats over Notes
SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
  SLOT_WINLIST="$WL" SLOT_FRONT="Notes" bash "$LIB" nav +1 >/dev/null
assert "15j.Notes kept at left" "$(pos_in "$d" sA Notes)" "left"
assert "15j.unobserved palette NOT adopted as a Fusion member" "$(pos_in "$d" sA Fusion)" ""
rm -rf "$d"

echo "TEST 15k: with palette auto-stripped, Fusion's real canvas is still adopted"
# Regression guard for 15j: when the big canvas IS on this space, auto-stripping the
# palette (no SLOT_CAD_AUX) must still leave the real document window, recorded once.
d=$(newdir); seed "$d" "Old|full" "Fusion|left"
WL=$'Fusion|3186|4|250|538\nFusion|0|0|1000|800'                      # palette + real main(full)
SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" \
  SLOT_WINLIST="$WL" SLOT_FRONT="Fusion" bash "$LIB" nav +1 >/dev/null
assert "15k.Fusion canvas adopted at full" "$(pos_in "$d" sA Fusion)" "full"
assert "15k.exactly one Fusion member" "$(awk -F'|' '$1=="sA"&&$2=="Fusion"' "$d/slot_members" | wc -l | xargs)" "1"
rm -rf "$d"

echo "TEST 15f: navapp on an app snapped in the CURRENT space focuses it in place, no jump"
# Running the go-to-app hotkey on an app that's already assigned to the current space
# must just bring it to the front here — not teleport to another space that also holds
# it. (Fusion is snapped in both sA (current) and sB; the hotkey must stay on sA.)
d=$(newdir)
printf '1000 800\n' > "$d/screen_dims"
printf 'sA\nsB\n' > "$d/slot_seq"; printf 'sA\n' > "$d/current_slot"
printf 'sA|Fusion|full|1\nsB|Fusion|full|2\n' > "$d/slot_members"
printf '2\n' > "$d/slot_counter"; printf '2\n' > "$d/z_counter"
out=$(SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" SLOT_FRONT="Notes" bash "$LIB" navapp Fusion | tail -1)
assert "15f.stayed in the current space sA" "$(cat "$d/current_slot")" "sA"
assert "15f.focused Fusion" "${out##*|}" "Fusion"
rm -rf "$d"

echo "TEST 15g: navapp still jumps when the app is snapped ONLY in another space"
# Counterpart: Fusion is not in current sA, only in sB → the hotkey jumps to sB.
d=$(newdir)
printf '1000 800\n' > "$d/screen_dims"
printf 'sA\nsB\n' > "$d/slot_seq"; printf 'sA\n' > "$d/current_slot"
printf 'sA|Notes|full|1\nsB|Fusion|full|2\n' > "$d/slot_members"
printf '2\n' > "$d/slot_counter"; printf '2\n' > "$d/z_counter"
out=$(SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" SLOT_FRONT="Notes" bash "$LIB" navapp Fusion | tail -1)
assert "15g.jumped to sB" "$(cat "$d/current_slot")" "sB"
assert "15g.focused Fusion" "${out##*|}" "Fusion"
rm -rf "$d"

# ── placeapp: splice an unassigned app's new full space next to its neighbour ──
# Canonical sequence for these tests: Podcasts Notes Claude Kindle (so Claude's
# predecessor=Notes, successor=Kindle). State is seeded directly — one full slot
# per app name in order — so each placement branch is exercised in isolation.
place_seed() {                 # d  name...   (one full slot each, current=s1)
  local d="$1"; shift
  printf '1000 800\n' > "$d/screen_dims"
  : > "$d/slot_seq"; : > "$d/slot_members"; : > "$d/app_lastpos"
  local i=0 name
  for name in "$@"; do
    i=$((i+1)); echo "s$i" >> "$d/slot_seq"; echo "s$i|$name|full|$i" >> "$d/slot_members"
  done
  echo "s1" > "$d/current_slot"; echo "$i" > "$d/slot_counter"; echo "$i" > "$d/z_counter"
}
runp() {                       # d  app-to-place  [layouts]
  SLOT_STATE_DIR="$1" SLOT_DRYRUN=1 SLOT_LOG="$1/log" \
    SLOT_APPS="Podcasts Notes Claude Kindle" SLOT_LAYOUTS="${3-}" \
    SLOT_FRONT="x" bash "$LIB" placeapp "$2"
}
# Sequence as app names (each seeded/placed slot holds exactly one member).
seq_names() {
  local d="$1" s; for s in $(seq_of "$d"); do
    awk -F'|' -v s="$s" '$1==s{print $2; exit}' "$d/slot_members"
  done | paste -sd' ' -
}

echo "TEST 16: placeapp splices BETWEEN predecessor & successor when they're adjacent"
d=$(newdir); place_seed "$d" Podcasts Notes Kindle
runp "$d" Claude >/dev/null
assert "16.new space is Claude:full" "$(cur_members "$d")" "Claude:full"
assert "16.spliced between Notes and Kindle" "$(seq_names "$d")" "Podcasts Notes Claude Kindle"
rm -rf "$d"

echo "TEST 17: placeapp anchors AFTER an exclusive predecessor (successor absent)"
d=$(newdir); place_seed "$d" Podcasts Notes
runp "$d" Claude >/dev/null
assert "17.placed right after Notes" "$(seq_names "$d")" "Podcasts Notes Claude"
rm -rf "$d"

echo "TEST 17b: placeapp anchors BEFORE an exclusive successor (predecessor absent)"
d=$(newdir); place_seed "$d" Kindle Podcasts
runp "$d" Claude >/dev/null
assert "17b.placed just before Kindle (at head)" "$(seq_names "$d")" "Claude Kindle Podcasts"
rm -rf "$d"

echo "TEST 18: placeapp searches outward when neither neighbour is present"
d=$(newdir); place_seed "$d" Podcasts            # only Podcasts (2 steps before Claude)
runp "$d" Claude >/dev/null
assert "18.anchored beside the nearest canonical app" "$(seq_names "$d")" "Podcasts Claude"
rm -rf "$d"

echo "TEST 19: placeapp puts X in the LARGER gap when a neighbour spans non-adjacent spaces"
d=$(newdir); place_seed "$d" Notes Podcasts Notes  # Notes at idx0 & idx2 (gap=Podcasts)
runp "$d" Claude >/dev/null
# larger forward gap is 0→2 (past Podcasts); X abuts the first Notes, outside the
# smaller wrap-around gap.
assert "19.placed in the larger gap, beside first Notes" "$(seq_names "$d")" "Notes Claude Podcasts Notes"
rm -rf "$d"

echo "TEST 20: placeapp sits OUTSIDE a consecutive block of the neighbour"
d=$(newdir); place_seed "$d" Notes Notes Podcasts  # Notes block at idx0-1
runp "$d" Claude >/dev/null
assert "20.placed just outside the Notes block" "$(seq_names "$d")" "Notes Notes Claude Podcasts"
rm -rf "$d"

# ── placeapp custom-default layouts (paired spaces) ───────────────────────────
# A primary opens with a companion alongside, but only when the companion "fits"
# (in no slot, or already snapped at the wanted tile). SLOT_LAYOUTS overrides the
# production config so these tests are self-contained.
LAY=$'Safari|Safari:right;Claude:left\nGoogle Chrome|Google Chrome:right;Claude:left'
# Members of whatever slot is current, "app:pos" by z-order (focus = last).
cur_pairs() {
  local d="$1" cur; cur=$(current_of "$d")
  awk -F'|' -v s="$cur" '$1==s{print $2":"$3"|"$4}' "$d/slot_members" \
    | sort -t'|' -k2,2n | cut -d'|' -f1 | paste -sd' ' -
}

echo "TEST 20a: placeapp Safari pairs Claude:left when Claude is in NO slot"
d=$(newdir); place_seed "$d" Podcasts Notes
runp "$d" Safari "$LAY" >/dev/null
assert "20a.Claude:left then Safari:right (Safari focus last)" "$(cur_pairs "$d")" "Claude:left Safari:right"
rm -rf "$d"

echo "TEST 20b: placeapp Safari pairs when Claude already snapped LEFT elsewhere"
d=$(newdir); place_seed "$d" Podcasts Notes
echo "s1|Claude|left|9" >> "$d/slot_members"   # Claude lives left in Podcasts' space
runp "$d" Safari "$LAY" >/dev/null
assert "20b.paired (Claude fits — already left)" "$(cur_pairs "$d")" "Claude:left Safari:right"
rm -rf "$d"

echo "TEST 20c: placeapp Safari does NOT pair when Claude fills its own space (full)"
d=$(newdir); place_seed "$d" Podcasts Notes Claude   # Claude:full in s3
runp "$d" Safari "$LAY" >/dev/null
assert "20c.Safari solo full (Claude doesn't fit)" "$(cur_pairs "$d")" "Safari:full"
rm -rf "$d"

echo "TEST 20d: reverse — placeapp Claude brings in the first fitting primary (Safari)"
d=$(newdir); place_seed "$d" Podcasts Notes
runp "$d" Claude "$LAY" >/dev/null
assert "20d.Safari:right then Claude:left (Claude focus last)" "$(cur_pairs "$d")" "Safari:right Claude:left"
rm -rf "$d"

echo "TEST 20e: reverse — skip a primary that doesn't fit, fall through to next (Chrome)"
d=$(newdir); place_seed "$d" Podcasts Notes Safari   # Safari:full ⇒ doesn't fit
runp "$d" Claude "$LAY" >/dev/null
assert "20e.Chrome brought in instead" "$(cur_pairs "$d")" "Google Chrome:right Claude:left"
rm -rf "$d"

echo "TEST 20f: reverse — no primary fits ⇒ Claude opens solo full"
d=$(newdir); place_seed "$d" Podcasts Safari "Google Chrome"   # both full
runp "$d" Claude "$LAY" >/dev/null
assert "20f.Claude solo full" "$(cur_pairs "$d")" "Claude:full"
rm -rf "$d"

echo "TEST 20g: a companion pulled in stays a member of its existing same-tile space"
d=$(newdir); place_seed "$d" Podcasts Notes
echo "s1|Claude|left|9" >> "$d/slot_members"   # Claude already left in s1
runp "$d" Safari "$LAY" >/dev/null
assert "20g.Claude now in 2 slots" "$(slots_with "$d" Claude | tr ',' ' ' | wc -w | xargs)" "2"
rm -rf "$d"

# Several apps at one tile = alternatives: the one most recently switched to wins.
LAY2=$'Claude|Claude:left;Safari:right;Google Chrome:right'
echo "TEST 20h: same-tile alternatives — no history ⇒ config order (Safari)"
d=$(newdir); place_seed "$d" Podcasts Notes
runp "$d" Claude "$LAY2" >/dev/null
assert "20h.Safari:right, Chrome left out" "$(cur_pairs "$d")" "Safari:right Claude:left"
rm -rf "$d"

echo "TEST 20i: same-tile alternatives — Chrome switched to more recently ⇒ Chrome"
d=$(newdir); place_seed "$d" Podcasts Notes
printf 'Notes\nGoogle Chrome\nPodcasts\nSafari\n' > "$d/app_mru"
runp "$d" Claude "$LAY2" >/dev/null
assert "20i.Chrome:right" "$(cur_pairs "$d")" "Google Chrome:right Claude:left"
assert "20i.placeapp records Claude as most recent" "$(head -1 "$d/app_mru")" "Claude"
rm -rf "$d"

echo "TEST 20j: same-tile alternatives — a contender that doesn't fit is skipped"
d=$(newdir); place_seed "$d" Podcasts Notes "Google Chrome"   # Chrome:full ⇒ doesn't fit
printf 'Google Chrome\nSafari\n' > "$d/app_mru"
runp "$d" Claude "$LAY2" >/dev/null
assert "20j.falls to Safari" "$(cur_pairs "$d")" "Safari:right Claude:left"
rm -rf "$d"

echo "TEST 20k: same-tile alternatives — running beats more recent-but-quit"
d=$(newdir); place_seed "$d" Podcasts Notes
printf 'Google Chrome\nSafari\n' > "$d/app_mru"
SLOT_RUNNING=$'Safari\nNotes' runp "$d" Claude "$LAY2" >/dev/null
assert "20k.Safari (Chrome not running)" "$(cur_pairs "$d")" "Safari:right Claude:left"
rm -rf "$d"

echo "TEST 20l: nav records the app it lands on"
d=$(newdir); run "$d" "Podcasts" init >/dev/null
run "$d" "x" nav +1 >/dev/null
assert "20l.Notes on top of MRU" "$(head -1 "$d/app_mru")" "Notes"
rm -rf "$d"

echo "TEST 21: winclose on a FULL-SCREEN app destroys the group, lands where we came FROM (left)"
d=$(newdir); run "$d" "Podcasts" init >/dev/null  # P N C K, current=Podcasts
PB=$(slots_with "$d" Podcasts)
run "$d" "x" nav +1 >/dev/null                    # current=Notes, came from Podcasts (left)
NB=$(current_of "$d")
run "$d" "Notes" winclose >/dev/null              # Notes fills its space → destroy + go back
assert "21.Notes group destroyed (gone from seq)" "$(seq_of "$d" | tr ' ' '\n' | grep -c "^$NB$" | xargs)" "0"
assert "21.landed on Podcasts (where we came from)" "$(current_of "$d")" "$PB"
assert "21.Notes left unassigned (not closed)" "$(slots_with "$d" Notes)" ""
rm -rf "$d"

echo "TEST 22: full-screen winclose lands on the RIGHT when that's where we came from"
d=$(newdir); run "$d" "Podcasts" init >/dev/null  # P N C K
run "$d" "x" nav +1 >/dev/null                    # Notes
run "$d" "x" nav +1 >/dev/null                    # Claude
CB=$(current_of "$d")
run "$d" "x" nav -1 >/dev/null                    # back to Notes, came from Claude (right)
NB=$(current_of "$d")
run "$d" "Notes" winclose >/dev/null              # destroy Notes → land back on Claude (right)
assert "22.Notes group gone" "$(seq_of "$d" | tr ' ' '\n' | grep -c "^$NB$" | xargs)" "0"
assert "22.landed on Claude (the right neighbour we came from)" "$(current_of "$d")" "$CB"
rm -rf "$d"

echo "TEST 23: full-screen winclose on the SOLE space peels instead of destroying to nothing"
d=$(newdir); run "$d" "Podcasts" init >/dev/null
run "$d" "x" nav +1 >/dev/null; run "$d" "x" destroy >/dev/null  # drop Notes
run "$d" "x" nav +1 >/dev/null; run "$d" "x" destroy >/dev/null  # drop the next
run "$d" "x" nav +1 >/dev/null; run "$d" "x" destroy >/dev/null  # down to one slot
SOLE=$(current_of "$d")
NS=$(seq_of "$d" | wc -w | xargs)
assert "23.precondition: one slot left" "$NS" "1"
APP=$(awk -F'|' -v s="$SOLE" '$1==s{print $2; exit}' "$d/slot_members")
run "$d" "$APP" winclose >/dev/null               # full-screen but sole → must NOT destroy
assert "23.sole space survives (not destroyed to nothing)" "$(seq_of "$d" | wc -w | xargs)" "1"
assert "23.current still on it" "$(current_of "$d")" "$SOLE"
assert "23.app peeled out (unassigned, kept open)" "$(slots_with "$d" "$APP")" ""
rm -rf "$d"

echo "TEST 24: non-full-screen winclose still just peels the app (unchanged)"
d=$(newdir); run "$d" "Claude" init >/dev/null
run "$d" "Claude" snap left >/dev/null            # Claude:left (NOT full) in current
CUR=$(current_of "$d")
NB=$(seq_of "$d" | wc -w | xargs)
run "$d" "Claude" winclose >/dev/null             # half-screen → peel, space survives
assert "24.space survives" "$(seq_of "$d" | wc -w | xargs)" "$NB"
assert "24.still current" "$(current_of "$d")" "$CUR"
assert "24.Claude peeled out" "$(slots_with "$d" Claude)" ""
rm -rf "$d"

# Seed a sequence directly (distinct slot ids, chosen members) for collapse tests.
dup_seed() { local d="$1"; shift
  printf '1000 800\n' > "$d/screen_dims"; : > "$d/slot_seq"; : > "$d/slot_members"
  local i=0 spec name pos
  for spec in "$@"; do                            # spec = app[:pos]  (pos defaults full)
    i=$((i+1)); name="${spec%%:*}"; pos="${spec#*:}"; [[ "$pos" == "$spec" ]] && pos=full
    echo "s$i" >> "$d/slot_seq"; echo "s$i|$name|$pos|$i" >> "$d/slot_members"
  done
  echo s1 > "$d/current_slot"; echo "$i" > "$d/slot_counter"; echo "$i" > "$d/z_counter"
}

echo "TEST 25: leaving a fullnew duplicate keeps both spaces; nav just moves on"
d=$(newdir); run "$d" "Notes" init >/dev/null     # P N C K, current=Notes (s2)
run "$d" "x" fullnew >/dev/null                   # seq: P N Ndup C K, current=Ndup (newer)
run "$d" "x" nav +1 >/dev/null                    # plain swipe to the next slot
assert "25.landed on Claude (the neighbour)" "$(cur_members "$d")" "Claude:full"
assert "25.both Notes spaces remain" "$(slots_with "$d" Notes | tr ',' '\n' | grep -c . | xargs)" "2"
assert "25.still five spaces (duplicate kept)" "$(seq_of "$d" | wc -w | xargs)" "5"
rm -rf "$d"

echo "TEST 26: an identical space elsewhere is left alone; nav moves normally"
d=$(newdir); dup_seed "$d" Claude Kindle Claude Notes  # s1 & s3 identical; current=s1
run "$d" "x" nav +1 >/dev/null                    # plain swipe to the neighbour
assert "26.nothing deleted" "$(seq_of "$d" | xargs)" "s1 s2 s3 s4"
assert "26.landed on the neighbour s2" "$(current_of "$d")" "s2"
rm -rf "$d"

echo "TEST 27: a near-identical space (different position) moves normally too"
d=$(newdir); dup_seed "$d" Claude:left Claude:right Kindle  # same app, different pos
run "$d" "x" nav +1 >/dev/null
assert "27.moved normally, nothing deleted" "$(seq_of "$d" | xargs)" "s1 s2 s3"
assert "27.landed on the half-screen neighbour" "$(current_of "$d")" "s2"
rm -rf "$d"

echo "TEST 28: with one duplicate elsewhere, nav moves to it without deleting"
d=$(newdir); dup_seed "$d" Claude Claude            # s1 current, s2 identical
run "$d" "x" nav +1 >/dev/null
assert "28.both spaces survive" "$(seq_of "$d" | xargs)" "s1 s2"
assert "28.landed on the neighbour" "$(current_of "$d")" "s2"
rm -rf "$d"

# ── appterm: react to an app quitting by any means (Dock, ⌘Q, crash) ──────────
# Seed arbitrary multi-member slots: each arg is "slot|app|pos". current defaults
# to the first slot; override with cur=… / prev=… leading args.
term_seed() { local d="$1"; shift
  printf '1000 800\n' > "$d/screen_dims"; : > "$d/slot_seq"; : > "$d/slot_members"
  local cur="" prev="" z=0 spec slot seen=""
  while [[ "$1" == cur=* || "$1" == prev=* ]]; do
    [[ "$1" == cur=*  ]] && cur="${1#cur=}";  [[ "$1" == prev=* ]] && prev="${1#prev=}"; shift
  done
  for spec in "$@"; do
    slot="${spec%%|*}"; z=$((z+1)); echo "$spec|$z" >> "$d/slot_members"
    case " $seen " in *" $slot "*) ;; *) echo "$slot" >> "$d/slot_seq"; seen="$seen $slot" ;; esac
  done
  echo "${cur:-$(head -1 "$d/slot_seq")}" > "$d/current_slot"
  echo "$prev" > "$d/prev_slot"; echo 100 > "$d/slot_counter"; echo "$z" > "$d/z_counter"
}
# runterm <statedir> <running-newline-list> — drive `appterm` with an injected
# running-apps list (SLOT_RUNNING) instead of live AX.
runterm() { local d="$1" running="$2"
  SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" SLOT_RUNNING="$running" \
    bash "$LIB" appterm; }

echo "TEST 29: quitting a sole full-screen app destroys its space, lands on neighbour"
d=$(newdir); term_seed "$d" cur=s1 prev=s2 "s1|Notes|full" "s2|Claude|full"
runterm "$d" $'Claude\nFinder' >/dev/null
assert "29.s1 gone, only s2 left" "$(seq_of "$d" | xargs)" "s2"
assert "29.landed on s2" "$(current_of "$d")" "s2"
rm -rf "$d"

echo "TEST 30: a floater on top does NOT save the space — full quit still destroys it"
d=$(newdir); term_seed "$d" cur=s1 prev=s2 "s1|Notes|full" "s1|Calc|100,100,300,400" "s2|Claude|full"
runterm "$d" $'Claude\nCalc\nFinder' >/dev/null
assert "30.s1 destroyed despite floater" "$(seq_of "$d" | xargs)" "s2"
rm -rf "$d"

echo "TEST 31: quitting a side-tiled sole app KEEPS the space (only full triggers destroy)"
d=$(newdir); term_seed "$d" cur=s1 prev=s2 "s1|Notes|left" "s2|Claude|full"
runterm "$d" $'Claude\nFinder' >/dev/null
assert "31.both spaces remain" "$(seq_of "$d" | xargs)" "s1 s2"
assert "31.dead Notes pruned from s1" "$(slots_with "$d" Notes)" ""
rm -rf "$d"

echo "TEST 32: with another snapped app still present, the space is kept (full quit)"
d=$(newdir); term_seed "$d" cur=s1 "s1|Notes|left" "s1|Podcasts|right" "s2|Claude|full"
runterm "$d" $'Podcasts\nClaude' >/dev/null
assert "32.space kept" "$(seq_of "$d" | xargs)" "s1 s2"
assert "32.Podcasts survives in s1" "$(pos_in "$d" s1 Podcasts)" "right"
rm -rf "$d"

echo "TEST 33: an app full in one space + tiled in another → only the full space dies"
d=$(newdir); term_seed "$d" cur=s3 "s1|Notes|full" "s2|Notes|left" "s2|Claude|right" "s3|Podcasts|full"
runterm "$d" $'Claude\nPodcasts' >/dev/null
assert "33.s1 (full Notes) destroyed, s2/s3 remain" "$(seq_of "$d" | xargs)" "s2 s3"
assert "33.Notes pruned everywhere" "$(slots_with "$d" Notes)" ""
assert "33.current untouched (s3)" "$(current_of "$d")" "s3"
rm -rf "$d"

echo "TEST 34: a BACKGROUND space dying leaves current put (no restore/move)"
d=$(newdir); term_seed "$d" cur=s2 prev=s1 "s1|Notes|full" "s2|Claude|full"
runterm "$d" $'Claude\nFinder' >/dev/null
assert "34.s1 destroyed" "$(seq_of "$d" | xargs)" "s2"
assert "34.current stays s2" "$(current_of "$d")" "s2"
rm -rf "$d"

echo "TEST 35: nothing quit ⇒ no-op; an empty running list is ignored (no nuke)"
d=$(newdir); term_seed "$d" cur=s1 "s1|Notes|full" "s2|Claude|full"
runterm "$d" $'Notes\nClaude\nFinder' >/dev/null
assert "35.all still here when nothing quit" "$(seq_of "$d" | xargs)" "s1 s2"
runterm "$d" "" >/dev/null      # AX hiccup: empty list must change nothing
assert "35.empty running list is a no-op" "$(seq_of "$d" | xargs)" "s1 s2"
rm -rf "$d"

# navapp to an app whose layout has same-tile alternatives (existing spaces).
LAY2=$'Claude|Claude:left;Safari:right;Google Chrome:right'
runnav() { SLOT_STATE_DIR="$1" SLOT_DRYRUN=1 SLOT_LOG="$1/log" SLOT_APPS="Podcasts Notes Claude Kindle" \
  SLOT_LAYOUTS="$LAY2" SLOT_FRONT="x" bash "$LIB" navapp "$2"; }
alt_seed() {                   # d  → s1 Podcasts, s2 Claude+Safari, [s3 Claude+Chrome if $2]
  local d="$1"; printf '1000 800\n' > "$d/screen_dims"
  printf 's1\ns2\n' > "$d/slot_seq"
  printf 's1|Podcasts|full|1\ns2|Claude|left|2\ns2|Safari|right|3\n' > "$d/slot_members"
  [[ -n "${2-}" ]] && { echo s3 >> "$d/slot_seq"; printf 's3|Google Chrome|right|4\ns3|Claude|left|5\n' >> "$d/slot_members"; }
  echo s1 > "$d/current_slot"; echo 3 > "$d/slot_counter"; echo 5 > "$d/z_counter"
}

echo "TEST 36: navapp prefers the space already holding the most recent alternative"
d=$(newdir); alt_seed "$d" 1; printf 'Google Chrome\nSafari\n' > "$d/app_mru"
runnav "$d" Claude >/dev/null
assert "36.jumped to s3 (Chrome), not the nearer s2" "$(current_of "$d")" "s3"
assert "36.s2 untouched" "$(pos_in "$d" s2 Safari)" "right"
rm -rf "$d"

echo "TEST 37: navapp swaps the most recent alternative into the only matching space"
d=$(newdir); alt_seed "$d"; printf 'Google Chrome\nSafari\n' > "$d/app_mru"
runnav "$d" Claude >/dev/null
assert "37.landed on s2" "$(current_of "$d")" "s2"
assert "37.Chrome now right" "$(cur_pairs "$d")" "Google Chrome:right Claude:left"
assert "37.Safari out of s2" "$(pos_in "$d" s2 Safari)" ""
rm -rf "$d"

echo "TEST 38: navapp leaves the space alone when its alternative is already the latest"
d=$(newdir); alt_seed "$d"; printf 'Safari\nGoogle Chrome\n' > "$d/app_mru"
runnav "$d" Claude >/dev/null
assert "38.Safari stays" "$(cur_pairs "$d")" "Safari:right Claude:left"
rm -rf "$d"

echo "TEST 39: navapp doesn't swap in a recent alternative that isn't running"
d=$(newdir); alt_seed "$d"; printf 'Google Chrome\nSafari\n' > "$d/app_mru"
SLOT_RUNNING=$'Safari\nClaude\nPodcasts' runnav "$d" Claude >/dev/null
assert "39.Safari stays" "$(cur_pairs "$d")" "Safari:right Claude:left"
rm -rf "$d"

cur_pairs_of() {
  awk -F'|' -v s="$2" '$1==s{print $2":"$3"|"$4}' "$1/slot_members" \
    | sort -t'|' -k2,2n | cut -d'|' -f1 | paste -sd' ' -
}
LAY3=$'Safari|Safari:right;Claude:left\nGoogle Chrome|Google Chrome:right;Claude:left'
runnav3() { SLOT_STATE_DIR="$1" SLOT_DRYRUN=1 SLOT_LOG="$1/log" SLOT_APPS="Podcasts Notes Claude Kindle" \
  SLOT_LAYOUTS="$LAY3" SLOT_FRONT="x" bash "$LIB" navapp "$2"; }

echo "TEST 40: navapp re-pairs a layout space whose companion was pruned (Claude quit)"
d=$(newdir); alt_seed "$d"
printf 's1|Podcasts|full|1\ns2|Safari|right|3\n' > "$d/slot_members"   # Claude gone
runnav3 "$d" Safari >/dev/null
assert "40.Claude back on the left" "$(cur_pairs "$d")" "Claude:left Safari:right"
rm -rf "$d"

echo "TEST 41: no re-pair when the companion lives elsewhere at another tile"
d=$(newdir); alt_seed "$d"
printf 's1|Claude|full|1\ns2|Safari|right|3\n' > "$d/slot_members"
runnav3 "$d" Safari >/dev/null
assert "41.Safari alone" "$(cur_pairs "$d")" "Safari:right"
rm -rf "$d"

echo "TEST 42: no re-pair when another member already covers the companion tile"
d=$(newdir); alt_seed "$d"
printf 's1|Podcasts|full|1\ns2|Notes|top-left|2\ns2|Safari|right|3\n' > "$d/slot_members"
runnav3 "$d" Safari >/dev/null
assert "42.Notes kept, no Claude" "$(cur_pairs "$d")" "Notes:top-left Safari:right"
rm -rf "$d"

runclick() { SLOT_STATE_DIR="$1" SLOT_DRYRUN=1 SLOT_LOG="$1/log" SLOT_APPS="Podcasts Notes Claude Kindle" \
  SLOT_LAYOUTS="$LAY2" SLOT_FRONT="x" bash "$LIB" clicked "$2" 7 "$3"; }

echo "TEST 43: clicking a full-screen window with a full space switches to that space"
d=$(newdir); alt_seed "$d"; echo s2 > "$d/current_slot"
out=$(runclick "$d" Podcasts "0 0 1000 800")
assert "43.now on s1" "$(current_of "$d")" "s1"
assert "43.reports the switch" "$out" "Safari|Podcasts"
assert "43.s2 untouched" "$(cur_pairs_of "$d" s2)" "Claude:left Safari:right"
rm -rf "$d"

echo "TEST 44: clicking a non-full window only lifts it — no switch, not committed"
d=$(newdir); alt_seed "$d"; echo s2 > "$d/current_slot"
out=$(runclick "$d" Podcasts "0 0 499 800")
assert "44.still on s2" "$(current_of "$d")" "s2"
assert "44.no handoff" "$out" "|"
assert "44.Podcasts not added to s2" "$(pos_in "$d" s2 Podcasts)" ""
rm -rf "$d"

echo "TEST 45: concurrent ops are serialised (no lost members)"
d=$(newdir); alt_seed "$d"
for i in 1 2 3 4 5 6; do
  SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" SLOT_APPS="Podcasts Notes Claude Kindle" \
    SLOT_LAYOUTS="$LAY2" SLOT_FRONT="Notes" bash "$LIB" snap "top-left" >/dev/null &
  SLOT_STATE_DIR="$d" SLOT_DRYRUN=1 SLOT_LOG="$d/log" SLOT_APPS="Podcasts Notes Claude Kindle" \
    SLOT_LAYOUTS="$LAY2" SLOT_FRONT="Kindle" bash "$LIB" snap "bottom-left" >/dev/null &
done; wait
assert "45.both snaps survived" "$(cur_pairs "$d" | tr ' ' '\n' | sort | paste -sd' ' -)" "Kindle:bottom-left Notes:top-left"
assert "45.Claude/Safari untouched" "$(cur_pairs_of "$d" s2)" "Claude:left Safari:right"
assert "45.lock released" "$([[ -e "$d/.slot_lock" ]] && echo held || echo free)" "free"
rm -rf "$d"

echo "TEST 46: snapping a FLOATER to full gives it its own space; the app hotkey leaves it"
d=$(newdir); alt_seed "$d"; echo s2 > "$d/current_slot"
echo 's2|Remap|100,100,600,400|6' >> "$d/slot_members"; echo 6 > "$d/z_counter"
run "$d" "Remap" snap full >/dev/null
NS=$(current_of "$d")
assert "46.landed on a new slot" "$([[ "$NS" != s1 && "$NS" != s2 ]] && echo new)" "new"
assert "46.new slot is Remap alone at full" "$(cur_pairs "$d")" "Remap:full"
assert "46.new slot sits right after s2" "$(seq_of "$d")" "s1 s2 $NS"
assert "46.Claude pair kept" "$(cur_pairs_of "$d" s2)" "Claude:left Safari:right"
runnav "$d" Claude >/dev/null
assert "46.Claude hotkey → back to the pair" "$(current_of "$d")" "s2"
assert "46.Remap keeps its space" "$(cur_pairs_of "$d" "$NS")" "Remap:full"
run "$d" "x" activate Remap >/dev/null
assert "46.summoning Remap jumps to its space" "$(current_of "$d")" "$NS"
assert "46.…without touching the pair" "$(cur_pairs_of "$d" s2 | tr " " "\n" | sort | paste -sd" " -)" "Claude:left Safari:right"
run "$d" "x" back >/dev/null
assert "46.back returns to the pair" "$(current_of "$d")" "s2"
rm -rf "$d"

echo "TEST 47: a floater snapped full on a space with no snapped app just fills it"
d=$(newdir); alt_seed "$d"; printf 's1\ns2\ns3\n' > "$d/slot_seq"; echo s3 > "$d/current_slot"
echo 's3|Remap|100,100,600,400|6' >> "$d/slot_members"; echo 6 > "$d/z_counter"
run "$d" "Remap" snap full >/dev/null
assert "47.stays on s3" "$(current_of "$d")" "s3"
assert "47.s3 is Remap at full" "$(cur_pairs "$d")" "Remap:full"
assert "47.no new slot" "$(seq_of "$d")" "s1 s2 s3"
rm -rf "$d"

echo "TEST 48: UI Zoom — a window on another zoom level's tile is still that tile"
# The glide re-fits only on-screen windows; another desktop's keep the zoom they were
# last shown at (Remap recorded loose at 0,0,1563,654 = full at 220% on a 100% screen).
d=$(newdir); seed "$d" "Notes|full"; echo 1.00 > "$d/.screen_zoom"
navwl "$d" Notes $'Notes|0|0|454|363' +1 >/dev/null          # full at 220% of 1000x800
assert "48a.full at 220% read as full" "$(pos_in "$d" sA Notes)" "full"
assert "48a.and is not snapped back" "$(grep -c 'DRY snapback Notes' "$d/log")" "0"
rm -rf "$d"
d=$(newdir); seed "$d" "Notes|full"                            # no screen zoom: no levels
navwl "$d" Notes $'Notes|0|0|454|363' +1 >/dev/null
# Notes is canon, so never a floater: read loose, it is snapped back to its tile.
assert "48b.without UI Zoom it reads loose (snapped back)" "$(grep -c 'DRY snapback Notes' "$d/log")" "1"
rm -rf "$d"
d=$(newdir); seed "$d" "Notes|right"; printf '800 640\n' > "$d/screen_dims"; echo 1.25 > "$d/.screen_zoom"
navwl "$d" Notes $'Notes|500|0|500|800' +1 >/dev/null          # right at 100%, screen now 125%
assert "48c.bigger than the zoomed screen: matched unclamped" "$(pos_in "$d" sA Notes)" "right"
rm -rf "$d"
d=$(newdir); seed "$d" "Notes|full"; echo 1.00 > "$d/.screen_zoom"
navwl "$d" Notes $'Notes|300|200|400|300' +1 >/dev/null
assert "48d.a really loose window still reads loose (snapped back)" "$(grep -c 'DRY snapback Notes' "$d/log")" "1"
rm -rf "$d"

echo "TEST 49: UI Zoom — realize picks the app's real window, whatever zoom it was sized at"
# 2026-10-20: at 110% Chrome's 100%-sized window fit no tile, so its 1396x89 bar on the
# target desktop won and was framed; the real window stayed stranded on a free desktop.
d=$(newdir)
printf 'g1\n' > "$d/slot_seq"; printf 'g1|Claude|left|1\ng1|Google Chrome|right|2\n' > "$d/slot_members"
printf 'g1|UA\n' > "$d/slot_spaces"; echo 1.10 > "$d/.screen_zoom"
out=$(cat <<'JSON' | /usr/bin/python3 -S "$(dirname "$LIB")/realize_plan.py" g1 "$d" 3127 1309
{"spaces": [{"uuid": "UA", "id": 8, "index": 1, "display": 1, "fullscreen": 0, "active": 1},
            {"uuid": "UB", "id": 18, "index": 2, "display": 1, "fullscreen": 0, "active": 0}],
 "windows": [{"id": 11, "app": "Claude", "x": 0, "y": 0, "w": 1562, "h": 1309, "spaces": [8]},
             {"id": 92, "app": "Google Chrome", "x": 1820, "y": 25, "w": 1396, "h": 89, "spaces": [8]},
             {"id": 90, "app": "Google Chrome", "x": 1720, "y": 0, "w": 1720, "h": 1440, "spaces": [18]}]}
JSON
)
assert "49.the real window comes over" "$(grep -c '^space 90 1$' <<< "$out")" "1"
assert "49.…and is framed to today's right tile" "$(grep -c '^frame 90 1563 0 1563 1309$' <<< "$out")" "1"
assert "49.the bar is left alone" "$(grep -c ' 92' <<< "$out")" "0"
rm -rf "$d"

line
echo "PASS=$PASS  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "SOME FAILED"
