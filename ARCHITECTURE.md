# Yabai Slots — system architecture

This file maps the **slots / window layer**. The repo's other system — the Fusion
tooling — is mapped by `FUSION.md`; `remap/`, `bin/` and `config/` are shared by
both. Start from `CLAUDE.md` for the routing table.

The one experience — seamless switching between "slots" (virtual spaces on a single
macOS space), with CAD apps getting special navigation and overlay bars — is built
from five cooperating layers. This file is the map; `slots/MODEL.md` is the
behavioural spec for the engine layer.

```
  BTT gestures/hotkeys          yabai signals (config/yabai/yabairc)
        │                              │
        ▼                              ▼
  ENTRY POINTS  ──────────────►  EVENT HANDLERS
  simple_nav.sh  goto_app.sh     slots/window_event.sh   (hand move/resize)
  focus.sh  snap.sh              slots/app_terminated.sh (any app quit)
  remove_app.sh                  fusion_observe_heal.sh  (Fusion AX race)
  slots/slot_*.sh                space_changed_handler.sh(legacy, see below)
                                  {fusion,sketchup}_activated.sh
        │                        cad_deactivated.sh
        ▼                              │
  ENGINE: slots/slotlib.sh  ◄──────────┘
  (state machine; state in /tmp/slot_*)
        │
        ▼                              side channel
  REVEAL: scene_restore (bin/scene_restore.m)  ──►  cadbars.app (freeze-frame;
  atomic z-order reveal via yabai SA sub-layers     retired/disabled, see below)
        │
        ▼
  CAD NAV daemons: reanchor / reanchor_pan / FusionScrollFilter / fusion_dwell
  (lifecycle managed by BetterTouchTool/*.sh wrappers, driven by the handlers)
```

## Settings (the GUI-facing layer)

All user-tunable, per-app behaviour lives in **`config/settings.json`** — the file a
future browser-based settings UI reads and writes. Schema is documented in the file
header comment of `config/gen_settings.py`. It currently declares:

- **apps** — the ordered canonical app list (`canonical: true` entries form the slot
  sequence order), each with its state key, `open -a` name, window-owner spellings
  (`alt_names`), CLI aliases, special launch handling, and — for CAD apps — overlay
  bar heights (`cad: {top_bar, bottom_bar}` — the spelling `gen_settings.py` documents;
  this line said `{top, bottom}` until 2026-09-08 and no consumer ever used those).
- **titlebar** (per app, px) — hide that much title bar above the top screen edge
  while the app is snapped to a top-edge tile (Photoshop's Application Frame strip,
  22). Written by `do_move` + `realize_plan.py`; the app drags it back on activation,
  so `slots/titlebar_hide.sh` (yabai `window_moved`/`window_resized`, regex in
  yabairc by hand) re-pushes it. Readers clamp to the screen, so it stays its tile.
  Not applied by `scene_restore` (single-space mode). **Unused since 2026-10-11**:
  the app fought the push (title bar flashing for seconds), so Photoshop runs in
  Full Screen Mode With Menu Bar instead and the yabai signals were removed.
- **place_layouts** — the "open this app paired with a companion" defaults
  (e.g. Safari opens `right` with Claude `left`).

Consumers:
- Shell side: `config/load_settings.sh` is sourced by `slotlib.sh`, `app_resolve.sh`
  and `slots/cad_handoff.sh`. It regenerates `config/settings.cache.sh` (gitignored)
  from the JSON via `config/gen_settings.py` whenever the JSON or generator is newer,
  then sources it — so the hot path costs two `stat`s, edits to the JSON are picked
  up on the next op with no manual step, and a JSON that fails to compile leaves the
  last-good cache in charge (emergency built-ins cover the no-cache-ever case).
- NOT consumed from JSON (deliberately, see Legacy + Fixed plumbing): the app
  regexes inside `config/yabai/yabairc` signal definitions. If you add a new CAD
  app, mirror it there by hand.

## Native spaces mode

