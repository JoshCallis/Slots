"""slotd.py — the slot engine's switch path, resident (native-spaces mode only).

A slot switch through slotlib.sh pays ~100-150 ms before anything moves: a bash
start-up, the settings cache, and dozens of awk/grep/cat forks to read and rewrite
six small state files, then a `yabai -m` process per window command (~25 ms each).
This daemon keeps that work in one long-lived process: the same files, read and
rewritten in-process (~1 ms), and yabai spoken to over its socket (~2 ms). The
flip itself is unchanged.

It is a PORT of the hot ops, not a new engine. slotlib.sh stays the engine:
  * it handles only `goto` (goto_app.sh's common case), `navapp`, `nav`,
    `spacesync`, `toggle`, and `activate` / `focus` (slot_activate.sh / focus.sh:
    the floater branch, Control Room's toggle), and inside those only the branches
    ported here. Anything else — an unassigned canon app, a floater with no window,
    a companion that would have to be launched, a
    slot with no cached desktop, the legacy single-desktop mode, the off switch —
    answers FALLBACK *before touching anything*, and the caller runs `bash slotlib.sh <op>` exactly as before;
  * state stays in the /tmp/slot_* files (re-read every op, so nothing can drift),
    under the same lock file, so slotlib's own ops (reconcile, appterm, snap, …)
    interleave with it safely;
  * an op is computed in memory and written only once it is known to succeed, so
    a FALLBACK half-way leaves no trace.

Every function below mirrors the slotlib.sh function of the same name. Change one,
change the other — slots/test_slotd.sh diffs the two engines on dry runs.

    slotd.py                    serve on /tmp/slotd.sock (launchd: com.josh.slotd)
    slotd.py --once OP ARG...   run one op in this process (tests; honours the
                                same SLOT_* env hooks as slotlib.sh)

Wire format (bin/slotc.c): the request is the args, NUL-terminated, then EOF; the
reply is one status byte ('0' done, 'F' fallback, 'X' dropped) and the op's stdout.
slotc puts "\\x01<SLOT_GEN>\\x01<its clock, ms>" first: a jump (JUMP_OPS) is DROPPED —
nothing done, the caller does nothing either — once it is DEADLINE_S past the key
press or a newer press has rewritten JUMP_GEN (slots/jump_stamp.sh).
"""
import ctypes
import json
import os
import pwd
import re
import socket
import struct
import subprocess
import sys
import threading
import time

REPO = "/Users/josh/Code/Scripts"
SLOTS = REPO + "/slots"
SLOTLIB = SLOTS + "/slotlib.sh"
SETTINGS = REPO + "/config/settings.json"
OFF_FLAG = REPO + "/config/slots_off"
SPACES_FLAG = REPO + "/config/slots_spaces"
SOCK = "/tmp/slotd.sock"
DLOG = "/tmp/slotd.log"
BIN = "/Users/josh/bin"
COH_FULLSCREEN = REPO + "/max/coherence_fullscreen.sh"
COH_HOME = REPO + "/max/coherence_home.py"
# app_resolve.sh's open_coherence for app $0 (launch / back to full screen), in the
# background; argv[0] names it for coh_opening's pgrep.
COH_OPEN = ('exec -a open_coherence /bin/bash -c \'source "%s/app_resolve.sh"; resolve_app "$0"; '
            '"%s/max/vm.sh" ensure; open_coherence\' "$0"' % (REPO, REPO))
OP_TS = "/tmp/.slot_op_ts"
JUMP_GEN = "/tmp/slot_jump_gen"   # the latest key press's token (slots/jump_stamp.sh)
JUMP_OPS = ("goto", "navapp", "nav", "toggle", "activate", "focus", "swipe", "gridtoggle")
DEADLINE_S = 3.0                  # a jump not done this long after its key press is dropped

sys.path.insert(0, SLOTS)
import realize_plan  # noqa: E402
import zoomtiles  # noqa: E402
import grid  # noqa: E402

TILES = zoomtiles.TILES


class Fallback(Exception):
    """Hand this op to slotlib.sh untouched."""


class Dropped(Exception):
    """A jump past its deadline, or superseded by a newer key press: do nothing."""


# The deadline of the jump being served (None: no deadline). yabai() caps every
# call by it and sends nothing once it has passed — yabai queues requests, so a
# command sent to a stuck yabai would still fire seconds later.
_deadline = None


def dlog(msg):
    t = time.time()
    try:
        with open(DLOG, "a") as f:
            f.write("%s.%03d %s\n" % (time.strftime("%H:%M:%S", time.localtime(t)), int(t * 1000) % 1000, msg))
    except OSError:
        pass


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except (FileNotFoundError, NotADirectoryError):
        return None


def file_lines(path):
    """A file's lines as awk/grep see them (a missing file → none)."""
    t = read_text(path)
    if not t:
        return []
    if t.endswith("\n"):
        t = t[:-1]
    return t.split("\n")


def cat(path):
    """$(cat path): the content minus trailing newlines, '' when missing."""
    t = read_text(path)
    return t.rstrip("\n") if t else ""


def write_atomic(path, text):
    tmp = path + ".tmp.slotd"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def touch(path):
    try:
        with open(path, "a"):
            pass
        os.utime(path, None)
    except OSError:
        pass


def fld(line, i):
    p = line.split("|")
    return p[i] if i < len(p) else ""


_AWKNUM = re.compile(r"\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?")
_SORTNUM = re.compile(r"\s*(-?\d*\.?\d*)")


def awk_num(s):                 # awk's `$4+0`
    m = _AWKNUM.match(s)
    return float(m.group(0)) if m else 0.0


def sort_num(s):                # sort -n's key
    m = _SORTNUM.match(s)
    try:
        return float(m.group(1))
    except (ValueError, AttributeError):
        return 0.0


# ── running processes (libproc — no ps / pgrep fork) ─────────────────────────
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


def proc_names():
    n = _libproc.proc_listallpids(None, 0)
    buf = (ctypes.c_int * (n + 256))()
    n = _libproc.proc_listallpids(buf, ctypes.sizeof(buf))
    nb = ctypes.create_string_buffer(256)
    out, pid_of = set(), {}
    for i in range(max(n, 0)):
        if _libproc.proc_name(buf[i], nb, 256) > 0:
            name = nb.value.decode("utf-8", "replace")
            out.add(name)
            pid_of[name] = buf[i]
    _PID_OF.clear()
    _PID_OF.update(pid_of)
    return out


_PID_OF = {}                     # name → a pid that had it, as of the last proc_names()
_PNB = ctypes.create_string_buffer(256)


def proc_any(pred):
    """→ True if a running process's name satisfies PRED. proc_names() walks every pid
    (2 ms idle, 10-20 ms mid-gesture); a hit is first looked for at the pid last seen
    under a matching name, its name re-read now — so True is always live, and only a
    miss (an app that quit, or never ran) pays the full walk."""
    for name, pid in list(_PID_OF.items()):
        if pred(name) and _libproc.proc_name(pid, _PNB, 256) > 0 \
                and pred(_PNB.value.decode("utf-8", "replace")):
            return True
    return any(pred(n) for n in proc_names())


# ── yabai over its socket (the `yabai -m` client is ~25 ms of process start) ─
_YSOCK = "/tmp/yabai_%s.socket" % pwd.getpwuid(os.getuid()).pw_name


def yabai(*args, timeout=10.0):
    """`yabai -m ARGS`; returns (ok, reply). Errors are swallowed like `2>/dev/null`."""
    msg = b"".join(str(a).encode() + b"\0" for a in args) + b"\0"
    if _deadline is not None:
        left = _deadline - time.time()
        if left <= 0:
            dlog("yabai %s: skipped, past the jump's deadline" % " ".join(map(str, args)))
            return False, b""
        timeout = min(timeout, max(left, 0.25))
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(_YSOCK)
        s.sendall(struct.pack("i", len(msg)) + msg)
        s.shutdown(socket.SHUT_WR)
        out = b""
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
        s.close()
    except OSError as e:
        dlog("yabai %s: %s" % (" ".join(map(str, args)), e))
        return False, b""
    if out[:1] == b"\x07":
        return False, out[1:]
    return True, out


# ── window server, in-process (space_query / win_list without the fork) ──────
# The floater ops read windows here: ~5 ms on a connection opened once, against
# ~40 ms per space_query / win_list start-up. CoreGraphics, never Accessibility, so
# a busy Fusion can't hold it (see space_query.m).
_CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_vp, _u32 = ctypes.c_void_p, ctypes.c_uint32
for _fn, _res, _args in (
        (_CF.CFArrayGetCount, ctypes.c_long, [_vp]),
        (_CF.CFArrayGetValueAtIndex, _vp, [_vp, ctypes.c_long]),
        (_CF.CFArrayCreate, _vp, [_vp, _vp, ctypes.c_long, _vp]),
        (_CF.CFDictionaryGetValue, _vp, [_vp, _vp]),
        (_CF.CFStringCreateWithCString, _vp, [_vp, ctypes.c_char_p, _u32]),
        (_CF.CFStringGetCString, ctypes.c_bool, [_vp, ctypes.c_char_p, ctypes.c_long, _u32]),
        (_CF.CFNumberGetValue, ctypes.c_bool, [_vp, ctypes.c_int, _vp]),
        (_CF.CFNumberCreate, _vp, [_vp, ctypes.c_int, _vp]),
        (_CF.CFBooleanGetValue, ctypes.c_bool, [_vp]),
        (_CF.CFRelease, None, [_vp]),
        (_CG.CGWindowListCopyWindowInfo, _vp, [_u32, _u32]),
        (_CG.CGSMainConnectionID, ctypes.c_int, []),
        (_CG.CGSGetActiveSpace, ctypes.c_uint64, [ctypes.c_int]),
        (_CG.CGSCopyManagedDisplaySpaces, _vp, [ctypes.c_int]),
        (_CG.CGSCopySpacesForWindows, _vp, [ctypes.c_int, ctypes.c_int, _vp])):
    _fn.restype, _fn.argtypes = _res, _args
