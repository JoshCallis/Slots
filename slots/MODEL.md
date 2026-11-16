# Slot system — model (single desktop space)

This is the authoritative behavioural spec the `slots/` scripts implement.
"Fullscreen" means *the fill-screen snap was the app's last snap*, nothing to do
with native macOS fullscreen (which is never used).

## Two ways to show a slot (`slots/spaces.sh on|off`)
Everything below — slots, members, coverage, floaters, pairing — is the same in
both; only how a slot reaches the screen differs.
- **Single desktop** (the original; flag off): every window lives on one macOS
  desktop and a switch re-stacks them (`scene_restore`, ~0.6s to reveal).
- **Native spaces** (`config/slots_spaces`): every slot is bound to its own macOS
  desktop (`/tmp/slot_spaces`, slot → desktop uuid) and a switch is a desktop flip
  (~0.13s from the gesture). Before the flip, any member window that is on another
  desktop is moved over (only a window shared between slots, e.g. Claude beside
  Safari and beside Chrome, ever travels) and drifted tiles are re-set. Floaters
  are made sticky (on every desktop); snapped windows never are. A slot with no
  desktop takes a free one (emptiest first); a dead slot's desktop becomes free.
  The flip normally comes first, from caches the last switch wrote (the slot's
  desktop; the window chosen for each app, so a shared one is moved without a
  query), and the full plan runs after it to catch drift. Reads come from the
  window server (`~/bin/space_query`), never yabai's window query; yabai is asked
  only to move windows and flip — never to focus a window (both of those go through
  the apps' Accessibility, which a busy Fusion stalls for 15s+, and yabai serves one
  request at a time). The leaving slot is reconciled ~1s later from ITS OWN
  desktop's windows, whatever is on screen, on a copy of the state, taking the lock
  only to swap the result in; a member with no window there but one on another
  desktop (Claude, borrowed by the other pair) is kept.
  macOS's own desktop switches (Dock, ⌘-Tab, Mission Control) are followed
  (`spacesync`). A swipe from a desktop that is no slot's (3ds Max full screen)
  returns to the current slot. Requires no app assigned to All Desktops (Dock ▸
  Options ▸ Assign To ▸ None — set it from the Dock menu: clearing the defaults key
  alone left running apps' windows on every desktop).

## Window classes (decided by live geometry)

A window's class is decided by where it actually is on screen, not by a registry:

- **Snapped** — its frame matches one of the 7 tiles (within an 8px tolerance).
  A snapped window is recorded by **tile name**, participates in the coverage rule,
  is a jump target for its app hotkey (`navapp`), and lives on the `normal`
  sub-layer **beneath** the floaters. Canon apps (the `APPS` sequence — `Podcasts
  Notes SketchUp Fusion Claude OrcaSlicer Safari "Google Chrome"`) and non-canon
  apps are treated alike: snap one with the snap script (or summon it via
  `focus.sh`/`goto_app.sh`) and it is a snapped member. A window merely *brought
  onto the screen* some other way (clicked, Dock, dragged to a tile) is **not**
  committed — see Switching.
- **Floater** — a window at a **non-tile** size. Recorded at its literal `x,y,w,h`
  geometry, it is **sticky** (shown on every space), **never resized** by the
  scripts, and pinned to the `above` sub-layer so it is **always on top of every
  snapped window** and can never be covered by one. A window becomes a floater when
  it is brought to front via the scripts or is found visible-and-loose while a space
  is reconciled. Closing it (normal close or the remove script) drops it from **all**
  spaces.
- **A canon app is never a floater** (2026-10-20: it only ever comes loose by mistake).
  Found loose by a reconcile (no window of it on a tile — a docked window plus loose
  palettes/dialogs still reads as docked), it is recorded at its tile (`canon_tile`:
  where it was snapped in that space, else its last tile, else any tile it holds, else
  the biggest free one) and **snapped back** once the mouse button is up — unless it was
  dropped on a tile by hand meanwhile. Any loose record of a canon app (old state) is
  rewritten onto its tile (`unfloat_canon`) before navapp/activate/reconcile read it.

A **multi-window app** (e.g. Fusion's main canvas plus its narrow side palettes and
a tiny helper window) is reconciled to a **single member**, preferring its
tile-matching (docked) window over the loose ones — so it never lands as several
members, one per window, which is what used to let it metastasise across spaces.

**Layer invariant:** floaters `above`, snapped `normal`. A window that is snapped
(or discovered in a snapped position) is always made **non-sticky** — pulled off
`above` back to `normal` — so it never competes with the floater layer.
`scene_restore` and `pin_loose_above` enforce this on every reveal/activate.

Classification reads window sizes — the only place screen state is consulted; all
*recorded* state still comes from explicit script/hotkey events.

## Concepts

- **Slot** — a position in an ordered sequence. A slot records the apps that
  belong to it, each with a **position** and a **z-order**. It is not tied to
  any particular app; apps come and go, the slot keeps its sequence position.
- **Sequence** — the ordered list of slots. Swiping moves through it.
- **Current slot** — where we are now.
- **app last-position** — each app's most recent snap position (global). Where it
  lands when brought to front.

Positions: `full | left | right | top-left | top-right | bottom-left | bottom-right`.
`full` overlaps every other position; `left`/`right` each overlap their two
quarters. Two positions "overlap" if they share any screen area.

## Coverage rule (the core invariant)

A slot only records what is *visibly on top*. Whenever an app is placed at a
position, every existing member whose position **overlaps** it is removed from
that slot (it's now covered). So `full` clears the slot down to that one app; a
side clears the two quarters on that side. On swipe-away the slot is also synced
against what's actually on screen (see Switching). Covered/hidden things are
never kept.

## Switching (swipe ±1)

- Before leaving, sync the current slot to the screen — **members only**: re-read
  where each recorded member actually sits (tile ↔ floater), but never adopt a
  window that isn't already a member (an app already floating elsewhere, loose on
  screen, is the one exception — floaters are sticky). A non-member neither joins
  nor counts as covering a member. Then drop anything recorded that isn't there, and prune
  members covered by a higher app. (the failsafe)
- Move to the adjacent slot in the sequence (wraps around). Duplicate spaces are
  left intact — identical copies (e.g. from a `fullnew`) are never collapsed or
  deleted on swipe; only the deliberate `destroy` removes a space.
- Restore that slot: raise its apps in recorded z-order (last = focus) and AX-
  position each to its recorded position. Non-members are left behind (not
  hidden). This is the `scene_restore` atomic restore.

## Deliberate actions inside a slot

### Snap front app A to POS (any position, including full)
- Remove every current-slot member whose position overlaps POS (coverage rule).
  For `full` that empties the slot; A becomes the sole fill-screen member.
- Set A's position in the current slot to POS, top of z-order. Set last-pos = POS.
- **Cross-slot rule:** remove A from every *other* slot whose recorded position
  for A ≠ POS (a resize means it no longer fits there).
- **Snapping always produces a snapped, non-sticky member** — even if A was a
  floater. A snapped window is a tile member like any other: it joins the coverage
  rule, becomes a jump target, and is pulled off the `above` layer to `normal`.
  Its prior floater membership/geometry is dropped from every space.
- Fill-screen otherwise just fills the current space. No pending state.
- **Exception — a floater snapped to `full` gets its own space.** If A is snapped
  in no space (a floater, e.g. Control Room) and the current space holds some
  other snapped app, A is not written into the current space: a new slot holding
  only `A|full` is inserted right after the current one and becomes current (native
  spaces: A's window moves to that slot's desktop). The space it was summoned over
  keeps its members, so their app hotkeys still jump back to it. On a space with no
  snapped app, A just fills that space as above.

### Duplicate the current space (`fullnew`)
- Create a brand-new slot inserted **immediately after** the current one that is
  an exact copy of the current slot (same members, positions, relative z-order);
  current becomes that new slot.
- Does not look at or touch the front window. Nothing on screen changes — the new
  space shows the same arrangement — so no window is moved, activated, or
  restored. The user then edits this fresh copy as they wish; the original space
  is left intact and reappears on swipe-back.

### Bring app A to front, no swipe (`activate`)
- **A has its own space** (it is `full` in another slot and not a member of the
  current one) → go there exactly as `navapp` would. Joining the current space at
  its last position (`full`) would wipe it.
- **Floater A** (any non-canon app not snapped here):
  raise that one window in place — never re-tile the scene. Register it at its
  current geometry as a sticky floater if it wasn't one yet (so a just-opened loose
  window is adopted on first summon instead of being snapped). Never resized.