`slots/spaces.sh on|off|status` (flag `config/slots_spaces`, gitignored). Each slot
owns a real macOS desktop; `do_restore` hands off to `realize_slot` (slotlib.sh §
native spaces mode), whose planner is `slots/realize_plan.py` (binds the desktop,
plans window moves — one python start-up per switch). `scene_restore` is not used
in this mode. yabai 7.1.22 can't create desktops on macOS 26 (`space --create` is a
silent no-op), so `mc_add_desktop` clicks Mission Control's "add desktop" button;
`spaces.sh on` tops up a pool once. `slots/space_event.sh` (yabai `space_changed`)
keeps "current" in step with desktop switches macOS makes itself. Spec:
`slots/MODEL.md` § Two ways to show a slot.

### slotd — the resident switch path (2026-10-10)

`slots/slotd.sh on|off|restart|status` (flag `config/slots_daemon`, gitignored;
launchd `com.josh.slotd`, log `/tmp/slotd.log` with per-op timings).
`slots/slotd.py` is a resident PORT of slotlib's switch path in native spaces mode
— `goto_app.sh`'s common case, `navapp`, `nav`, `spacesync` — reading/writing the
same `/tmp/slot_*` files under the same lock, talking to yabai over its socket.
`goto_app.sh`, `simple_nav.sh` and `slots/space_event.sh` ask it first via
`~/bin/slotc` (`bin/slotc.c`); anything it doesn't handle (app already in the
current slot, floaters, unassigned apps, a companion to launch, no cached desktop,
single-desktop mode, the off switch) comes back as FALLBACK before any state is
touched, and the script runs `slotlib.sh` exactly as before. Measured: the engine's
part of a jump went from ~100–150 ms to 2–15 ms. `slotlib.sh` was not changed.

**Floaters (2026-10-11)**: navapp/activate's floater branch is ported too, so
`focus.sh` (`slotc focus`), `slot_activate.sh` (`slotc activate`) and Control Room's
toggle (`goto`/`focus` of `Remap` — remap_open.sh's in-view test, in-process) also
go through slotd. Windows are read in-process from CoreGraphics (`ws_windows`, one
window-server connection held by the daemon — ~5 ms vs a 40 ms `space_query` fork);
stranded windows go sticky and the floater goes `above` *before* `activate_app`;
`pin_loose_above` follows off the hot path (`slotlib.sh pinhere`). The reconcile
slotlib runs first is deferred, as in navapp. An app with NO window at all gets one
from `open -a` (a Dock click — Finder reopens at its remembered spot). Control Room
is never quit by its key, ✕ or Escape: RemapApp HIDES (SIGUSR2) and `summon`
(SIGUSR1) unhides — quitting made every show a ~1 s cold launch. Summoning Finder:
~2 s → ~35 ms (~65 ms when its window has to be reopened); Control Room show/hide:
~1.1 s → 20–45 ms. Still FALLBACK: a hidden/minimized window, a CAD floater, a window
sitting on a tile, Control Room not running (cold start), a full-screen Space.
**3 s deadline, latest press wins (2026-10-13)**: every jump entry point sources
`slots/jump_stamp.sh` (token in `/tmp/slot_jump_gen` + `SLOT_DEADLINE`); slotc forwards
the token and its clock. slotd drops a jump (`X`, slotc exit 4, the script does nothing)
once a newer press rewrote the token or 3 s have passed — while waiting on the lock, and
before committing, when a 0.5 s yabai probe fails (yabai queues requests, so a command
sent to a stuck yabai fires late); `yabai()` is capped by the deadline. slotlib's
`slot_lock` does the same for the fallback path (`jump_dropped`). Cause it guards
against: a display burst (wake) ran several reveals at once and yabai stalled 10 s per
call — `display_event.sh` now debounces by token.
**Rollback**: `slots/slotd.sh off` (instant; the daemon dying has the same effect).
Pre-slotd copies of `slots/` and the entry scripts: `snapshots/pre_slotd_2026-10-10/`.
**Any change to slotlib's nav/navapp/spacesync/realize logic must be mirrored in
slotd.py** — `slots/test_slotd.sh` diffs the two engines.

## Entry points (external ABI — paths wired into the keyboard/gesture layer; do not move/rename)

Gestures call these from BetterTouchTool; the four-finger KEYBOARD layer that
calls the same scripts is remapd's since 2026-09-08 (`remap/bindings.json`,
situations `finger4` / `finger5` — see `remap/README.md` § The slots layer). The
paths are the ABI either way.