_UTF8, _SINT64, _DOUBLE = 0x08000100, 4, 13
_K = {k: _CF.CFStringCreateWithCString(None, k.encode(), _UTF8) for k in (
    "kCGWindowLayer", "kCGWindowOwnerName", "kCGWindowNumber", "kCGWindowBounds",
    "kCGWindowIsOnscreen", "kCGWindowAlpha", "X", "Y", "Width", "Height",
    "Spaces", "id64", "ManagedSpaceID", "type")}
_ARRAY_CB = ctypes.addressof(ctypes.c_char.in_dll(_CF, "kCFTypeArrayCallBacks"))
_CID = []


def _cid():
    if not _CID:
        _CID.append(_CG.CGSMainConnectionID())
    return _CID[0]


def _cfnum(d, k, typ=_SINT64):
    v = _CF.CFDictionaryGetValue(d, _K[k])
    if not v:
        return None
    out = ctypes.c_double() if typ == _DOUBLE else ctypes.c_int64()
    _CF.CFNumberGetValue(v, typ, ctypes.byref(out))
    return out.value


def _cfnums(arr):
    out = []
    for i in range(_CF.CFArrayGetCount(arr) if arr else 0):
        v = ctypes.c_int64()
        _CF.CFNumberGetValue(_CF.CFArrayGetValueAtIndex(arr, i), _SINT64, ctypes.byref(v))
        out.append(v.value)
    return out


def ws_windows(onscreen_only=False, owners=None):
    """CGWindowList, front to back: dicts id app layer alpha x y w h onscreen
    (only OWNERS' windows when given — the rest aren't decoded)."""
    arr = _CG.CGWindowListCopyWindowInfo((1 if onscreen_only else 0) | 16, 0)
    if not arr:
        return []
    out, buf = [], ctypes.create_string_buffer(512)
    try:
        for i in range(_CF.CFArrayGetCount(arr)):
            d = _CF.CFArrayGetValueAtIndex(arr, i)
            s = _CF.CFDictionaryGetValue(d, _K["kCGWindowOwnerName"])
            b = _CF.CFDictionaryGetValue(d, _K["kCGWindowBounds"])
            if not s or not b or not _CF.CFStringGetCString(s, buf, 512, _UTF8):
                continue
            app = buf.value.decode("utf-8", "replace")
            if owners is not None and app not in owners:
                continue
            o = _CF.CFDictionaryGetValue(d, _K["kCGWindowIsOnscreen"])
            out.append({"id": _cfnum(d, "kCGWindowNumber"), "app": app,
                        "layer": _cfnum(d, "kCGWindowLayer"), "alpha": _cfnum(d, "kCGWindowAlpha", _DOUBLE),
                        "x": round(_cfnum(b, "X", _DOUBLE) or 0), "y": round(_cfnum(b, "Y", _DOUBLE) or 0),
                        "w": round(_cfnum(b, "Width", _DOUBLE) or 0), "h": round(_cfnum(b, "Height", _DOUBLE) or 0),
                        "onscreen": bool(o) and _CF.CFBooleanGetValue(o)})
    finally:
        _CF.CFRelease(arr)
    return out


def ws_spaces_of(wid):
    """The desktop ids a window is on (several = sticky; none = hidden/minimized)."""
    n = ctypes.c_int64(wid)
    num = _CF.CFNumberCreate(None, _SINT64, ctypes.byref(n))
    arr = _CF.CFArrayCreate(None, ctypes.byref(_vp(num)), 1, _ARRAY_CB)
    res = _CG.CGSCopySpacesForWindows(_cid(), 7, arr)
    out = _cfnums(res)
    for r in (res, arr, num):
        if r:
            _CF.CFRelease(r)
    return out


def ws_active():
    """(id, full-screen?) of the desktop being shown."""
    cid = _cid()
    sid = _CG.CGSGetActiveSpace(cid)
    full = False
    disps = _CG.CGSCopyManagedDisplaySpaces(cid)
    try:
        for i in range(_CF.CFArrayGetCount(disps) if disps else 0):
            sps = _CF.CFDictionaryGetValue(_CF.CFArrayGetValueAtIndex(disps, i), _K["Spaces"])
            for j in range(_CF.CFArrayGetCount(sps) if sps else 0):
                s = _CF.CFArrayGetValueAtIndex(sps, j)
                if (_cfnum(s, "id64") or _cfnum(s, "ManagedSpaceID")) == sid:
                    full = _cfnum(s, "type") == 4
    finally:
        if disps:
            _CF.CFRelease(disps)
    return sid, full


def remap_in_view():
    """remap_open.sh's VISIBLE test: Control Room's window is on screen and nothing
    real (not borders, not transparent, not Dock level or above) overlaps it."""
    ws = ws_windows(onscreen_only=True)
    i = next((k for k, w in enumerate(ws) if w["app"] == "Remap" and w["layer"] == 0 and w["w"] > 100), -1)
    if i < 0:
        return False
    r = ws[i]
    for w in ws[:i]:
        if w["layer"] is None or w["layer"] < 0 or w["layer"] >= 20 or not w["alpha"] \
                or w["app"] in ("borders", "Remap"):
            continue
        ox = min(r["x"] + r["w"], w["x"] + w["w"]) - max(r["x"], w["x"])
        oy = min(r["y"] + r["h"], w["y"] + w["h"]) - max(r["y"], w["y"])
        if ox > 4 and oy > 4:
            return False
    return True


# ── settings (config/settings.json, read as gen_settings.py compiles it) ─────
class Settings:
    def __init__(self):
        self.stamp = None
        self.ok = False

    def norm_alias(self, s):
        return s.lower().replace(" ", "").replace("-", "")

    def load(self):
        try:
            st = os.stat(SETTINGS)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            stamp = None
        if self.ok and stamp == self.stamp:
            return
        try:
            with open(SETTINGS) as f:
                cfg = json.load(f)
            apps = cfg["apps"]
            canon, cad, normalize, open_name, alt_names, resolve = [], [], {}, {}, {}, {}
            for a in apps:
                key = a["key"]
                opn = a.get("open", key)
                act = a.get("activate", key)
                owners = [key]
                for n in [opn, act] + a.get("alt_names", []):
                    if n not in owners:
                        owners.append(n)
                aliases = {self.norm_alias(key), self.norm_alias(opn)}
                aliases.update(self.norm_alias(x) for x in a.get("aliases", []))
                if a.get("canonical"):
                    canon.append(key)
                if "cad" in a:
                    cad.append(key)
                for n in owners:                    # case: first pattern wins
                    if n != key:
                        normalize.setdefault(n, key)
                if act != key:
                    open_name.setdefault(key, act)
                if len(owners) > 1:
                    alt_names.setdefault(key, owners)
                for al in aliases:
                    resolve.setdefault(al, (opn, key, owners, a.get("special", "")))
            layouts = []
            for l in cfg.get("place_layouts", []):
                layouts.append((l["primary"], ";".join("%s:%s" % (m["app"], m["pos"]) for m in l["members"])))
        except Exception as e:
            # slotlib keeps its last-good cache on a bad edit; so does this.
            dlog("settings.json unreadable (%s) — %s" % (e, "keeping last-good" if self.ok else "falling back"))
            if not self.ok:
                raise Fallback("settings")
            return
        self.apps, self.layouts, self.cad_apps = canon, layouts, " ".join(cad)
        self.normalize, self.open_name, self.alt_names, self.resolve = normalize, open_name, alt_names, resolve
        self.stamp, self.ok = stamp, True


SETTINGS_OBJ = Settings()