- If A is already a snapped member of the current slot, just raise it at its
  recorded position.
- Else (canon) add A to the current slot at **A's last tile** (it takes over the
  space at that tile via the coverage rule); only an app with no recorded history at
  all defaults to full.
  (A stays in any other slots it was in.)

### Jump to app A's space (`navapp`, the app hotkey via `goto_app.sh`)
- **A is snapped in the current space** → just bring it to the front **here**; no
  jump. Tested on *recorded* membership, so an app genuinely assigned to this space
  stays put even when it also has a home elsewhere — distinct from one merely
  summoned on top of this space (which the jump path's leaving-space reconcile, that
  excludes the target, still handles).
- **A is snapped only in other spaces** → jump to the next such space in the
  sequence (after current, wrapping) and focus A there. If A's layout has
  same-tile alternatives (see §Custom default layouts), a space whose tile already
  holds the winning alternative is preferred; failing that, the target's tile has
  its current alternative replaced by the winner (the old one just leaves that
  space). A tile holding none of the alternatives is left alone.
- **Layout re-pair.** Landing on (or staying in) a space where A sits at its
  §Custom-default-layout tile, any other tile of that layout that no member
  covers gets its companion back (same fit + recency rules as placeapp). This is
  what puts Claude back beside Safari/Chrome after Claude quit and was pruned.