| script | gesture/keys it serves | what it does |
|---|---|---|
| `simple_nav.sh` (also via `BetterTouchTool/yabai_nav.sh`) | swipe ±1 | `slotlib nav` + CAD handoff |
| `goto_app.sh "<app>"` | per-app hotkeys | resolve name → `slotlib navapp`, falling back to `placeapp` (new space, possibly paired via place_layouts) |
| `focus.sh "<app>"` | misc app hotkeys | resolve + ensure window → `slot_activate.sh` (raise here, no jump) |
| `toggle_app.sh "<A>" "<B>" ["<startsOn>"]` | a toggle key (written by Control Room ▸ Slots ▸ Shortcuts) | reads slot membership, then `goto_app.sh` the app whose space you are NOT on — `focus.sh` when it is already a member of this slot. Tests: `slots/test_toggle.sh` |
| `snap.sh <pos>` | snap hotkeys | `slotlib snap` (7 tile positions) |
| `remove_app.sh "<app>"` | peel named app from this space | `slotlib winclose <app>` |
| `slots/slot_activate.sh` `slot_close.sh` `slot_winclose.sh` `slot_fullnew.sh` `slot_destroy.sh` | Cmd-W etc. | thin wrappers: one slotlib op + `cad_handoff.sh` |
| `slots/show_space.sh` | "what's here" hotkey | dialog showing current slot contents |
| `yabai-refresh.sh` (via `~/bin/yabai-refresh.sh`) | BTT button | `yabai --restart-service` |
| `yabai_reset.sh` / `yabai_reset_light.sh` | BTT reset buttons | see Legacy plumbing below |
| `cursor_finger_lift.sh` / `cursor_finger_touch.sh` (via `~/bin/`) | trackpad finger-count gesture | `hide_cursor.sh` / `show_cursor.sh` + `cursor_hide_timer.sh` |

`move_space_left.sh` / `move_space_right.sh` are retired no-ops (manual space
reordering was removed — the sequence always follows canonical app order, see
MODEL.md § Concepts). Kept at their paths only because they're ABI; nothing
calls them anymore.

Every nav-ish wrapper follows the same contract: `slotlib <op>` prints `PREV|NEW`
(focus transition) on its last line; the wrapper feeds that to
`slots/cad_handoff.sh`, which starts/stops the CAD daemons when focus crosses a
CAD boundary.

## The off switch

Control Room ▸ Slots ▸ Settings, or `slots/power.sh on|off|status`. Off =
`config/slots_off` exists (gitignored; survives reboots). Every entry point, yabai
handler and `slotlib.sh` (the dispatch backstop — read-only ops still answer, dry
runs ignore it) test that one path. Off also un-strips windows (sub-layer normal,
shadow back) and kills `borders`; yabairc won't start `borders` while it's set. On
= flag removed + `yabai --restart-service`, which is the startup path. Fallbacks so
no key goes dead: `goto_app.sh` / `focus.sh` / `toggle_app.sh` just `open -a`;
`slot_winclose.sh` (four-finger W; ⌘W itself is native since 2026-10-13) posts a native ⌘W via `keypost`. Untouched: Light /
Dark (contrast_theme), CAD nav daemons, yabai itself.

## Engine

- `slots/slotlib.sh` — all slot/space state and decisions. State files in
  `/tmp/slot_*` (see MODEL.md §State files). Test hooks via `SLOT_*` env vars;
  `slots/test_slots.sh` is the dry-run suite (run it after ANY slotlib change).
- `bin/scene_restore.m` → `~/bin/scene_restore` — the atomic reveal: freeze,
  AX-position members, lower covering windows to yabai's `below` sub-layer, unfreeze.
  Helper: `bin/slot_yabai_focus`. Reads `SCENE_FREEZE` (set by slotlib for
  user-initiated switches) to request cadbars' freeze-frame overlay.