# ── one op ────────────────────────────────────────────────────────────────────
class Op:
    def __init__(self, env, settings):
        self.env = env
        settings.load()
        self.st = settings
        sdir = env.get("SLOT_STATE_DIR") or "/tmp"
        self.sdir = sdir
        self.dry = bool(env.get("SLOT_DRYRUN"))
        self.logpath = env.get("SLOT_LOG") or "/tmp/slots.log"
        self.SEQ = sdir + "/slot_seq"
        self.MEM = sdir + "/slot_members"
        self.LP = sdir + "/app_lastpos"
        self.CUR = sdir + "/current_slot"
        self.PREVF = sdir + "/prev_slot"
        self.MRU = sdir + "/app_mru"
        self.ZC = sdir + "/z_counter"
        self.DIMS = sdir + "/screen_dims"
        self.SPB = sdir + "/slot_spaces"
        self.ACTIVE_DESK = sdir + "/.slot_active_desk"
        self.LOCKF = sdir + "/.slot_lock"
        layouts = self.st.layouts
        if "SLOT_LAYOUTS" in env:
            layouts = [tuple(l.split("|", 1)) if "|" in l else (l, "")
                       for l in env["SLOT_LAYOUTS"].split("\n") if l]
        self.layouts = layouts
        self.apps = env["SLOT_APPS"].split() if env.get("SLOT_APPS") else self.st.apps
        # state: read by reload_state() once the lock is held, written back by commit()
        self.mem, self.lp, self.cur, self.zc, self.mru, self.prev = [], [], "", None, [], ""
        self.seq_new = None              # seq_set's, written by commit()
        self.GACT = sdir + "/slot_grid_active"
        self.gact = {}                   # the grid's picks (grid.read_active), written by commit()
        self.dirty = set()
        self.logs, self.out, self.realizes, self.reconciles = [], [], [], []
        self.spawns = []                 # commands run after the reply (spawn_reconciles)
        self.floats = []                 # (app, windows) raised after the commit (raise_floater)
        self._wins = {}                  # app_wins, read once per op
        self.locked = False
        self._running = None
        self.deadline = None             # a jump's: serve() sets it (DEADLINE_S after the press)
        self.gen = ""                    # the jump's key-press token (JUMP_GEN)

    def still_wanted(self, where):
        """Raise Dropped if a newer jump was pressed, or this one is past its deadline."""
        if self.gen and cat(JUMP_GEN) != self.gen:
            raise Dropped("superseded by a newer jump, %s" % where)
        if self.deadline is not None and time.time() >= self.deadline:
            raise Dropped("past its %gs deadline, %s" % (DEADLINE_S, where))

    # ── basics ────────────────────────────────────────────────────────────────
    def log(self, msg):
        self.logs.append("[%s] [slots] %s\n" % (time.strftime("%H:%M:%S"), msg))

    def log_now(self, msg):
        try:
            with open(self.logpath, "a") as f:
                f.write("[%s] [slots] %s\n" % (time.strftime("%H:%M:%S"), msg))
        except OSError:
            pass

    def spaces_on(self):
        if self.dry:
            return bool(self.env.get("SLOT_SPACES"))
        return os.path.exists(SPACES_FLAG)

    def normalize(self, n):
        return self.st.normalize.get(n, n)

    def alt_names(self, app):
        return self.st.alt_names.get(app, [app])

    # ── sequence / current ────────────────────────────────────────────────────
    def seq_all(self):
        return self.seq_new if self.seq_new is not None else file_lines(self.SEQ)

    def seq_set(self, seq):
        """The grid's only sequence edits: a cell back in, an emptied off-grid slot out."""
        self.seq_new = list(seq)
        self.dirty.add("seq")

    def seq_read(self):
        return [l for l in self.seq_all() if l != ""]

    def seq_index(self, s):
        seq = self.seq_read()
        return seq.index(s) if s in seq else -1

    def get_current(self):
        return self.cur

    def set_current(self, s):
        self.cur = s
        self.dirty.add("cur")

    def goto_slot(self, frm, to):
        if to != frm:
            self.prev = frm
            self.dirty.add("prev")
        self.set_current(to)

    # ── membership ────────────────────────────────────────────────────────────
    def next_z(self):
        t = (self.zc or "").strip() or "0"
        if not re.fullmatch(r"\d+", t):
            raise Fallback("z_counter %r" % t)
        n = int(t) + 1
        self.zc = "%d\n" % n
        self.dirty.add("zc")
        return n

    def set_member(self, slot, app, pos):
        z = self.next_z()
        self.mem = [l for l in self.mem if not (fld(l, 0) == slot and fld(l, 1) == app)]
        self.mem.append("%s|%s|%s|%d" % (slot, app, pos, z))
        self.dirty.add("mem")

    def remove_member(self, slot, app):
        self.mem = [l for l in self.mem if not (fld(l, 0) == slot and fld(l, 1) == app)]
        self.dirty.add("mem")

    def set_lastpos(self, app, pos):
        self.lp = [l for l in self.lp if fld(l, 0) != app] + ["%s|%s" % (app, pos)]
        self.dirty.add("lp")

    def members_of(self, slot):
        rows = [(fld(l, 1), fld(l, 2), fld(l, 3)) for l in self.mem if fld(l, 0) == slot]
        rows.sort(key=lambda r: (sort_num(r[2]), "|".join(r)))
        return rows

    def focus_of(self, slot):
        a, z, n = "", 0.0, 0
        for l in self.mem:
            if fld(l, 0) == slot:
                v = awk_num(fld(l, 3))
                if n == 0 or v > z:
                    z, a = v, fld(l, 1)
                n += 1
        return a

    def is_snapped_member(self, slot, app):
        return any(fld(l, 0) == slot and fld(l, 1) == app and fld(l, 2) in TILES for l in self.mem)

    def app_fits_at(self, app, want):
        for l in self.mem:
            if fld(l, 1) == app:
                p = fld(l, 2)
                if p and p != want:
                    return False
        return True

    # ── geometry ──────────────────────────────────────────────────────────────
    def screen_dims(self):
        t = cat(self.DIMS).split()
        if len(t) < 2:
            raise Fallback("no screen_dims cache")
        return t[0], t[1]

    def pos_rect(self, p):
        if "," in p:
            v = p.replace(",", " ").split(None, 3)
        else:
            sw, sh = (int(x) for x in self.screen_dims())
            v = zoomtiles.rects(sw, sh).get(p)
            if v is None:
                return None
            v = [str(x) for x in v]
        v = list(v) + [""] * (4 - len(v))
        return v if v[0] != "" else None

    def pos_overlaps(self, a, b):
        if "," in a or "," in b:
            ra, rb = self.pos_rect(a), self.pos_rect(b)
            if ra is None or rb is None:
                return False
            try:
                ax, ay, aw, ah = (int(x) if x else 0 for x in ra)
                bx, by, bw, bh = (int(x) if x else 0 for x in rb)
            except ValueError:
                return False
            return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
        if a == b or a == "full" or b == "full":
            return True
        if a == "left" and b in ("top-left", "bottom-left"):
            return True
        return a == "right" and b in ("top-right", "bottom-right")

    # ── running apps / recency ────────────────────────────────────────────────
    def running_list(self):
        """pick_recent's ps list: SLOT_RUNNING, else live (not in a dry run)."""
        if "SLOT_RUNNING" in self.env:
            v = self.env["SLOT_RUNNING"]
            return set(v.split("\n")) if v else None
        if self.dry:
            return None
        if self._running is None:
            self._running = proc_names()
        return self._running

    def app_running(self, app, tokens):
        return any(n and n in tokens for n in self.alt_names(app))

    def pick_recent(self, cands):
        if len(cands) == 1:
            return cands[0]
        running = self.running_list()
        best, bestk = "", None
        for i, a in enumerate(cands):
            r = 0
            if running:
                r = 0 if self.app_running(a, running) else 1
            rank = next((k + 1 for k, l in enumerate(self.mru) if l == a), 999)
            k = (r, rank, i)
            if bestk is None or k < bestk:
                bestk, best = k, a
        return best

    def ensure_running(self, app):
        if self.dry:
            self.log("DRY ensure-running %s" % app)
            return
        names = set(n for n in self.alt_names(app) if n)
        if self.spaces_on() and proc_any(lambda p: p in names):
            return
        raise Fallback("would launch %s" % app)

    def mru_touch(self, a):
        if not a:
            return
        self.mru = ([a] + [l for l in self.mru if l != a])[:50]
        self.dirty.add("mru")

    def switched(self, prev, new):
        self.out.append("%s|%s" % (prev, new))
        self.mru_touch(new)

    # ── layouts ───────────────────────────────────────────────────────────────
    def layout_for(self, app):
        return next((spec for prim, spec in self.layouts if prim == app), "")

    @staticmethod
    def toks(spec):
        t = spec.split(";")
        if t and t[-1] == "":
            t.pop()
        return [(tok.rsplit(":", 1)[0], tok.rsplit(":", 1)[-1]) for tok in t]

    def spec_pos(self, spec, app):
        return next((pos for a, pos in self.toks(spec) if a == app), "")

    def layout_alt_picks(self, A):
        spec = self.layout_for(A)
        if not spec:
            return []
        toks, poss, xpos = self.toks(spec), [], ""
        for app, pos in toks:
            if app == A:
                xpos = pos
            if pos not in poss:
                poss.append(pos)
        picks = []
        for p in poss:
            if p == xpos:
                continue
            alts, cands = [], []
            for app, pos in toks:
                if pos == p and app != A:
                    alts.append(app)
                    if self.app_fits_at(app, pos):
                        cands.append(app)
            if len(alts) > 1 and cands:
                picks.append((p, self.pick_recent(cands), alts))
        return picks

    def alt_at(self, slot, pos, alts):
        for l in self.mem:
            if fld(l, 0) == slot and fld(l, 2) == pos and fld(l, 1) in alts:
                return fld(l, 1)
        return ""

    def apply_alt_picks(self, slot, picks):
        for p, w, alts in picks:
            occ = self.alt_at(slot, p, alts)
            if not occ or occ == w:
                continue
            self.ensure_running(w)
            self.remove_member(slot, occ)
            self.set_member(slot, w, p)
            self.set_lastpos(w, p)
            self.log("layout alt: %s %s %s → %s (switched to more recently)" % (slot, p, occ, w))

    def fill_layout_companions(self, slot, A, apos):
        spec = self.layout_for(A)
        if not spec or self.spec_pos(spec, A) != apos:
            return
        toks, poss = self.toks(spec), []
        for _, pos in toks:
            if pos not in poss:
                poss.append(pos)
        for p in poss:
            if p == apos:
                continue
            if any(m and m != A and self.pos_overlaps(p, mpos) for m, mpos, _ in self.members_of(slot)):
                continue
            cands = [app for app, pos in toks if pos == p and app != A and self.app_fits_at(app, pos)]
            if not cands:
                continue
            w = self.pick_recent(cands)
            self.ensure_running(w)
            self.set_member(slot, w, p)
            self.set_lastpos(w, p)
            self.log("layout refill: %s %s ← %s (companion missing from %s's space)" % (slot, p, w, A))

    # ── native spaces ─────────────────────────────────────────────────────────
    def active_desk(self):
        u = cat(self.ACTIVE_DESK)
        if not u:
            try:
                r = subprocess.run([BIN + "/space_query", "active"], capture_output=True, text=True, timeout=5)
                u = r.stdout.rstrip("\n")
                u = u.split(" ", 1)[1] if " " in u else u
            except (OSError, subprocess.SubprocessError):
                u = ""
            if u:
                write_atomic(self.ACTIVE_DESK, u + "\n")
        return u

    def slot_of_active_space(self):
        uuid = self.active_desk()
        if not uuid:
            return ""
        seq = self.seq_all()
        for l in file_lines(self.SPB):
            s, _, u = l.partition("|")
            if u == uuid and s in seq:
                return s
        return ""

    def spaces_follow(self):
        if not self.spaces_on():
            return
        here, cur = self.slot_of_active_space(), self.get_current()
        if here and here != cur:
            self.goto_slot(cur, here)
            self.log("spacesync: desktop switched natively → current %s → %s" % (cur, here))

    def do_restore(self, slot):
        self.realizes.append(slot)

    def reconcile_left(self, slot, excl=""):
        self.reconciles.append((slot, excl))

    # ── the ops ───────────────────────────────────────────────────────────────
    def op_nav(self, d_arg):
        if not re.fullmatch(r"[+-]?\d+", d_arg):
            raise Fallback("nav %r" % d_arg)
        seq = self.seq_read()
        n = len(seq)
        if n == 0:
            raise Fallback("empty seq")
        cur = self.get_current()
        d = int(d_arg[1:] if d_arg.startswith("+") else d_arg)
        here = self.slot_of_active_space()
        if not here:
            self.log("nav %s: off-slot desktop → back to %s" % (d_arg, cur))
            self.do_restore(cur)
            f = self.focus_of(cur)
            self.switched(f, f)
            return
        if here != cur:
            self.goto_slot(cur, here)
            cur = here
        prevfocus = self.focus_of(cur)
        frm = cur
        idx = self.seq_index(cur)
        if idx < 0:
            idx = 0
        tgt = seq[((idx + d) % n + n) % n]
        if tgt == frm:
            self.set_current(frm)
            self.log("nav %s: staying on %s" % (d_arg, frm))
            self.do_restore(frm)
            self.out.append("%s|%s" % (prevfocus, prevfocus))
            return
        self.goto_slot(frm, tgt)
        newfocus = self.focus_of(tgt)
        cads = " %s " % self.st.cad_apps
        cad_in_tgt = next((fld(l, 1) for l in self.mem
                           if fld(l, 0) == tgt and (" %s " % fld(l, 1)) in cads), "")
        if cad_in_tgt:
            newfocus = cad_in_tgt
        self.log("nav %s: %s(%s) → %s(%s)" % (d_arg, frm, prevfocus, tgt, newfocus))
        self.do_restore(tgt)
        self.switched(prevfocus, newfocus)
        self.reconcile_left(frm)

    def op_navapp(self, arg):
        A = self.normalize(arg)
        if self.grid_navapp(A):
            return
        seq = self.seq_read()
        n = len(seq)
        if n == 0:
            raise Fallback("empty seq")
        cur = self.get_current()
        idx = self.seq_index(cur)
        if idx < 0:
            idx = 0
        if self.is_snapped_member(cur, A):
            # slotlib reconciles cur (failsafe_adopt_snapped) synchronously first; here
            # that's the deferred reconcile_slot instead, so the hot path stays in-process
            # (from 3ds Max's desktop, "current" is still the slot we left — this branch).
            prevfocus = self.focus_of(cur)
            posA = next((fld(l, 2) for l in self.mem if fld(l, 0) == cur and fld(l, 1) == A), "")
            self.fill_layout_companions(cur, A, posA)
            self.set_member(cur, A, posA)
            self.log("navapp %s: already snapped in current %s → focus in place (no jump)" % (A, cur))
            self.do_restore(cur)
            self.switched(prevfocus, A)
            self.reconcile_left(cur)
            return
        picks = self.layout_alt_picks(A)
        tgt, tidx = "", -1
        if picks:
            for i in range(1, n + 1):
                j = (idx + i) % n
                if not self.is_snapped_member(seq[j], A):
                    continue
                if all(self.alt_at(seq[j], p, alts) == w for p, w, alts in picks):
                    tgt, tidx = seq[j], j
                    break
        if not tgt:
            snapped_in = set(fld(l, 0) for l in self.mem if fld(l, 1) == A and fld(l, 2) in TILES)
            for i in range(1, n + 1):
                j = (idx + i) % n
                if seq[j] in snapped_in:
                    tgt, tidx = seq[j], j
                    break
        if not tgt:
            # Snapped nowhere: a non-canon app is a floater, raised in the current
            # slot; a canon app is never one — with no slot it is placeapp's (slotlib).
            if A in self.apps:
                raise Fallback("%s snapped nowhere" % A)
            self.float_up(cur, A, "navapp %s: floater → raise only in current slot %s (scene untouched)" % (A, cur))
            return
        prevfocus = self.focus_of(cur)
        posA = next((fld(l, 2) for l in self.mem if fld(l, 0) == tgt and fld(l, 1) == A), "")
        if picks:
            self.apply_alt_picks(tgt, picks)
        self.fill_layout_companions(tgt, A, posA)
        self.set_member(tgt, A, posA)
        self.goto_slot(cur, tgt)
        self.log("navapp %s: %s[%d] → %s[%d], focusing %s" % (A, cur, idx, tgt, tidx, A))
        self.do_restore(tgt)
        self.switched(prevfocus, A)
        self.reconcile_left(cur, A)

    def op_goto(self, arg):
        """goto_app.sh up to its navapp, for the common case only (see its header)."""
        key = arg.lower().replace(" ", "").replace("-", "")
        r = self.st.resolve.get(key)
        if not r:
            raise Fallback("unknown app %r" % arg)
        _open, slot_name, owners, special = r
        if special == "controlroom":
            return self.op_controlroom()
        if special in ("coherence", "parallels", "explorer"):
            raise Fallback("special %s" % special)
        # ensure_app_window: `pgrep -x` (p_comm, 16 chars) for "running", then a
        # slot member → done; a non-canon app with a window on some desktop, or with
        # none at all (float_up reopens one) → done (navapp raises it as a floater);
        # anything else is goto_app.sh's own path.
        want = set(o[:16] for o in owners)
        if not proc_any(lambda p: p[:16] in want):
            raise Fallback("%s not running" % slot_name)
        if not any(fld(l, 1) == slot_name for l in self.mem) and \
                slot_name not in grid.grid_apps(self.grid_cfg()):
            if slot_name in self.apps or self.dry or not (
                    self.has_window(slot_name) or self.reopen_cmd(slot_name)):
                raise Fallback("%s not a slot member" % slot_name)
        self.op_navapp(slot_name)

    def op_focus(self, arg):
        """focus.sh up to its slot_activate.sh, for a running app with a window."""
        key = arg.lower().replace(" ", "").replace("-", "")
        r = self.st.resolve.get(key)
        _open, slot_name, owners, special = r or (arg, arg, [arg], "")
        if special == "controlroom":
            return self.op_controlroom()
        if special in ("coherence", "parallels", "explorer"):
            raise Fallback("special %s" % special)
        want = set(o[:16] for o in owners)
        if not proc_any(lambda p: p[:16] in want):
            raise Fallback("%s not running" % slot_name)
        self.op_activate(slot_name)

    def op_activate(self, arg, make=None):
        """slotlib's op_activate, FLOATER branch only (a snapped reveal, a live window
        sitting on a tile, a canon app → FALLBACK). The current slot's reconcile, which
        slotlib runs first, is deferred (reconcile_left) as in navapp. MAKE: float_up's."""
        A = self.normalize(arg)
        cur = self.get_current()
        if A in self.apps:
            raise Fallback("activate %s: canon, never a floater" % A)
        if not any(fld(l, 0) == cur and fld(l, 1) == A for l in self.mem) and \
                any(fld(l, 1) == A and fld(l, 2) == "full" for l in self.mem):
            raise Fallback("activate %s: has its own space" % A)   # slotlib → navapp
        pos = next((fld(l, 2) for l in self.mem if fld(l, 0) == cur and fld(l, 1) == A), "")
        if pos in TILES:
            raise Fallback("activate %s: snapped member of %s" % (A, cur))
        if not self.dry:
            live = next((w for w in self.app_wins(A) if w["onscreen"]), None)
            if live and self.tile_for_geom(live["x"], live["y"], live["w"], live["h"]):
                raise Fallback("activate %s: sitting on a tile" % A)
        if any(not any(fld(l, 0) == s for l in self.mem) for s in self.seq_read()):
            raise Fallback("an empty slot to destroy")
        fg = self.float_up(cur, A, None, make)
        self.set_current(cur)
        self.log("activate %s: floater → raise in place%s (scene untouched)" % (A, " at " + fg if fg else ""))
        self.log_raise(A)

    def op_controlroom(self):
        """remap_open.sh for a running Control Room on a slot desktop. Not a toggle
        (asked for, 2026-10-17): its key goes there like Go to Fusion. Snapped (its
        own space) → jump there like any app (navapp), then SIGUSR1 (RemapApp summon)
        in case it was put away. Not snapped → raise it as a floater — put away, it
        has no window on a desktop and SIGUSR1 brings it back. Not running (cold
        start) or a full-screen Space → FALLBACK."""
        if self.dry or not proc_any(lambda p: p == "Remap"):
            raise Fallback("Control Room not running")
        if ws_active()[1]:
            raise Fallback("full-screen Space")
        if any(fld(l, 1) == "Remap" and "," not in fld(l, 2) for l in self.mem):
            self.op_navapp("Remap")
            self.spawns += [["pkill", "-USR1", "-x", "Remap"]]
            return
        self.op_activate("Remap", make=["pkill", "-USR1", "-x", "Remap"])
        # Always summon too: it pulls a window stranded on another desktop here itself,
        # which raise_floater's sticky toggle can't when yabai lost the window's AX ref.
        self.spawns += [["pkill", "-USR1", "-x", "Remap"]]

    # ── floaters (navapp / activate's floater branch) ─────────────────────────
    def app_wins(self, A):
        """A's layer-0 windows, front to back, each with the desktops it is on."""
        if A not in self._wins:
            ws = [w for w in ws_windows(owners=set(self.alt_names(A)) | {A})
                  if w["layer"] == 0 and self.normalize(w["app"]) == A]
            for w in ws:
                w["spaces"] = ws_spaces_of(w["id"])
            self._wins[A] = ws
        return self._wins[A]

    def has_window(self, A):
        """space_query has: a window of at least 50x50 on some desktop."""
        return any(w["w"] >= 50 and w["h"] >= 50 and w["spaces"] for w in self.app_wins(A))

    def tile_for_geom(self, x, y, w, h):
        """slotlib's tile_for_geom on the on-screen part of the rect (clamp_to_screen),
        at any UI Zoom level (zoomtiles) by the raw one."""
        sw, sh = (int(v) for v in self.screen_dims())
        x2, y2 = min(x + w, sw), min(y + h, sh)
        cx, cy = max(x, 0), max(y, 0)
        r = (cx, cy, max(x2 - cx, 0), max(y2 - cy, 0))
        return zoomtiles.tile_of(r, sw, sh, (x, y, w, h), self.sdir)

    def floater_geom(self, A):
        g = next((fld(l, 1) for l in self.lp if fld(l, 0) == A), "")
        if "," in g:
            return g
        return next((fld(l, 2) for l in self.mem if fld(l, 1) == A and "," in fld(l, 2)), "")

    def reopen_cmd(self, A):
        """ensure_app_window's _make_window for an app with NO window at all: `open -a`
        is a Dock click, which reopens one (Finder's at its remembered spot). Windows
        that exist but are hidden/minimized → None (ensure_app_window's AX path)."""
        r = self.st.resolve.get(A.lower().replace(" ", "").replace("-", ""))
        if (r[3] if r else "") not in ("", "finder"):
            return None
        if any(w["w"] >= 100 and w["h"] >= 100 for w in self.app_wins(A)):
            return None
        name = r[0] if r else A
        if name.startswith("Adobe Photoshop"):   # app_resolve.sh open_app: marquee-arrow hook
            return [REPO + "/remap/photoshop/cursor/open.sh"]
        return ["open", "-a", name]

    def float_up(self, cur, A, msg, make=None):
        """Register A in the current slot at its floater geometry, synced to where it
        actually sits (refresh_floater_geom), and queue the raise. With no window on
        a desktop, MAKE (or reopen_cmd) brings one up instead. → the geometry."""
        if (" %s " % A) in (" %s " % self.st.cad_apps):
            raise Fallback("CAD floater %s" % A)          # win_list_raw's aux filter
        wins = [] if self.dry else self.app_wins(A)
        if self.dry or any(w["spaces"] for w in wins):
            make = None
        else:
            make = make or self.reopen_cmd(A)
            if not make:
                raise Fallback("%s has no window on a desktop" % A)
        prevfocus = self.focus_of(cur)
        live = next(("%d,%d,%d,%d" % (w["x"], w["y"], w["w"], w["h"]) for w in wins if w["onscreen"]), "")
        fg = self.floater_geom(A) or live
        if "," in fg:
            self.set_member(cur, A, fg)
            self.set_lastpos(A, fg)
            if live:
                self.mem = ["%s|%s|%s|%s" % (fld(l, 0), A, live, fld(l, 3))
                            if fld(l, 1) == A and "," in fld(l, 2) else l for l in self.mem]
                self.set_lastpos(A, live)
                self.log("refresh_floater_geom: %s → %s (synced across spaces)" % (A, live))
        if msg:
            self.log(msg)
            self.log_raise(A)
        self.floats.append((A, wins, make))
        self.switched(prevfocus, A)
        self.reconcile_left(cur)
        return fg

    def log_raise(self, A):
        if self.dry:
            self.log("DRY raise_floater %s" % A)

    def raise_floater(self, A, wins, make=None):
        """slotlib's raise_floater: stranded windows made sticky (floater_to_all_desktops)
        and the floater layer pinned BEFORE the activation, so it lands on top in one
        frame; the full layer/shadow pass (pin_loose_above) follows off the hot path.
        MAKE (float_up) brings a window up and activates the app itself."""
        if make:
            self.spawns += [make, ["/bin/bash", "-c", 'sleep 0.6; exec /bin/bash "$0" pinhere', SLOTLIB]]
            return
        active = ws_active()[0]
        stranded = [w["id"] for w in wins if len(w["spaces"]) == 1 and w["spaces"][0] != active]
        for wid in stranded:
            yabai("window", wid, "--toggle", "sticky")
        if stranded:
            self.log_now("floater %s: windows %s were on another desktop → sticky"
                         % (A, " ".join(str(i) for i in stranded)))
        for w in wins:
            if w["spaces"]:
                yabai("window", w["id"], "--sub-layer", "above")
        self.spawns += [[BIN + "/activate_app", self.st.open_name.get(A, A)],
                        ["/bin/bash", "-c", 'sleep 0.3; exec /bin/bash "$0" pinhere', SLOTLIB]]

    def op_coherence(self, r):
        """goto_app.sh's open_coherence (app_resolve.sh) for a RUNNING Coherence app
        (3ds Max): focus the Space its window is on, then open the Mac stub in the
        background so it is key. Outside the slots — no lock, no state. Anything
        else (not running, VM paused by vm.sh, stub not cached yet, no window) →
        FALLBACK. The Space is remembered (space_query costs 40-130 ms) and
        re-checked on a thread after the flip, which re-flips if it had moved."""
        t0 = time.time()
        idx = self.coherence_flip(r)
        return ["coherence|%s" % idx], "flip %.1f ms" % ((time.time() - t0) * 1000)

    def coherence_flip(self, r):
        open_name = r[0]
        # Every Coherence stub runs as WinAppHelper: none → nothing is running.
        if not proc_any(lambda n: n.startswith("WinAppHelper")):
            raise Fallback("no Coherence app running")
        if os.path.exists("/tmp/.vm_paused_by_slots"):
            raise Fallback("VM paused by vm.sh")
        stub = cat("/tmp/.coherence_stub_" + re.sub(r"[^A-Za-z0-9]", "_", open_name))
        if not stub or not os.path.exists(stub):
            raise Fallback("no cached stub for %s" % open_name)
        write_atomic("/tmp/.coherence_last", "%s\n" % (self.coh_pid(stub) or ""))
        sp = _COH_SPACE.get(open_name)
        if sp is None:
            sp = coherence_space(open_name)
            if sp is None:
                raise Fallback("%s has no window on a Space" % open_name)
        else:
            threading.Thread(target=coherence_recheck, args=(open_name, sp), daemon=True).start()
        self.spawns += [[COH_HOME]]   # strays back onto the app's Space
        if not sp[2]:
            # Off its own Space (a relaunched Max opens on top of a slot): the
            # script flips there and puts it back in full screen.
            _COH_SPACE.pop(open_name, None)
            self.spawns += [[COH_FULLSCREEN, open_name], [REPO + "/max/vm.sh", "ensure"]]
            return sp[0]
        yabai("space", "--focus", sp[0])
        write_atomic(self.ACTIVE_DESK, sp[1] + "\n")
        self.spawns += [["open", stub], [REPO + "/max/vm.sh", "ensure"]]   # after the reply
        return sp[0]

    @staticmethod
    def coh_pid(stub):
        """pid of the WinAppHelper running from a stub .app (coherence_home's /tmp/.coherence_last)."""
        try:
            out = subprocess.run(["pgrep", "-f", stub + "/Contents/MacOS/WinAppHelper"],
                                 capture_output=True, text=True, timeout=1).stdout.split()
        except (OSError, subprocess.SubprocessError):
            return None
        return out[0] if out else None

    def on_coherence(self, open_name):
        """True if the desktop being shown is the Coherence app's own."""
        sp = _COH_SPACE.get(open_name) or coherence_space(open_name)
        return bool(sp) and sp[1] == self.active_desk()

    def op_toggle(self, a_arg, b_arg, start_arg):
        """toggle_app.sh's decision, minus its "already in front" window read: here
        spaces_follow has already put current on the desktop you're looking at.
        Landing in this slot → "focus APP" (the script runs focus.sh); else op_goto.
        A Coherence app (3ds Max) has no slot: "on it" means its desktop is shown,
        and landing on it is coherence_flip ("coherence|IDX")."""
        rs = []
        for arg in (a_arg, b_arg, start_arg):
            r = self.st.resolve.get(arg.lower().replace(" ", "").replace("-", ""))
            if not r:
                raise Fallback("unknown app %r" % arg)
            if r[3] in ("parallels", "controlroom", "explorer"):
                raise Fallback("special %s" % r[3])
            rs.append(r)
        A, B, START = (r[1] for r in rs)
        cur = self.get_current()
        here = lambda app: any(fld(l, 0) == cur and fld(l, 1) == app for l in self.mem)
        coh = next((r for r in rs[:2] if r[3] == "coherence"), None)
        if coh and A != B:
            C = coh[1]
            other = B if C == A else A
            if self.on_coherence(coh[0]):
                T = other
            elif here(other):
                T = C
            else:
                T = START
            if T == C:
                self.out.append("coherence|%s" % self.coherence_flip(coh))
                self.log("toggle → %s (its own desktop)" % C)
                return
            # Leaving the Coherence desktop: current still names the slot left
            # before it, so the target may be "here" while not on screen — flip back.
            if self.is_snapped_member(cur, T) and self.slot_of_active_space() != cur:
                self.goto_slot(cur, cur)
                self.log("toggle %s: back to %s from %s's desktop" % (T, cur, C))
                self.do_restore(cur)
                self.switched(C, T)
                return
        elif A == B:
            T = A
        elif self.spaces_on() and self.active_desk() and not self.slot_of_active_space():
            # On a desktop no slot owns (3ds Max's, any Coherence window's): current
            # still names the slot left before it, so here() would say you're on
            # whichever app that was and the key would alternate. Nowhere → START.
            T = START
            if self.is_snapped_member(cur, T):
                self.goto_slot(cur, cur)
                self.log("toggle %s: start app, back to %s from a non-slot desktop" % (T, cur))
                self.do_restore(cur)
                self.switched("", T)
                return
        elif here(A) and here(B):
            T = B if self.focus_of(cur) == A else A
        elif here(A):
            T = B
        elif here(B):
            T = A
        else:
            T = START
        if here(T):
            self.out.append("focus %s" % T)
            return
        self.op_goto(T)

    # ── the grid (slots/grid.py; MODEL.md § The grid) ─────────────────────────
    def grid_cfg(self):
        return grid.load(self.env.get("SLOT_GRID"), self.dry)

    def grid_seed(self, cell, focus="", launch=True):
        """Make CELL's slot hold what the grid shows there now: back into the sequence if
        it dropped out, each position's pick at its tile (FOCUS on top), anything else on
        those tiles out. A grid app leaves the off-grid slots (one app, one place); a slot
        that empties that way is dropped. Floaters are left alone. LAUNCH False: a pick
        that isn't open is left out (its tile stays empty) instead of launched."""
        g, slot = self.grid_cfg(), cell["id"]
        rows = grid.seed(cell, self.gact, focus)
        outside = grid.outside(cell, self.gact)
        running = self.running_list()
        if not launch and not outside and running is not None:
            rows = [r for r in rows if self.app_running(r[0], running)]
        if not rows:
            raise Fallback("grid cell %s is empty" % slot)
        if not outside:                         # residents behind 3ds Max: never launched
            for a, _ in rows:
                self.ensure_running(a)
        seq = self.seq_read()
        if slot not in seq:
            seq.append(slot)
            self.seq_set(seq)
            self.log("grid: %s back in the sequence" % slot)
        tiles = [p for _, p in rows]
        for a, p, _ in self.members_of(slot):
            if p in TILES and (a, p) not in rows and any(self.pos_overlaps(q, p) for q in tiles):
                self.remove_member(slot, a)
        cells = set(c["id"] for c in g["cells"])
        for a, _ in rows:
            for l in [l for l in self.mem if fld(l, 1) == a and fld(l, 0) not in cells
                      and fld(l, 2) in TILES]:
                s = fld(l, 0)
                self.remove_member(s, a)
                self.log("grid: %s left off-grid %s" % (a, s))
                if not any(fld(m, 0) == s for m in self.mem) and s != self.get_current():
                    self.seq_set([x for x in self.seq_read() if x != s])
                    self.log("grid: off-grid %s emptied → removed from the sequence" % s)
        for a, p in rows:
            self.set_member(slot, a, p)
            self.set_lastpos(a, p)

    def grid_go(self, cur, here, cell, focus, why, launch=True):
        """Seed CELL and switch to it from CUR (HERE: the active desktop is a slot's).
        LAUNCH False (a swipe): the cell's apps that aren't open stay closed."""
        prevfocus = self.focus_of(cur)
        tgt = cell["id"]
        self.grid_seed(cell, focus, launch)
        if self.grid_outside(cur, here, cell, prevfocus, why):
            return
        newfocus = focus or self.focus_of(tgt)
        cads = " %s " % self.st.cad_apps
        cad = next((fld(l, 1) for l in self.mem if fld(l, 0) == tgt and (" %s " % fld(l, 1)) in cads), "")
        if cad and not focus:
            newfocus = cad
        self.goto_slot(cur, tgt)
        self.log("%s: %s(%s) → %s(%s)" % (why, cur, prevfocus, tgt, newfocus))
        self.do_restore(tgt)
        self.switched(prevfocus, newfocus)
        if "Remap" in grid.unshown(cell, self.gact):     # see grid_cr_swap
            self.spawns += self.grid_cr_swap("Remap", "")
        if here and tgt != cur:
            self.reconcile_left(cur, focus)

    def grid_outside(self, cur, here, cell, prevfocus, why):
        """CELL shows an outside app (3ds Max): current becomes the cell, its Space is
        flipped to, the cell's desktop and residents stay as they are. → True if so."""
        A = grid.outside(cell, self.gact)
        if not A:
            return False
        r = self.st.resolve.get(A.lower().replace(" ", "").replace("-", ""))
        if not r:
            raise Fallback("unknown app %r" % A)
        if not self.dry:
            # Until Max sits full screen on its own Space (launching, splash on a
            # slot's desktop) the cell shows its residents, and Max is opened in
            # the background — never a swipe that goes nowhere (2026-10-18).
            running = proc_any(lambda n: n.startswith("WinAppHelper"))
            sp = coherence_space(r[0]) if running else None
            if not (sp and sp[2]) or os.path.exists("/tmp/.vm_paused_by_slots"):
                # Launch only when it isn't running: a starting Max is left to its
                # own launch (coherence_fullscreen waits for the window).
                if not running and not self.coh_opening():
                    self.spawns += [["/bin/bash", "-c", COH_OPEN, r[0]]]
                self.log("%s: %s not ready — showing %s" % (why, A, cell["id"]))
                return False
            self.coherence_flip(r)
        self.goto_slot(cur, cell["id"])
        self.log("%s: %s(%s) → %s(%s, its own desktop)" % (why, cur, prevfocus, cell["id"], A))
        self.switched(prevfocus, A)
        if here and cell["id"] != cur:
            self.reconcile_left(cur)
        return True

    @staticmethod
    def coh_opening():
        """True while a Coherence open is already under way (no respawn per swipe)."""
        return subprocess.run(["pgrep", "-f", "coherence_fullscreen.sh|open_coherence"],
                              capture_output=True).returncode == 0

    def grid_here(self):
        """→ (cur, here): current, followed onto the active desktop's slot if it differs.
        On the Space of the outside app current's cell shows (3ds Max), here = cur."""
        cur, here = self.get_current(), self.slot_of_active_space()
        if here and here != cur:
            self.goto_slot(cur, here)
            cur = here
        if not here:
            cell = grid.cell_of(self.grid_cfg(), cur)
            A = cell and grid.outside(cell, self.gact)
            r = A and self.st.resolve.get(A.lower().replace(" ", "").replace("-", ""))
            if r and not self.dry and self.on_coherence(r[0]):
                here = cur
        return cur, here

    def op_swipe(self, d):
        """Swipe D (left|right|up|down) to the neighbouring grid cell (grid.swipe)."""
        if d not in grid.DIRS:
            raise Fallback("swipe %r" % d)
        g = self.grid_cfg()
        cur, here = self.grid_here()
        running = self.running_list()      # None (a dry run without SLOT_RUNNING): no skipping
        ok = None
        if running is not None:
            ok = lambda c: grid.live(c, self.gact, lambda a: self.app_running(a, running))
        t = grid.swipe(g, cur if here else "", d, ok)
        if not t:
            f = self.focus_of(cur)
            self.log("swipe %s: nothing that way from %s" % (d, cur))
            self.out.append("%s|%s" % (f, f))
            return
        self.grid_go(cur, here, t, "", "swipe %s" % d, launch=False)

    def op_gridtoggle(self):
        """Flip the current grid cell's alternatives (grid.toggle): the focused app's
        position, else the first one that has any."""
        g = self.grid_cfg()
        cur, here = self.grid_here()
        cell = grid.cell_of(g, cur) if here else None
        if not cell:
            f = self.focus_of(cur)
            self.log("gridtoggle: %s is not a grid cell — nothing to toggle" % (cur or "this desktop"))
            self.out.append("%s|%s" % (f, f))
            return
        shown = [a for a, _ in grid.chosen(cell, self.gact)]
        mine = [(sort_num(fld(l, 3)), fld(l, 1)) for l in self.mem
                if fld(l, 0) == cur and fld(l, 1) in shown]
        focus = max(mine)[1] if mine else ""
        dead = [] if self.dry else [a for a in shown if not proc_any(
            lambda n, ns=set(self.alt_names(a)): n in ns)]   # a quit pick comes back first
        r = grid.toggle(cell, focus, self.gact, dead)
        if not r:
            self.log("gridtoggle: %s has nothing to toggle" % cur)
            self.out.append("%s|%s" % (focus, focus))
            return
        self.dirty.add("grid")
        p, old, new = r
        self.grid_seed(cell, new)
        if self.grid_outside(cur, cur, cell, old, "gridtoggle %s" % p):
            return
        self.set_current(cur)
        self.log("gridtoggle: %s %s %s → %s" % (cur, p, old, new))
        self.do_restore(cur)
        self.switched(old, new)
        self.spawns += self.grid_cr_swap(old, new)

    @staticmethod
    def grid_cr_swap(old, new):
        """Control Room keeps its window on the `above` sub-layer (RemapApp floatAbove;
        yabai can't reach it), so no app it shares a grid tile with can be raised over
        it: toggled away it is put away (SIGUSR2, its ✕), toggled to it is summoned."""
        if new == "Remap" and old != new:
            return [["pkill", "-USR1", "-x", "Remap"]]
        if old == "Remap" and new != old:
            return [["pkill", "-USR2", "-x", "Remap"]]
        return []

    def grid_navapp(self, A):
        """navapp for an app the grid places: its cell, made to show A. → True if done."""
        g = self.grid_cfg()
        hit = grid.pick(g, A, self.gact)
        if not hit:
            return False
        self.dirty.add("grid")
        cur, here = self.grid_here()
        self.grid_go(cur, here, hit[0], A, "navapp %s (grid)" % A)
        return True

    # ── locking (shlock-compatible: the holder's pid, then a newline) ─────────
    def _lock_once(self):
        tmp = "%s.slotd%d" % (self.LOCKF, os.getpid())
        try:
            with open(tmp, "w") as f:
                f.write("%d\n" % os.getpid())
            for _ in range(2):
                try:
                    os.link(tmp, self.LOCKF)
                    return True
                except FileExistsError:
                    holder = cat(self.LOCKF)
                    if not re.fullmatch(r"\d+", holder or ""):
                        return False
                    try:
                        os.kill(int(holder), 0)
                        return False                         # alive: really held
                    except ProcessLookupError:
                        try:
                            os.unlink(self.LOCKF)            # dead holder: stale
                        except FileNotFoundError:
                            pass
                    except PermissionError:
                        return False
            return False
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def lock(self, op):
        for _ in range(200):
            if self._lock_once():
                self.locked = True
                return
            if self.deadline is not None:
                self.still_wanted("waiting on the lock (pid %s)" % cat(self.LOCKF))
            time.sleep(0.05)
        holder = cat(self.LOCKF)
        try:
            age = int(time.time() - os.stat(self.LOCKF).st_mtime)
        except OSError:
            age = 0
        if re.fullmatch(r"\d+", holder or "") and int(holder) != os.getpid() and age >= 20:
            self.log_now("lock: %s broke a %ds-old lock — killing hung pid %s" % (op, age, holder))
            kill_tree(int(holder))
            time.sleep(0.1)
            try:
                os.unlink(self.LOCKF)
            except OSError:
                pass
            if self._lock_once():
                self.locked = True
                return
        self.log_now("lock: %s waited 10s on pid %s, running unlocked" % (op, holder))

    def unlock(self):
        if self.locked and cat(self.LOCKF) == str(os.getpid()):
            try:
                os.unlink(self.LOCKF)
            except OSError:
                pass
        self.locked = False

    # ── realize (realize_slot / _realize_planned) ─────────────────────────────
    def fast_path(self, slot):
        """realize_slot's cache read: (desktop index, uuid, [window ids]) or None."""
        idx, u = None, ""
        for l in file_lines(self.sdir + "/slot_space_idx"):
            if fld(l, 0) == slot:
                idx, u = fld(l, 1), fld(l, 2)
        wid = {}
        for l in file_lines(self.sdir + "/slot_winids"):
            wid[fld(l, 0)] = fld(l, 1)
        mine, other = [], set()
        for l in self.mem:
            if fld(l, 0) == slot:
                if "," not in fld(l, 2) and fld(l, 1) not in mine:   # floaters: sticky, never moved
                    mine.append(fld(l, 1))
            else:
                other.add(fld(l, 1))
        if idx is None or idx == "":
            return None
        ws = ""
        for a in mine:
            if a in other:
                if a not in wid:
                    return None
                ws += " " + wid[a]
        t = ("%s %s%s" % (idx, u, ws)).split()          # read -r fast fuuid fwids
        if not t or not re.fullmatch(r"\d+", t[0]):
            return None
        return t[0], (t[1] if len(t) > 1 else ""), t[2:]

    # ── commit + effects ──────────────────────────────────────────────────────
    def precheck(self):
        """Every effect checked before anything is written or flipped: raises Fallback
        if one could not be done here. → [(slot, fast_path)]."""
        fasts = []
        if not self.dry:
            for slot in self.realizes:
                fp = self.fast_path(slot)
                if fp is None:
                    raise Fallback("no cached desktop for %s" % slot)
                fasts.append((slot, fp))
            if self.realizes:
                self.screen_dims()
        return fasts

    def commit(self):
        """Writes state and the log. Runs AFTER the flip (still under the lock, before
        the plan thread reads the state): it cannot fall back, and the desktop starts
        moving ~1-8 ms sooner."""
        w = self.dirty
        if "mem" in w:
            write_atomic(self.MEM, "".join(l + "\n" for l in self.mem))
        if "lp" in w:
            write_atomic(self.LP, "".join(l + "\n" for l in self.lp))
        if "zc" in w:
            write_atomic(self.ZC, self.zc)
        if "prev" in w:
            write_atomic(self.PREVF, self.prev + "\n")
        if "cur" in w:
            write_atomic(self.CUR, self.cur + "\n")
        if "mru" in w:
            write_atomic(self.MRU, "".join(l + "\n" for l in self.mru))
        if "seq" in w:
            write_atomic(self.SEQ, "".join(l + "\n" for l in self.seq_new))
        if "grid" in w:
            grid.write_active(self.gact, self.GACT)
        if self.logs:
            try:
                with open(self.logpath, "a") as f:
                    f.write("".join(self.logs))
            except OSError:
                pass
            self.logs = []

    def realize(self, slot, fp):
        """The flip (realize_slot's fast path). → the plan's thread, for run() to start
        once commit() has written the state it reads."""
        if self.dry:
            self.log_now("DRY realize %s: %s" % (slot, "".join("%s|%s " % (a, p) for a, p, _ in self.members_of(slot))))
            return None
        sw, sh = self.screen_dims()
        fast, fuuid, fwids = fp
        for fw in fwids:
            yabai("window", fw, "--space", fast)
        yabai("space", "--focus", fast)
        if fuuid:
            write_atomic(self.ACTIVE_DESK, fuuid + "\n")
        return threading.Thread(target=self.realize_planned, args=(slot, sw, sh, fast), daemon=True)

    def realize_planned(self, slot, sw, sh, flipped_to):
        qos_interactive()
        try:
            self._realize_planned(slot, sw, sh, flipped_to)
        except Exception as e:                     # never take the daemon down
            dlog("realize_planned %s: %r" % (slot, e))

    def _realize_planned(self, slot, sw, sh, flipped_to):
        try:
            sw, sh = self.screen_dims()          # a UI Zoom glide may have landed since the flip
        except Fallback:
            pass
        plan = ""
        for attempt in (1, 2):
            try:
                snap = subprocess.run([BIN + "/space_query", "json"], capture_output=True,
                                      text=True, timeout=10).stdout
            except (OSError, subprocess.SubprocessError):
                snap = ""
            try:
                out = realize_plan.plan(slot, self.sdir, int(sw), int(sh), snap)
            except Exception as e:
                dlog("plan %s: %r" % (slot, e))
                out = None
            plan = (out or "").rstrip("\n")
            if not (plan.startswith("NOFREE") and attempt == 1):
                break
            if not self.mc_add_desktop():
                break
        first, _, ops = plan.partition("\n")
        hd = first.split(None, 2)
        tgt = hd[0] if hd else ""
        cur = hd[1] if len(hd) > 1 else ""
        tuuid = hd[2] if len(hd) > 2 else ""
        if not re.fullmatch(r"\d+", tgt):
            self.log_now("spaces: no desktop for %s (%s) — realize skipped" % (slot, plan[:40]))
            return
        post = []
        for line in ops.split("\n"):
            f = line.split(None, 5)                # read -r kind a b c d e
            f += [""] * (6 - len(f))
            kind, a, b = f[0], f[1], f[2]
            if kind == "sticky":
                yabai("window", a, "--toggle", "sticky")
            elif kind == "space":
                ok, _ = yabai("window", a, "--space", b)
                if not ok and re.fullmatch(r"\d+", a):      # unmovable: follow the window
                    try:
                        snap = subprocess.run([BIN + "/space_query", "json"], capture_output=True,
                                              text=True, timeout=10).stdout
                        r = realize_plan.rebind(slot, self.sdir, int(a), snap)
                    except Exception as e:
                        dlog("rebind %s: %r" % (slot, e))
                        r = None
                    if r:
                        tgt, tuuid = r.split()
                        self.log_now("rebind %s → desktop %s (window %s unmovable)" % (slot, tgt, a))
            elif kind == "evict":
                yabai("window", a, "--space", b)
            elif kind:
                post.append(f)
        if flipped_to != tgt and (flipped_to or tgt != cur):
            yabai("space", "--focus", tgt)
        write_atomic(self.ACTIVE_DESK, tuuid + "\n")
        self.log_now("realize %s on desktop %s (from %s): %s" % (slot, tgt, cur, ops.replace("\n", ";")))
        if post:
            post = self.frames_after_zoom(slot, post, sw, sh)
            for kind, a, b, c, d, e in post:
                if kind == "activate":
                    subprocess.run([BIN + "/activate_app", a], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                elif kind == "frame":
                    yabai("window", a, "--move", "abs:%s:%s" % (b, c))
                    yabai("window", a, "--resize", "abs:%s:%s" % (d, e))
            touch(OP_TS)

    def frames_after_zoom(self, slot, post, sw, sh):
        """The drifted-tile frames are cut from the screen as it was at the plan. A UI Zoom
        glide moving windows now ends at another size: wait for it to land (≤2 s), and
        if the screen changed, take the frames from a fresh plan. A window still left at
        another zoom's tile reads as that tile (zoomtiles) until its next reveal."""
        if not any(f[0] == "frame" for f in post) or not zoomtiles.busy(self.sdir):
            return post
        zoomtiles.wait(self.sdir)
        try:
            nsw, nsh = self.screen_dims()
        except Fallback:
            return post
        if (str(nsw), str(nsh)) == (str(sw), str(sh)):
            return post
        try:
            snap = subprocess.run([BIN + "/space_query", "json"], capture_output=True,
                                  text=True, timeout=10).stdout
            out = realize_plan.plan(slot, self.sdir, int(nsw), int(nsh), snap) or ""
        except Exception as e:
            dlog("replan %s: %r" % (slot, e))
            return [f for f in post if f[0] != "frame"]
        frames = []
        for line in out.split("\n")[1:]:
            f = line.split(None, 5)
            if f and f[0] == "frame":
                frames.append(f + [""] * (6 - len(f)))
        self.log_now("realize %s: UI Zoom landed at %sx%s — frames re-cut" % (slot, nsw, nsh))
        return [f for f in post if f[0] != "frame"] + frames

    def mc_add_desktop(self):
        """slotlib's mc_add_desktop: one desktop via Mission Control's button."""
        def count():
            ok, out = yabai("query", "--spaces")
            try:
                return len(json.loads(out)) if ok else None
            except ValueError:
                return None
        before = count()
        subprocess.run(["open", "-a", "Mission Control"])
        subprocess.run(["osascript"], input=b'''tell application "System Events" to tell process "Dock"
  repeat 40 times
    try
      click (first button of group 2 of group 1 of group 1 whose description is "add desktop")
      exit repeat
    end try
    delay 0.05
  end repeat
end tell''', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)
        r = subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "Dock" to exists group 1'],
                           capture_output=True, text=True)
        if "true" in r.stdout:
            subprocess.run(["open", "-a", "Mission Control"])
        after = None
        for _ in range(30):
            after = count()
            if after is not None and before is not None and after > before:
                self.log_now("spaces: added a desktop (%d → %d)" % (before, after))
                return True
            time.sleep(0.1)
        self.log_now("spaces: mc_add_desktop failed (still %s)" % ("" if after is None else after))
        return False

    def spawn_reconciles(self, children):
        for cmd in self.spawns:
            children.append(subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL, start_new_session=True))
        delay = self.env.get("SLOT_RECONCILE_DELAY") or "1"
        for slot, excl in self.reconciles:
            children.append(subprocess.Popen(
                ["/bin/bash", "-c", 'sleep "$0"; exec bash %s reconcile_slot "$1" "$2"' % SLOTLIB,
                 delay, slot, excl],
                env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True))

    # ── dispatch (slotlib.sh § dispatch) ──────────────────────────────────────
    def run(self, op, args):
        """→ (stdout lines, timing note). Raises Fallback untouched."""
        if op not in ("goto", "navapp", "nav", "spacesync", "toggle", "activate", "focus",
                      "swipe", "gridtoggle"):
            raise Fallback("op %s" % op)
        if op == "goto" and args and not self.dry:
            r = self.st.resolve.get(args[0].lower().replace(" ", "").replace("-", ""))
            if r and r[3] == "coherence":
                return self.op_coherence(r)
        if not self.dry and os.path.exists(OFF_FLAG):
            raise Fallback("slots off")
        if not self.spaces_on():
            raise Fallback("single-desktop mode")
        if op in ("goto", "navapp", "nav", "activate", "focus", "swipe") and len(args) < 1:
            raise Fallback("no arg")
        if op == "toggle" and len(args) < 2:
            raise Fallback("toggle needs two apps")
        touch(OP_TS)
        t0 = time.time()
        if op == "spacesync":
            if not self._lock_once():
                return [], "lock busy"
            self.locked = True
        else:
            self.lock(op)
        t1 = time.time()
        probe = None
        if self.deadline is not None and not self.dry:
            # The pre-flip yabai check, asked now so its round-trip overlaps the decide.
            probe = threading.Thread(target=self.yabai_probe, daemon=True)
            probe.ok = False
            probe.start()
        try:
            self.reload_state()          # under the lock: it may have changed while we waited
            if op in ("goto", "navapp", "spacesync", "toggle", "activate", "focus"):
                self.spaces_follow()
            if op != "spacesync":
                try:
                    if os.path.getsize(self.SEQ) == 0:
                        raise Fallback("empty seq (init)")
                except OSError:
                    raise Fallback("no seq (init)")
            # A canon app is never a floater; one recorded loose is slotlib's to
            # rewrite onto its tile (unfloat_canon) before anything reads it.
            if any(fld(l, 1) in self.apps and "," in fld(l, 2) for l in self.mem) or \
                    any(fld(l, 0) in self.apps and "," in fld(l, 1) for l in self.lp):
                raise Fallback("canon app recorded loose")
            if op == "goto":
                self.op_goto(args[0])
            elif op == "navapp":
                self.op_navapp(args[0])
            elif op == "nav":
                self.op_nav(args[0])
            elif op == "activate":
                self.op_activate(args[0])
            elif op == "focus":
                self.op_focus(args[0])
            elif op == "toggle":
                self.op_toggle(args[0], args[1], args[2] if len(args) > 2 else args[0])
            elif op == "swipe":
                self.op_swipe(args[0])
            elif op == "gridtoggle":
                self.op_gridtoggle()
            fasts = self.precheck()
            if self.deadline is not None:
                # Last exit before anything is written or flipped. A yabai that does not
                # answer a query now (display reconfigure, an app holding its AX) would
                # sit on the flip and then run it late: drop instead. But a yabai that is
                # only BUSY for a moment is waited for, up to the jump's deadline or a
                # newer press: on every desktop switch it re-asks apps whose windows it
                # never resolved for them over AX, and an app whose AX is dead (a hung
                # Fusion/Photoshop) holds it ~1 s each time. Dropping on the first 0.5 s
                # miss lost every swipe made within ~1.5 s of the last (2026-11-15,
                # the "cooldown").
                self.still_wanted("before the flip")
                if probe is not None:
                    probe.join()
                    while not probe.ok:
                        self.still_wanted("waiting for yabai")
                        time.sleep(0.03)
                        probe.ok = yabai("query", "--displays", "--display", timeout=0.5)[0]
            t2 = time.time()
            if self.dry:
                self.commit()
                for s in self.realizes:
                    self.realize(s, None)
                t3 = time.time()
            else:
                plans = []
                try:
                    for slot, fp in fasts:
                        plans.append(self.realize(slot, fp))
                finally:
                    t3 = time.time()
                    self.commit()
                for p in plans:
                    p.start()
                for a, wins, make in self.floats:
                    self.raise_floater(a, wins, make)
            t4 = time.time()
            ms = lambda a, b: (b - a) * 1000
            return self.out, "lock %.1f, decide %.1f, flip %.1f, write %.1f ms" % (
                ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4))
        finally:
            self.unlock()

    def yabai_probe(self):
        qos_interactive()
        threading.current_thread().ok = yabai("query", "--displays", "--display", timeout=0.5)[0]

    def reload_state(self):
        self.mem = file_lines(self.MEM)
        self.lp = file_lines(self.LP)
        self.cur = cat(self.CUR)
        self.zc = read_text(self.ZC)
        self.mru = file_lines(self.MRU)
        self.seq_new = None
        self.gact = grid.read_active(self.GACT)