- **A is snapped nowhere but exists as a floater** → raise it in the current space
  (no jump). **A is in no slot at all** → the caller (`goto_app.sh`) falls through
  to `placeapp`, giving it its own new space.

### Clicking a parked window (`clicked`, via `slots/app_focused.sh`)
A reveal hides non-members by parking them on yabai's `below` sub-layer, which app
activation can't undo. When the user focuses such a window (click, ⌘-Tab, Dock):
- it **fills the screen** and its app is `full` in some space → switch to that
  space exactly as `navapp` would (the click *is* "go to A's space");
- otherwise → lift just that window to `normal` and raise it. Not committed.

## Give an unassigned app its own space (`placeapp`)
Used by `goto_app.sh` when the requested app `X` is a member of **no** slot:
launch `X` if needed, create a brand-new slot holding only `X` **at the size it
actually launched** (its docked tile if it opened onto one, else its current
geometry — never coerced to `full`; full is only the fallback when its geometry
can't yet be read), splice it into the sequence next to `X`'s canonical neighbour
(its position in the predefined app list), make it current, and restore it (so `X`
is on screen). So reopening a quit app gives it its own space "however it comes in".

`X` sits canonically between predecessor `P` and successor `S` (the list wraps).
The insertion point is chosen in priority order:

1. **Between, if adjacent** — if some space holding `P` is immediately followed
   by a space holding `S`, insert `X`'s space strictly between them (nearest such
   pair to the current space wins).
2. **Single best neighbour anchor** — otherwise anchor to `P` (new space goes
   just after it) or `S` (just before it). A neighbour that lives in exactly one
   space (**exclusive**) beats one spread across several (**shared**); ties break
   to whichever anchor is nearest the current space.
   - A shared neighbour's occurrences split the ring into arcs; the new space
     goes in the **larger** gap, abutting the occurrence on the canonical side —
     i.e. *outside* any consecutive block, never inside it. (One rule — "the
     occurrence with the biggest gap on the relevant side" — covers exclusive,
     consecutive-block and gapped cases alike; 3+ occurrences fall out of the
     same arithmetic.)
3. **Search outward** — if neither `P` nor `S` is present anywhere, walk the
   canonical list outward (two steps, three, …) and anchor beside the nearest
   present app (predecessor-side → after it, successor-side → before it).