- Compiled helpers in `~/bin` used by the engine: `frontmost_app`, `activate_app`,
  `win_list`, `win_at`. Sources tracked in `bin/` (symlinked back into `~/bin`);
  build lines in each source header, see `bin/README.md`.

## CAD specialness (why Fusion/SketchUp have extra machinery)

- **reanchor / reanchor_pan** (`bin/reanchor.m`, `bin/reanchor_pan.c`; deployed at
  repo root): 3-finger orbit/pan + 2-finger scroll-to-activate for Fusion/SketchUp.
  Persistent, cursor-gated; mode handoff in `/tmp/fusion_reanchor_mode`.
- **FusionScrollFilter** (`bin/FusionScrollFilter.c`; deployed at repo root):
  scroll-to-zoom shaping for Fusion. Persistent — must already be running when a
  gesture starts; never kill it mid-swipe.
- **fusion_dwell** (python, repo root): dwell-click helper, on only while Fusion is
  focused.
- Lifecycle wrappers in `BetterTouchTool/`: `reanchor.sh` (mode switch),
  `fusion_scroll.sh` (idempotent on), `fusion_dwell.sh`, `fusion_trigger.sh`.
  Orchestrated by `fusion_activated.sh` / `sketchup_activated.sh` /
  `cad_deactivated.sh` and `slots/cad_handoff.sh`.
- **fusion_observe_heal.sh**: yabai sometimes never AX-observes Fusion's Qt canvas;
  this restarts yabai once (guarded) so the slot reveal can lower Fusion.
- **CAD palette poison**: Fusion's sticky AXDialog palettes must never be adopted
  as slot members — filtered by subrole in `slotlib.sh` (`cad_aux_geoms` /
  `filter_cad_aux`). Do not replace with size heuristics.

## cadbars (retired)

`/Applications/cadbars.app`: black bars that covered CAD chrome, space-bound via
private CGS APIs. **Retired 2026-06-22** (commit `95f8784`) in favour of
`sketchup_plugins/Josh Hide Chrome.rb`, which hides Fusion/SketchUp's title + status
bars for real instead of covering them — LaunchAgent removed, all four edges disabled
in `~/.config/cadbars/disabled`, `~/bin/cadbars*` symlinks gone. **Source removed
from the tree 2026-09-18**; tag `cadbars-last` has it (`git checkout cadbars-last --
cadbars`). Don't reinstate. `bin/scene_restore.m`'s freeze-frame/handshake calls to
it were deliberately left in place — they gate on `pkill` succeeding, so they no-op
cleanly with cadbars not running (see Engine above). Four BetterTouchTool buttons
still point at the gone `~/bin/cadbars-{fusion,sketchup}-{top,bottom}` — dead, safe
to delete in BTT.

## Legacy + fixed plumbing (works; don't extend)

From the pre-slots era when each app lived on a real macOS fullscreen space:
`yabai_cache.sh`, `yabai_cache_debounced.sh`, `yabai_register.sh`, `yabai_reset.sh`,
`yabai_reset_light.sh`, `space_changed_handler.sh`, and the
`/tmp/yabai_{nav_cache,space_app_map,current_space,last_fullscreen_space,
registered_spaces}` files they maintain. Still wired (yabairc signals; BTT buttons
for the resets) and harmless — `space_changed_handler` also re-fires the CAD
activation hooks on rare real CGS space changes, which is idempotent. Nothing in the
slots engine or cadbars reads these caches. New features must not depend on them;
they can be deleted as a unit once the BTT reset buttons and the two yabairc signal
lines pointing at them are removed.

`config/yabai/yabairc` is the boot-time glue (SA load, `layout float`, all signal
wiring). The duplicated Fusion regex `^(Autodesk )?Fusion$` there is intentional —
yabai matches window-owner names, which flip between the two spellings.

## Rollback

The repo is the canonical source for everything deployed (symlinks per
`bin/README.md`). Tag `pre-tidy-baseline` marks the last state before the 2026-06
restructure; `git checkout pre-tidy-baseline -- <path>` restores any piece, then
rebuild via the build line in the source header (or `bin/build.sh`).
