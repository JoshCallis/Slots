"""realize_plan.py — the planner behind slotlib.sh realize_slot (native-spaces mode).

    space_query json | python3 -S realize_plan.py SLOT STATE_DIR SW SH

Input is ~/bin/space_query's window-server snapshot — never yabai's query, which
reads apps' Accessibility state and stalls for 15s+ behind a busy Fusion.

One pass, so a switch pays for one Python start-up (process spawns are the cost
on the switch path — this reads the slot files and settings itself rather than
have bash fork a helper per member):
  1. Resolve SLOT's desktop from STATE_DIR/slot_spaces ("slot|desktop-uuid"),
     binding it to a free one if it has none. Free = a regular desktop on the main
     display that no live slot (in slot_seq) is bound to; emptiest first, so a
     recycled desktop rarely still shows an old window. Dead entries are dropped.
     Also refreshes STATE_DIR/slot_space_idx ("slot|index|uuid") for the fast path.
  2. Plan the window ops that make the desktop show SLOT (members from
     slot_members, owner spellings from config/settings.json, Fusion's companion
     windows from config/fusion_companions).

Output: first line "TGT CUR TGT_UUID" (desktop indexes: the slot's, the active
one), or "NOFREE" when a desktop must be added first. Then one op per line:
  sticky ID          toggle sticky (on for a floater, off for a snapped window)
  space ID IDX       move the window to desktop IDX            — before the flip
  evict ID IDX       send another slot's window home to IDX    — before the flip
  activate NAME      give NAME keyboard focus (activate_app)   — after the flip
  frame ID X Y W H   re-set a drifted tile (yabai, via AX)     — after, backgrounded
macOS itself focuses the top window of a desktop it flips to; `activate` is only
for a pair where the member to focus is not the top one, and only when every
window of that app is on the target (activating an app with a window elsewhere
would make macOS jump to that desktop instead).

Also imported by slots/slotd.py (the resident engine), which calls plan() with the
snapshot text instead of paying for a Python start-up per switch.
"""
import json
import os
import sys

import zoomtiles

REPO = "/Users/josh/Code/Scripts"


def lines(path):
    try:
        with open(path) as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except FileNotFoundError:
        return []


def write_if_changed(path, text):
    try:
        if open(path).read() == text:
            return
    except FileNotFoundError:
        pass
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)