# ── Coherence apps' Space (op_coherence) ─────────────────────────────────────
_COH_SPACE = {}                          # open name → (desktop index, uuid), last seen


def coherence_space(open_name):
    """(index, uuid, is-full-screen) of the app's desktop from space_query,
    remembered; or None. A window on several Spaces is a sticky popup (Max keeps
    one on all) — skipped."""
    try:
        r = subprocess.run([BIN + "/space_query", "json"], capture_output=True, text=True, timeout=3)
        j = json.loads(r.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    # The main window is the biggest one on a single desktop (Max also opens
    # dialogs on whatever desktop is shown).
    ws = [w for w in j.get("windows", []) if w.get("app") == open_name and len(w.get("spaces") or []) == 1]
    sid = max(ws, key=lambda w: w.get("w", 0) * w.get("h", 0))["spaces"][0] if ws else None
    sp = next(((s.get("index"), s.get("uuid", ""), s.get("fullscreen") == 1)
               for s in j.get("spaces", []) if s.get("id") == sid), None)
    if sp is None:
        _COH_SPACE.pop(open_name, None)
    else:
        _COH_SPACE[open_name] = sp
    return sp


def coherence_recheck(open_name, flipped):
    sp = coherence_space(open_name)
    if sp is not None and not sp[2]:
        # Its full-screen Space is gone (Max relaunched onto a slot's desktop).
        _COH_SPACE.pop(open_name, None)
        subprocess.Popen([COH_FULLSCREEN, open_name], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        dlog("coherence %s: off its full-screen Space (desktop %s), healing" % (open_name, sp[0]))
    elif sp is not None and sp[0] != flipped[0]:
        yabai("space", "--focus", sp[0])
        write_atomic("/tmp/.slot_active_desk", sp[1] + "\n")
        dlog("coherence %s: Space moved %s → %s, re-flipped" % (open_name, flipped[0], sp[0]))


def kill_tree(pid):
    try:
        kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    except OSError:
        kids = []
    for c in kids:
        kill_tree(int(c))
    try:
        os.kill(pid, 15)
    except OSError:
        pass


# ── server ────────────────────────────────────────────────────────────────────
_libsys = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


def qos_interactive():
    """This thread to QOS_CLASS_USER_INTERACTIVE. A launchd agent runs at the default
    QoS, and so does every Python thread (none inherit it): mid-gesture (remapd,
    reanchor, WindowServer busy) the switch waited behind them, and a plan thread
    holding the GIL held up the next switch with it."""
    try:
        rc = _libsys.pthread_set_qos_class_self_np(0x21, 0)
        if rc:
            dlog("qos: pthread_set_qos_class_self_np → %d" % rc)
    except Exception as e:
        dlog("qos: %r" % e)


def serve():
    global _deadline
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:%s:%s" % (BIN, env.get("PATH", "/usr/bin:/bin"))
    for k in [k for k in env if k.startswith("SLOT_")]:
        del env[k]                       # a live daemon never runs the test hooks
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o077)
    srv.bind(SOCK)
    os.umask(old)
    srv.listen(16)
    srv.settimeout(30)
    children = []
    qos_interactive()
    try:
        ws_windows(owners=set())         # open the window-server connection now, not on the first summon
    except Exception as e:
        dlog("window server warm-up: %r" % e)
    dlog("slotd up (pid %d)" % os.getpid())
    while True:
        children[:] = [c for c in children if c.poll() is None]
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        t0 = time.time()
        try:
            conn.settimeout(2)
            data = b""
            while True:
                b = conn.recv(4096)
                if not b:
                    break
                data += b
            args = [a.decode("utf-8", "replace") for a in data.split(b"\0")[:-1]]
            # slotc's first arg: "\x01<key-press token>\x01<its clock, ms>"
            gen, sent = "", t0
            if args and args[0][:1] == "\x01":
                meta = args.pop(0)[1:].split("\x01")
                gen = meta[0]
                try:
                    sent = min(t0, int(meta[1]) / 1000.0)
                except (IndexError, ValueError):
                    pass
            if not args:
                conn.close()
                continue
            if args[0] == "ping":
                conn.sendall(b"0pong")
                conn.close()
                continue
            op = None
            try:
                op = Op(env, SETTINGS_OBJ)
                if args[0] in JUMP_OPS:
                    op.gen, op.deadline = gen, sent + DEADLINE_S
                    _deadline = op.deadline
                    op.still_wanted("%.0f ms after the press" % ((t0 - sent) * 1000))
                out, timing = op.run(args[0], args[1:])
                reply = b"0" + "\n".join(out).encode()
                status = "done %s (%s)" % ("|".join(out[-1:]) or "-", timing)
            except Dropped as e:
                reply, status = b"X", "DROPPED (%s)" % e
            except Fallback as e:
                reply, status = b"F", "FALLBACK (%s)" % e
            except Exception as e:
                reply, status = b"F", "ERROR %r — fallback" % e
            finally:
                _deadline = None
            try:
                conn.sendall(reply)
            except OSError:
                pass
            conn.close()
            dlog("%s → %s, %.1f ms" % (" ".join(args), status, (time.time() - t0) * 1000))
            if op is not None and reply[:1] == b"0":
                op.spawn_reconciles(children)
        except Exception as e:
            dlog("request error: %r" % e)
            try:
                conn.close()
            except OSError:
                pass


def once(argv):
    op = Op(dict(os.environ), SETTINGS_OBJ)
    try:
        out, _ = op.run(argv[0], argv[1:])
    except Fallback as e:
        print("FALLBACK %s" % e)
        return 3
    if out:
        print("\n".join(out))
    op.spawn_reconciles([])
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        sys.exit(once(sys.argv[2:]))
    serve()