4. **Append** — if nothing in the list is on screen, add the space at the end.

Like a swipe, the slot being left is reconciled first (the failsafe). This is
the deliberate "new space" action — it replaces using `fullnew` (duplicate the
current space) for that purpose.

### Custom default layouts (paired spaces)
By default the new space holds only `X` at its launched size. A few apps instead have a
**custom default layout** — a primary tile plus a companion alongside — declared
in `place_layouts` in `config/settings.json` (compiled into slotlib's
`PLACE_LAYOUTS` as `PRIMARY|app:pos;app:pos;…` entries). Shipped:

- `Safari` → `Safari:right` + `Claude:left`
- `Google Chrome` → `Google Chrome:right` + `Claude:left`

Adding another is one entry in that JSON list; an app with no entry keeps the
plain solo-`full` behaviour. Rules:

- **Companion fit.** A companion is only pulled in if it *fits* the wanted tile:
  it is in **no** slot, or **every** slot it is already in records it at exactly
  that tile. So a Claude that is unassigned, or already snapped `left` somewhere,
  joins on the left; a Claude filling its own space (`full`) does **not** — the
  primary then just opens solo `full`, as if it had no layout. (Same window, two
  spaces: a pulled-in companion stays a member of its original same-tile space
  and is repositioned per-space on restore — the standard multi-slot model.)
- **Same-tile alternatives.** Several members at one tile (e.g. `Claude:left` +
  `Safari:right` + `Google Chrome:right`) are *alternatives*, not a stack: exactly
  one takes the tile — among those that fit, a running app beats a non-running one,
  then the one most recently switched to via slots (`nav`/`navapp`/`activate`/
  `placeapp` record the app they land on in `/tmp/app_mru`), then config order. If
  `X` itself is at that tile it wins it outright.
- **Focus.** The just-opened app `X` is always the focus (placed last in z), tile
  positions come from the layout regardless of which app `X` is.
- **Reverse direction.** When `X` is itself a *companion* of one or more layouts
  (e.g. Claude) and gets its own new space, the first layout (in `PLACE_LAYOUTS`
  declaration order) whose **primary** fits is brought in alongside `X`; if none
  fit, `X` opens solo `full`.
- **Splicing is unchanged** — the new space is still anchored on `X`'s canonical
  neighbour by the priority rules above; the layout only decides the space's
  *contents*, not where it sits in the sequence.
- Companions are launched (if not already running) so they can be positioned.

## Closing the active app (`close`)
- Remove A from **all** slots, forget its last-position, quit A. The current
  space is **never** destroyed by closing — only the deliberate `destroy` removes
  a slot. Current stays put and is restored; if A was its only member the slot
  survives (empty, or adopting whatever is now revealed). Whatever is now on
  screen in A's vacated rectangle (the window that was behind it) is adopted into
  the current slot, so it becomes the space.

## Closing the front window (`winclose`)
Never quits/closes a window — it just peels the front app out of the current
space, so it reads as "closed" here while staying open and whatever was behind it
comes forward.
- **A fills the current space** (its sole `full` member — a "full-screen group"):
  destroy the whole group and swipe to the space we were on **last** (else the
  adjacent one), the same way `destroy` would but aimed back the way we came. A
  is not closed — it just becomes unassigned from this space (still running, still
  a member of any other space) and is left behind, covered by the space we land
  on. Exception: if this is the only space left there's nowhere to go, so it falls
  through to the peel below (a space is never destroyed down to nothing). "Last
  space" is the slot we came from on the previous `nav`/`navapp`/`placeapp`.
- A not in the current slot (floating / different slot): just hide it; it leaves
  this space (kept open, never closed) even if it ends up in no slot at all. No
  recorded state changes; the current slot is restored so focus settles on what's
  revealed.
- A in the current slot but **not** full-screen (a half/quarter tile): remove it
  from this slot and hide it (move it off-screen). It stays in any other slots it
  belongs to; if this was its only slot the slot survives (it just goes empty
  until something is revealed). The window is preserved, not closed. Whatever now
  fills A's vacated rectangle (the window behind it) is adopted into the slot in
  A's place.

