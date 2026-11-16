#!/usr/bin/env python3
"""The slots grid — fixed spaces arranged on a 3×3 grid (Control Room ▸ Slots ▸ Grid).

Asked for (2026-10-17): instead of one key per app, the spaces are laid out on a grid
and swiped between in four directions. Each grid cell is a slot with a FIXED id (its
cell id, e.g. "g1"), so it keeps its desktop; the engine (slotd / slotlib) seeds its
members from here every time it is entered.

config/slot_grid.json:
  {"arm_hops": true,              # an arm's perpendicular swipe goes round to the next arm
   "home": "g1",                  # where a swipe from an off-grid space lands
   "cells": [{"id": "g1", "row": 1, "col": 1, "layout": "split" | "full",
              "left": [apps], "right": [apps], "full": [apps]}]}

A position holding several apps holds ALTERNATIVES: one shows at a time, the first by
priority until Toggle picks another. The pick sticks (/tmp/slot_grid_active,
`cell|pos|app`) — leaving and coming back keeps it.

Swipe direction is content-follows-fingers: swipe LEFT goes to the cell on the RIGHT,
swipe UP to the cell BELOW. With arm_hops, a swipe whose cell is empty steps one cell
toward home on the other axis (right arm, swipe up → bottom arm); the opposite arm is
still only reached through the middle. A cell none of whose shown apps is running is
skipped: the swipe goes on to the next cell that way, or nowhere — never launching.

CLI (slotlib's side; slotd imports this):
  grid.py swipe CUR DIR      → target slot id ('' = nowhere); $GRID_RUNNING (running
                               app keys, one per line) set → cells with none open skipped
  grid.py apps               → every app the grid lists, one per line
  grid.py seed SLOT          → `app|pos` lines the cell shows now, focus last
  grid.py toggle SLOT FOCUS [DEAD…] → `pos|old|new` and records the pick ('' = nothing to toggle)
  grid.py unshown SLOT       → the cell's alternatives not shown now, one per line
  grid.py pick APP           → `slot|pos` of APP's cell and records APP as its pick
  grid.py cell APP           → APP's cell id, recording nothing ('' = not on the grid)
  grid.py outside SLOT       → the outside app (3ds Max) the cell shows ('' = none)
  grid.py has SLOT           → exit 0 if SLOT is a grid cell
  grid.py cells              → every cell id, one line
"""
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.environ.get("SLOT_GRID") or os.path.join(REPO, "config", "slot_grid.json")
ACTIVE = (os.environ.get("SLOT_STATE_DIR") or "/tmp") + "/slot_grid_active"
DIRS = {"left": (0, 1), "right": (0, -1), "up": (1, 0), "down": (-1, 0)}


def load(path=None, dry=None):
    """DRY (default: $SLOT_DRYRUN) with no PATH / $SLOT_GRID reads no grid: the dry-run
    suites test the ring, never the live config."""
    dry = os.environ.get("SLOT_DRYRUN") if dry is None else dry
    if dry and not (path or os.environ.get("SLOT_GRID")):
        return {"arm_hops": True, "home": "", "cells": []}
    try:
        with open(path or CONFIG) as f:
            g = json.load(f)
    except (OSError, ValueError):
        return {"arm_hops": True, "home": "", "cells": []}
    g.setdefault("arm_hops", True)
    g.setdefault("cells", [])
    return g


def positions(cell):
    """→ [(pos, [apps])] the cell shows, in tile order."""
    if cell.get("layout") == "full":
        return [("full", list(cell.get("full") or []))] if cell.get("full") else []
    return [(p, list(cell.get(p) or [])) for p in ("left", "right") if cell.get(p)]


def cell_of(g, slot):
    return next((c for c in g["cells"] if c.get("id") == slot), None)


def home_of(g):
    h = cell_of(g, g.get("home") or "")
    if h:
        return h
    # No home set: the cell with the most neighbours (the middle of a plus).
    best, bestn = None, -1
    for c in g["cells"]:
        n = sum(1 for dr, dc in DIRS.values() if at(g, c["row"] + dr, c["col"] + dc))
        if n > bestn:
            best, bestn = c, n
    return best