def plan(slot, sdir, sw, sh, snap_text):
    """The CLI's stdout as a string, or None for an unreadable snapshot (exit 1)."""
    bpath = os.path.join(sdir, "slot_spaces")
    seq = set(lines(os.path.join(sdir, "slot_seq")))
    members = [l.split("|") for l in lines(os.path.join(sdir, "slot_members"))]
    comps = set(l.strip() for l in lines(REPO + "/config/fusion_companions")
                if not l.lstrip().startswith("#"))
    owners, activate_as, cad, titlebar = {}, {}, set(), {}   # from settings.json, as gen_settings.py reads it
    try:
        for a in json.load(open(REPO + "/config/settings.json")).get("apps", []):
            n = [a["key"]]
            for x in [a.get("open", a["key"]), a.get("activate", a["key"])] + a.get("alt_names", []):
                if x not in n:
                    n.append(x)
            owners[a["key"]] = n
            activate_as[a["key"]] = a.get("activate", a["key"])
            titlebar[a["key"]] = int(a.get("titlebar", 0))
            if "cad" in a:
                cad.update(n)
    except Exception:
        pass
    try:
        snap = json.loads(snap_text)
        spaces, ws = snap["spaces"], snap["windows"]
    except Exception:
        return None

    # ── 1. the slot's desktop ────────────────────────────────────────────────
    desk = [s for s in spaces if not s["fullscreen"] and s["display"] == 1]
    byuuid = {s["uuid"]: s for s in desk}
    cur = next((s["index"] for s in spaces if s["active"]), 0)
    bind, raw = {}, lines(bpath)
    for line in raw:
        p = line.split("|")
        if len(p) == 2 and p[0] in seq and p[1] in byuuid and p[1] not in bind.values():
            bind[p[0]] = p[1]
    # Where this slot's own windows already are: a desktop holding the real window
    # (> 600×400, on one desktop only) of an app snapped in this slot and no other.
    # Self-heal for a lost or stale binding (a cell emptied and rebound to a fresh
    # desktop left Fusion behind on its old one, 2026-10-18): follow the windows
    # rather than drag them over, or show an empty desktop.
    keyed = {n: k for k, ns in owners.items() for n in ns}
    snapped = {}
    for m in members:
        if len(m) == 4 and "," not in m[2] and m[0] in seq:
            snapped.setdefault(keyed.get(m[1], m[1]), set()).add(m[0])
    own = {a for a, ss in snapped.items() if ss == {slot}}
    holds = {}
    for w in ws:
        if len(w["spaces"]) == 1 and w["w"] * w["h"] > 600 * 400 and keyed.get(w["app"], w["app"]) in own:
            holds.setdefault(w["spaces"][0], set()).add(keyed.get(w["app"], w["app"]))
    used = set(v for k, v in bind.items() if k != slot)
    if slot in bind and own and not holds.get(byuuid[bind[slot]]["id"]):
        home = [s for s in desk if s["uuid"] not in used and holds.get(s["id"]) == own]
        if len(home) == 1:
            del bind[slot]          # → rebound to HOME just below
    if slot not in bind:
        free = [s for s in desk if s["uuid"] not in used]
        if not free:
            return "NOFREE\n"
        count = {s["id"]: 0 for s in free}
        for w in ws:
            if len(w["spaces"]) == 1 and w["spaces"][0] in count:
                count[w["spaces"][0]] += 1
        free.sort(key=lambda s: (-len(holds.get(s["id"], ())), count[s["id"]], s["index"]))
        bind[slot] = free[0]["uuid"]
    write_if_changed(bpath, "".join("%s|%s\n" % kv for kv in bind.items()))
    write_if_changed(os.path.join(sdir, "slot_space_idx"),
                     "".join("%s|%d|%s\n" % (k, byuuid[v]["index"], v) for k, v in bind.items()))
    tgt_s = byuuid[bind[slot]]
    tgt, tgt_id = tgt_s["index"], tgt_s["id"]
    head = "%s %s %s\n" % (tgt, cur, tgt_s["uuid"])

    # ── 2. the window ops ────────────────────────────────────────────────────
    T = zoomtiles.rects(sw, sh)
    mine, floaters = [], set()
    for m in members:
        if len(m) != 4:
            continue
        s_, app, pos, z = m
        names = set(owners.get(app, [app]))
        if "," in pos:
            floaters |= names
        if s_ == slot:
            mine.append((int(z) if z.isdigit() else 0, app, pos, names))
    if not any(app == "Fusion" for _, app, _, _ in mine):
        comps = set()               # companions only ride with a slot that has Fusion
    mine.sort()

    # Only windows on at least one desktop count: [] is minimized / hidden / ordered out.
    live = [w for w in ws if w["spaces"]]
    def sticky(w): return len(w["spaces"]) > 1
    def on_tgt(w): return tgt_id in w["spaces"] and not sticky(w)
    def area(w): return w["w"] * w["h"]

    pre, post, used, focus_app = [], [], set(), None
    for z, app, pos, names in mine:
        cand = [w for w in live if w["app"] in names and w["id"] not in used]
        if not cand:
            continue
        if "," in pos:                                     # floater: sticky, never moved
            pre += ["sticky %d" % w["id"] for w in cand if not sticky(w)]
            focus_app = app
            continue
        # A tile-sized window beats a palette that merely sits on the target desktop
        # (Fusion's canvas lives elsewhere while a small dialog is here — the old
        # on_tgt-first rank chose the palette and left the canvas stranded). Tile-sized
        # at ANY UI Zoom level (zoomtiles): a window last shown at another zoom is still
        # the app's real one — at 110% Chrome's 100%-sized window fit nothing, so its
        # 1396×89 bar on the target won, was framed to the tile, and the real window
        # stayed stranded on a free desktop, which a reset then made Chrome's own slot
        # (2026-10-20). For the same reason a real window beats a sliver on the target.
        def fits(w):
            return zoomtiles.fits(w["w"], w["h"], pos, sw, sh, sdir)
        w = max(cand, key=lambda w: (fits(w), area(w) > 600 * 400, on_tgt(w), area(w)))
        used.add(w["id"])
        # A sticky snapped window is unstuck, then always sent to the target: where
        # macOS drops it on unsticking is not ours to guess.
        if sticky(w):
            pre.append("sticky %d" % w["id"])
        if not on_tgt(w):
            pre.append("space %d %d" % (w["id"], tgt))
        # A drifted tile is re-set — through yabai, i.e. the app's Accessibility, so
        # never for a CAD app (a busy Fusion would stall yabai for everyone) and only
        # after the flip.
        if pos in T and w["app"] not in cad:
            x, y, ww, wh = T[pos]
            tb = titlebar.get(app, 0)
            if y == 0 and tb:       # title bar pushed above the screen (settings `titlebar`)
                y, wh = -tb, wh + tb
            if max(abs(w["x"] - x), abs(w["y"] - y), abs(w["w"] - ww), abs(w["h"] - wh)) > 8:
                post.append("frame %d %d %d %d %d" % (w["id"], x, y, ww, wh))
        focus_app = app

    # app → the window chosen for it, for realize_slot's fast path: a shared member's
    # window is moved straight from this cache before the flip, the plan only after.
    cache = dict(l.split("|", 1) for l in lines(os.path.join(sdir, "slot_winids")) if "|" in l)
    for z, app, pos, names in mine:
        hit = next((w for w in live if w["id"] in used and w["app"] in names), None)
        if hit:
            cache[app] = str(hit["id"])
    write_if_changed(os.path.join(sdir, "slot_winids"), "".join("%s|%s\n" % kv for kv in cache.items()))

    for w in live:                  # Fusion companions ride with Fusion, never sticky
        if w["app"] in comps:
            if sticky(w):
                pre.append("sticky %d" % w["id"])
            if not on_tgt(w):
                pre.append("space %d %d" % (w["id"], tgt))
    for w in live:                  # every recorded floater stays sticky
        if w["app"] in floaters and not sticky(w) and "sticky %d" % w["id"] not in pre:
            pre.append("sticky %d" % w["id"])

    # Another slot's window dropped on this desktop by its own app, not by slots:
    # Control Room (moveToActiveSpace) lands on whatever desktop is active when it
    # launches or leaves a full-screen Space, and then sat over the Claude pair. Only
    # an app snapped in exactly one slot (not this one), and only a window its tile's
    # size — that is unambiguously that slot's window. Sent home before the flip.
    key_of = {n: k for k, ns in owners.items() for n in ns}
    homes = {}
    for m in members:
        if len(m) == 4 and "," not in m[2] and m[0] in bind:
            homes.setdefault(key_of.get(m[1], m[1]), set()).add((m[0], m[2]))
    mine_apps = {app for _, app, _, _ in mine}
    for w in live:
        app = key_of.get(w["app"], w["app"])
        home = homes.get(app, set())
        if (w["id"] in used or not on_tgt(w) or app in mine_apps or len(home) != 1
                or w["app"] in floaters or w["app"] in comps):
            continue
        hslot, hpos = next(iter(home))
        if hpos not in T or bind[hslot] == tgt_s["uuid"]:
            continue
        if zoomtiles.fits(w["w"], w["h"], hpos, sw, sh, sdir):
            pre.append("evict %d %d" % (w["id"], byuuid[bind[hslot]]["index"]))

    # Keyboard focus. A floater you are typing in keeps it (it is on every desktop) —
    # the native-spaces form of op_nav's floater rule.
    front = next((w for w in ws if w.get("front")), None)
    if focus_app and not (front and front["app"] in floaters and sticky(front)):
        names = set(owners.get(focus_app, [focus_app]))
        # Only a real window elsewhere counts: Chrome keeps a 1303×89 bar on another
        # desktop (yabai can't even address it), which blocked every toggle to Chrome
        # — it stayed behind Safari on the target.
        elsewhere = [w for w in live if w["app"] in names and w["id"] not in used
                     and not sticky(w) and tgt_id not in w["spaces"]
                     and area(w) > 600 * 400]
        if not elsewhere:
            post.insert(0, "activate %s" % activate_as.get(focus_app, focus_app))
    return head + "\n".join(pre + post) + "\n"