## Back to the previous space (`back`)
Go to `prev_slot` (the space we were on last), keeping the current one. Control
Room's hotkey uses it to toggle off when Control Room is on its own space (hiding
it there would leave an empty desktop).

## Destroy the current space (`destroy`)
- Drop **all** members of the current slot and remove the slot from the sequence.
  Apps that lived only here become **unassigned** (still running, untracked);
  apps also in other slots keep those memberships. Nothing is quit or hidden.
- Land on the neighbouring slot and restore it.

## An app quits by any means (`appterm`)
Fired by yabai's `application_terminated` signal (Dock quit, ⌘Q, **or a crash** —
not just the `close` script), via `slots/app_terminated.sh` (debounced + op-guarded
like the window-move handler). Two effects:
- **Prune.** Every recorded member whose app is no longer running is dropped from
  all slots and forgotten (last-position cleared). This stops a quit app lingering
  as a phantom member — the thing that used to make a swiped-away space adopt the
  previous space's window and duplicate it.
- **Destroy a bare full-screen shell.** A space is destroyed **only** if the quit
  app was its `full` member and **no other snapped app survives** there. Floaters
  don't count (they're sticky/global and live on every space anyway), so a full app
  with only floaters on top is still destroyed. A space whose quit app was a
  side/corner tile, or that still holds another snapped app, is kept as-is (minus
  the dead member). A grid cell is never destroyed (it stays current, so Toggle
  there relaunches the quit pick). If the destroyed space is the current one, land on a neighbour
  (last space if available, else the left neighbour) and restore it; a background
  space dying leaves the current space untouched.

Mirrors `close`: because both only ever act on apps still *recorded* as members, an
app quit through the `close` script (which already removed it) is a no-op here — the
two never fight.

## The grid (`swipe`, `gridtoggle`; `slots/grid.py`, `config/slot_grid.json`)
Asked for 2026-10-17: fixed spaces laid out on a 3×3 grid (Control Room ▸ Slots ▸
Grid), swiped between in four directions, instead of one key per app.
- **A cell is a slot with a fixed id** (`g1`…), so it keeps its desktop. A cell is
  `split` (a `left` and a `right` list) or `full` (one list). Entering it **seeds** it:
  each position's pick goes to its tile (on top: the app jumped to, else the left/full
  one), anything else on those tiles leaves, and a seeded app leaves every off-grid
  slot (one app, one place — an emptied off-grid slot is dropped). Floaters untouched.
  A cell that dropped out of the sequence is put back; reconcile never drops one.
- **Outside apps** (special `coherence`: 3ds Max, full screen on its own Space) can be
  an alternative but never a member: while one is the pick, the position keeps its
  first ordinary app as **resident** (never launched for it), so the cell keeps its
  desktop. Entering the cell shows the app's Space instead; from there `gridtoggle`
  flips back and swipes start from the cell. (2026-10-18: Toggle to Max emptied the
  Fusion cell, which lost its desktop; swipes to it fell back and were dropped.)
- **Alternatives.** Several apps in one list: one shows at a time — the first
  (priority) until `gridtoggle` steps it on. The pick sticks (`/tmp/slot_grid_active`
  `cell|pos|app`): leave and come back, it is still the one picked.
- **`gridtoggle`** steps the focused app's position (else the first position with
  alternatives) to its next app, in this cell only. Off the grid: nothing. A pick
  that has quit is brought back (relaunched) instead of stepped past. Control Room's
  window sits on the `above` sub-layer, so in a cell where it isn't the pick it is put
  away (SIGUSR2, its ✕) and toggled to it is summoned (SIGUSR1).
- **`swipe DIR`**: content follows the fingers — `left` goes to the cell on the RIGHT,
  `up` to the cell BELOW. Empty cells are never landed on. With `arm_hops`, a swipe
  whose cell is empty takes one step toward home on the other axis (in a plus: right
  arm, swipe up → bottom arm); the opposite arm is still only via the middle. From an
  off-grid space (an app's own space, 3ds Max's desktop) any swipe goes home (`home`,
  else the cell with the most neighbours).
  **A swipe never launches anything** (2026-11-15): a cell none of whose shown apps
  (or resident) is open is skipped — the swipe goes on to the next cell that way, or,
  with none, does nothing (an arm hop or home that is closed: nothing). Landing on a
  cell, a pick that isn't open is left out and its tile stays empty. App keys still
  launch.