def at(g, r, c):
    """The cell at (R, C) — only one with an app in it: an empty cell is never swiped to."""
    return next((x for x in g["cells"]
                 if x.get("row") == r and x.get("col") == c and positions(x)), None)


def live(cell, act, running):
    """Is CELL worth landing on: one of the apps it shows (or its resident behind an
    outside app) is running? RUNNING: app → bool."""
    return any(running(a) for a in {a for a, _ in chosen(cell, act) + members(cell, act)})


def swipe(g, cur, d, ok=None):
    """→ the cell a swipe D from slot CUR lands on, or None. OK (cell → bool, default:
    every cell) says which cells may be landed on; one that may not — its app isn't
    open (2026-11-15) — is skipped, the swipe going on to the next cell that way, and
    with no such cell it goes nowhere."""
    ok = ok or (lambda c: True)
    if d not in DIRS or not g["cells"]:
        return None
    here = cell_of(g, cur)
    if not here:
        h = home_of(g)               # off-grid (an app's own space, 3ds Max) → home
        return h if h and ok(h) else None
    dr, dc = DIRS[d]

    def walk(r, c):
        while True:
            t = at(g, r, c)
            if not t or t is here:
                return None
            if ok(t):
                return t
            r, c = r + dr, c + dc

    r, c = here["row"] + dr, here["col"] + dc
    if at(g, r, c) or not g.get("arm_hops"):
        return walk(r, c)
    h = home_of(g)
    if not h:
        return None
    # Empty cell: one step toward home on the other axis (round the plus).
    if dr:
        c += (h["col"] > c) - (h["col"] < c)
    else:
        r += (h["row"] > r) - (h["row"] < r)
    t = at(g, r, c)
    return t if t and t is not here and ok(t) else None


def read_active(path=None):
    out = {}
    try:
        with open(path or ACTIVE) as f:
            for l in f:
                p = l.rstrip("\n").split("|")
                if len(p) == 3:
                    out[(p[0], p[1])] = p[2]
    except OSError:
        pass
    return out


def write_active(act, path=None):
    tmp = (path or ACTIVE) + ".tmp"
    with open(tmp, "w") as f:
        for (s, p), a in sorted(act.items()):
            f.write("%s|%s|%s\n" % (s, p, a))
    os.replace(tmp, path or ACTIVE)


def chosen(cell, act):
    """→ [(app, pos)] the cell shows now: each position's pick, else its first app."""
    out = []
    for p, apps in positions(cell):
        a = act.get((cell["id"], p))
        out.append((a if a in apps else apps[0], p))
    return out


def unshown(cell, act):
    """→ the cell's alternatives it does not show now."""
    shown = set(a for a, _ in chosen(cell, act))
    return [a for _, apps in positions(cell) for a in apps if a not in shown]


_OUTSIDE = None


def outside_apps():
    """Apps that can be a pick but never a slot member: special "coherence" (3ds Max
    runs full screen on its own Space). settings.json, read once."""
    global _OUTSIDE
    if _OUTSIDE is None:
        try:
            with open(os.path.join(REPO, "config", "settings.json")) as f:
                _OUTSIDE = {a["key"] for a in json.load(f).get("apps", [])
                            if a.get("special") == "coherence"}
        except (OSError, ValueError, KeyError):
            _OUTSIDE = set()
    return _OUTSIDE


def outside(cell, act):
    """The outside app CELL shows now (its Space is shown instead of the cell's
    desktop), or ''."""
    out = outside_apps()
    return next((a for a, _ in chosen(cell, act) if a in out), "")


def members(cell, act):
    """→ [(app, pos)] the cell's slot holds: chosen(), but a position showing an
    outside app keeps its first ordinary app as resident, so the cell keeps its
    desktop and Toggle comes back to it (2026-10-18: Toggle to 3ds Max emptied the
    Fusion cell, which lost its desktop)."""
    out, rows = outside_apps(), []
    alts = dict(positions(cell))
    for a, p in chosen(cell, act):
        if a in out:
            a = next((x for x in alts[p] if x not in out), "")
        if a:
            rows.append((a, p))
    return rows


