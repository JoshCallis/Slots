"""zoomtiles.py — the 7 tiles at every UI Zoom level (slotlib.sh tile_for_geom's twin).

UI Zoom (ui_zoom.sh § Screen zoom) zooms the screen pinned top-left, so the screen
tiles are cut from is the top-left native/z, and its glide re-fits only the windows on
screen. Every other desktop keeps the tiles of the zoom it was last shown at until its
slot is revealed. A window that is no tile today but is one at another level is that
tile, not a floater; slotlib.sh zoom_tile_for_geom says why and in what order.

STATE_DIR/.screen_zoom (live: /tmp) holds the zoom; without it (no monitor, dry runs)
only today's tiles count.

The ONE Python copy of the tile rule (slotd, realize_plan and slotlib's inline Python
import it); bin/tiles.h is the C copy. slots/test_tiles.sh checks they all agree with
slotlib.sh pos_rect.
"""
import os

TILES = ("full", "left", "right", "top-left", "top-right", "bottom-left", "bottom-right")
TOL = 8
ZOOM_MIN_PCT, ZOOM_MAX_PCT, ZOOM_STEP_PCT = 100, 300, 5    # ui_zoom.sh's levels


def rects(sw, sh):
    """slotlib pos_rect for the 7 tiles of a SW×SH screen."""
    hw, hh = sw // 2, sh // 2
    lw = hw - 1                 # left-edge tiles inset 1px (slotlib.sh pos_rect)
    return {"full": (0, 0, sw, sh), "left": (0, 0, lw, sh), "right": (hw, 0, hw, sh),
            "top-left": (0, 0, lw, hh), "top-right": (hw, 0, hw, hh),
            "bottom-left": (0, hh, lw, hh), "bottom-right": (hw, hh, hw, hh)}


def zoom(sdir="/tmp"):
    try:
        with open(os.path.join(sdir, ".screen_zoom")) as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def other_screens(sw, sh, sdir="/tmp"):
    """The screen at every other UI Zoom level (100–300%, 5% steps), as slotlib's awk."""
    z = zoom(sdir)
    if z is None:
        return []
    nw, nh = int(sw * z + 0.5), int(sh * z + 0.5)
    return [(int(nw * 100 // p), int(nh * 100 // p))
            for p in range(ZOOM_MIN_PCT, ZOOM_MAX_PCT + 1, ZOOM_STEP_PCT)]


def near(a, b):
    return all(abs(p - q) <= TOL for p, q in zip(a, b))


def tile_of(rect, sw, sh, raw=None, sdir="/tmp"):
    """Tile name for RECT (x, y, w, h) on today's SW×SH screen, else at another zoom
    level (matched by RAW, the unclamped rect, when given), else ""."""
    now = rects(sw, sh)
    for t in TILES:
        if near(rect, now[t]):
            return t
    scr = other_screens(sw, sh, sdir)
    if not scr:
        return ""
    r = raw or rect
    for t in TILES:
        for s in scr:
            if near(r, rects(*s)[t]):
                return t
    return ""


def fits(w, h, pos, sw, sh, sdir="/tmp"):
    """Is a W×H window POS-sized today, or at another zoom level?"""
    if pos not in TILES:
        return False
    for s in [(sw, sh)] + other_screens(sw, sh, sdir):
        _, _, tw, th = rects(*s)[pos]
        if abs(w - tw) <= TOL and abs(h - th) <= TOL:
            return True
    return False


UI_ZOOM_LOCK = "/tmp/.ui_zoom.lock"


def busy(sdir="/tmp"):
    """slotlib.sh zoom_busy: is a UI Zoom glide moving windows (ui_zoom.sh holds its press
    lock until the glide lands, then rewrites .screen_zoom; 1 s more for the apps)?"""
    import fcntl
    import time
    zf = os.path.join(sdir, ".screen_zoom")
    try:
        landed = os.path.getmtime(zf)
    except OSError:
        return False
    try:
        fd = os.open(UI_ZOOM_LOCK, os.O_RDONLY)
    except OSError:
        fd = None
    if fd is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            return True
        finally:
            os.close(fd)
    return time.time() - landed < 1.0


def wait(sdir="/tmp", secs=2.0):
    """→ True once no glide is moving windows, False if one still is after SECS."""
    import time
    end = time.time() + secs
    while busy(sdir):
        if time.time() >= end:
            return False
        time.sleep(0.1)
    return True