- **App keys** (`navapp`) for an app the grid places go to its cell — one already
  showing it, else the first listing it — and make it that position's pick. Apps not
  in the grid keep everything above (own space, off-grid, placeapp).

## Cycling an app's own windows (`slots/slot_wincycle.sh next|prev`)
Asked for 2026-11-14: alongside `gridtoggle` (Chrome ⇄ Safari), step through the
FRONT app's windows in its spot. Ring = the app's standard, unminimized windows on any
desktop, by window id; the next one is brought to this desktop if elsewhere, given the
focused window's frame and focused. One window → nothing. No slot state changes (a
member is app:tile; the old window stays under the new one). Slots off → native ⌘` /
⌘⇧`. Commands `slots.window.next|prev`; Chrome binds them to five fingers ← / →.
Log: `[wincycle]` in `/tmp/slots.log`.

## Robustness
- **A slot follows its windows** (native spaces, `realize_plan.py`): a slot with no
  desktop, or whose desktop holds none of its own apps' windows (apps snapped in it
  and no other slot) while exactly one unclaimed desktop holds them all, is bound to
  that desktop — never an empty one, never dragging the windows over.
- **One op at a time.** Every state-changing op holds `/tmp/.slot_lock`
  (shlock; a dead holder is cleared, a >10s wait runs unlocked and is logged).
- **Display blips.** Any `display_*` signal stamps `/tmp/.slot_display_ts`
  (`slots/display_event.sh`); for 20s reconciles leave recorded state alone
  (macOS is shuffling windows between screens), then the current slot is
  re-revealed onto whatever screen is now main.

- **UI Zoom** (`ui_zoom.sh` § Screen zoom; the screen tiles are cut from is the
  top-left native/zoom). Its glide re-fits only the windows on screen; every other
  desktop keeps the tiles of the zoom it was last shown at. So a window on a tile of
  ANY zoom level (100–300%, 5% steps) is that tile, never a floater (`tile_for_geom`,
  `slots/zoomtiles.py`, `scene_restore --zoom`), and is re-set on its next reveal or
  glide. While a glide is moving windows (ui_zoom.sh's press lock, +1s) reconciles
  leave recorded state alone, a left slot's reconcile and reset wait it out (≤3s),
  and realize's tile frames wait for it to land and are re-cut.

## Init / restore-fail
- Build the sequence from the predefined app list: one slot per currently-open
  listed app, in list order, each app at `full`, current = the frontmost app's
  slot (or the first).

## Explicitly dropped (were in earlier drafts)
- Fullscreen-gets-its-own-space + the pending-fullscreen state. (Fill-screen
  stays in the current space; use `fullnew` to get a new one deliberately — except
  a floater snapped full, which does get one; see Snap.)
- Neighbour auto-resize when snapping. ("Nothing else should configure around it.")
- Any clean-tiling requirement. (Arrangements need not tile cleanly.)
- Hiding non-slot windows on switch. (Left as-is.)
- Manual space reordering (`slotlib move`, the `move_space_left/right.sh` entry
  points). The sequence order always follows the canonical app list — set once
  at `init` and preserved by `placeapp`'s neighbour-anchored splicing and
  `fullnew`'s insert-after-current — never rearranged by hand.

## State files (/tmp)
- `slot_seq`      — ordered slot IDs, one per line (the sequence).
- `slot_members`  — `slotID|app|position|z` lines.
- `app_lastpos`   — `app|position` global last snap per app.
- `current_slot`  — current slot ID.
- `prev_slot`     — slot we were on before the current one (full-screen winclose
                    lands here).
- `app_mru`       — apps switched to via slots, most recent first (same-tile
                    layout tie-break).
- `slot_counter`  — monotonic slot-ID source.
- `z_counter`     — monotonic z-order source.