def seed(cell, act, focus=""):
    """members(), FOCUS (or the left/full app) last so it takes the keyboard."""
    rows = members(cell, act)
    if not focus and rows:
        focus = rows[0][0]
    return sorted(rows, key=lambda r: r[0] == focus)


def toggle(cell, focus, act, dead=()):
    """Step the focused app's position (else the first with alternatives) to its next
    app; record it in ACT (the caller writes it). A pick in DEAD (quit) is brought
    back instead of stepped past: (pos, old, old). → (pos, old, new) or None."""
    rows = chosen(cell, act)
    alts = dict(positions(cell))
    cands = [p for a, p in rows if a == focus and len(alts[p]) > 1] + \
            [p for a, p in rows if len(alts[p]) > 1]
    if not cands:
        return None
    p = cands[0]
    old = next(a for a, q in rows if q == p)
    if old in dead and old not in outside_apps():
        return p, old, old
    lst = alts[p]
    new = lst[(lst.index(old) + 1) % len(lst)]
    act[(cell["id"], p)] = new
    return p, old, new


def pick(g, app, act):
    """APP's cell — one where it already shows first, else the first listing it —
    and record APP as that position's pick in ACT. → (cell, pos) or None."""
    hits = [(c, p) for c in g["cells"] for p, apps in positions(c) if app in apps]
    if not hits:
        return None
    showing = [(c, p) for c, p in hits if (app, p) in chosen(c, act)]
    c, p = (showing or hits)[0]
    if len(dict(positions(c))[p]) > 1:
        act[(c["id"], p)] = app
    return c, p


def grid_apps(g):
    return {a for c in g["cells"] for _, apps in positions(c) for a in apps}


def main(argv):
    g = load()
    act = read_active()
    op = argv[1] if len(argv) > 1 else ""
    if op == "swipe" and len(argv) >= 4:
        # $GRID_RUNNING (newline list of running app keys), when set: skip dead cells.
        ok = None
        if "GRID_RUNNING" in os.environ:
            run = set(os.environ["GRID_RUNNING"].split("\n"))
            ok = lambda c: live(c, act, lambda a: a in run)
        t = swipe(g, argv[2], argv[3], ok)
        print(t["id"] if t else "")
    elif op == "seed" and len(argv) >= 3:
        c = cell_of(g, argv[2])
        for a, p in (seed(c, act, argv[3] if len(argv) > 3 else "") if c else []):
            print("%s|%s" % (a, p))
    elif op == "toggle" and len(argv) >= 3:
        c = cell_of(g, argv[2])
        r = toggle(c, argv[3] if len(argv) > 3 else "", act, argv[4:]) if c else None
        if r:
            write_active(act)
        print("|".join(r) if r else "")
    elif op == "pick" and len(argv) >= 3:
        r = pick(g, argv[2], act)
        if r:
            write_active(act)
        print("%s|%s" % (r[0]["id"], r[1]) if r else "")
    elif op == "cell" and len(argv) >= 3:
        r = pick(g, argv[2], dict(act))           # a copy: nothing recorded
        print(r[0]["id"] if r else "")
    elif op == "outside" and len(argv) >= 3:
        c = cell_of(g, argv[2])
        print(outside(c, act) if c else "")
    elif op == "unshown" and len(argv) >= 3:
        c = cell_of(g, argv[2])
        for a in (unshown(c, act) if c else []):
            print(a)
    elif op == "has" and len(argv) >= 3:
        return 0 if cell_of(g, argv[2]) else 1
    elif op == "apps":
        for a in sorted(grid_apps(g)):
            print(a)
    elif op == "cells":
        print(" ".join(c["id"] for c in g["cells"]))
    else:
        print(__doc__.split("CLI")[1], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