def rebind(slot, sdir, wid, snap_text):
    """A window the scripting addition can't move (yabai: "could not locate the window")
    stays on its own desktop — so make that desktop the slot's. The slot already bound
    there (if any) takes the slot's old desktop. Returns "index uuid" or None."""
    try:
        snap = json.loads(snap_text)
        spaces, ws = snap["spaces"], snap["windows"]
    except Exception:
        return None
    w = next((w for w in ws if w["id"] == wid), None)
    if not w or len(w["spaces"]) != 1:
        return None
    dst = next((s for s in spaces if s["id"] == w["spaces"][0] and not s["fullscreen"]), None)
    if not dst:
        return None
    bpath = os.path.join(sdir, "slot_spaces")
    bind = dict(l.split("|", 1) for l in lines(bpath) if "|" in l)
    old = bind.get(slot)
    for k, v in list(bind.items()):
        if v == dst["uuid"] and k != slot:
            if old:
                bind[k] = old
            else:
                del bind[k]
    bind[slot] = dst["uuid"]
    byuuid = {s["uuid"]: s for s in spaces}
    write_if_changed(bpath, "".join("%s|%s\n" % kv for kv in bind.items()))
    write_if_changed(os.path.join(sdir, "slot_space_idx"),
                     "".join("%s|%d|%s\n" % (k, byuuid[v]["index"], v) for k, v in bind.items() if v in byuuid))
    return "%d %s" % (dst["index"], dst["uuid"])


if __name__ == "__main__":
    if sys.argv[1] == "--rebind":
        r = rebind(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.stdin.read())
        if r is None:
            sys.exit(1)
        print(r)
        sys.exit(0)
    out = plan(sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.stdin.read())
    if out is None:
        sys.exit(1)
    sys.stdout.write(out)
