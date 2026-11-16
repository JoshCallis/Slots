/*
 * scene_restore — atomically restore a scene layout.
 *
 * Usage:
 *   scene_restore SW SH app1:pos1 app2:pos2 ...
 *
 *   SW, SH  — screen width/height in logical pixels
 *   app:pos — app localizedName and one of:
 *             full | left | right | top-left | top-right
 *             bottom-left | bottom-right
 *
 *   Apps are listed in activation order (left/top first, right/bottom last).
 *   The LAST app in the list ends up with keyboard focus.
 *
 * Why the old version stepped, and what changed
 * ──────────────────────────────────────────────
 * The old version froze the display (CGSDisableUpdate), activated every app,
 * slept a FIXED 80ms, then unfroze. The problem: apps raise their windows on
 * their own run loops at very different speeds. Measured on this machine:
 *   Chrome   ~93ms      SketchUp ~260ms
 * So at the 80ms unfreeze, the slower apps hadn't raised yet — their windows
 * composited a beat later, which is the visible "one-two-three step".
 *
 * CGSDisableUpdate is a GLOBAL display freeze (with a ~1s server watchdog), so
 * the correct fix is not a longer guess but to hold the freeze and POLL the
 * window list until every group window has actually reached the front, then
 * unfreeze for a single composite. The window list keeps updating while the
 * screen is frozen, so we can watch the apps raise and only reveal the finished
 * scene. Total hold is whatever the slowest app needs (~260ms here), capped
 * well under the 1s watchdog.
 *
 * Direct cross-process reordering (CGSOrderWindow) was tried and the window
 * server rejects it (err 1000) without yabai's injected scripting addition, so
 * we let each app raise its own window and just gate the reveal on the result.
 *
 * Scripting-addition fast path (2026-06-08)
 * ─────────────────────────────────────────
 * With yabai's scripting addition loaded (SIP already permits it; the SA is now
 * loaded at boot by ~/.config/yabai/yabairc, which also writes the sentinel
 * /tmp/.yabai_sa_loaded), `yabai window --focus` reorders SYNCHRONOUSLY at the
 * window-server level — even a slow Metal app (Fusion) jumps to front the instant
 * the call returns. So when the sentinel is present we issue the raises in the
 * foreground and the poll below collapses to a one-shot confirm: the group
 * reveals in a single composite with no one-at-a-time pop-in. The async
 * background+poll dance is kept only as the fallback for when the SA is absent.
 */

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>
#include "tiles.h"

typedef uint32_t CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSDisableUpdate(CGSConnectionID cid);
extern CGError CGSReenableUpdate(CGSConnectionID cid);
// The window server's screen zoom (what Accessibility ▸ Zoom drives). `center` is the
// middle of the visible rect, clamped to the screen — {0,0} pins it top-left. The two
// doubles are the scale (both set alike); `smooth` = image smoothing. Signatures read
// off the disassembly, macOS 26 (2026-10-20). See § Zoom glide.
extern CGError CGSSetZoomParameters(CGSConnectionID, CGPoint *center, double scale,
                                    double scale2, int smooth, int unused);
extern CGError CGSGetZoomParameters(CGSConnectionID, CGPoint *center, double *scale,
                                    unsigned char *smooth);
extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);
extern CGError CGSSetConnectionProperty(CGSConnectionID, CGSConnectionID, CFStringRef, CFTypeRef);
static int zoom_glide(int argc, const char *argv[]);
static int standin_test(int argc, const char *argv[]);

// ── Tunables ──────────────────────────────────────────────────────────────────
static const useconds_t kPollInterval    = 3000;  // 3ms between window-list checks
// After firing the (backgrounded) yabai raise we poll until the async reorder
// lands, then unfreeze. Capped well under the ~1s CGSDisableUpdate watchdog so
// the freeze stays bounded by us, never expiring mid-reorder. 160 * 3ms ≈ 480ms.
static const int        kLandMaxPolls    = 160;
// When the scripting addition is loaded (sentinel /tmp/.yabai_sa_loaded, written
// by ~/.config/yabai/yabairc) `yabai window --focus` reorders synchronously, so
// we issue the raises in the FOREGROUND and only need a short confirm afterwards
// — it lands on the first check. 20 * 3ms ≈ 60ms ceiling.
static const int        kConfirmPolls    = 20;
// Apps whose Metal/GL viewport takes extra time to render after activation.
// After the stacking-order poll exits we hold the freeze until this many ms
// have elapsed since Phase 3 (activation) for any slow app in the scene.
// SketchUp and Fusion need ~260ms; add some slack → 300ms.
// Set to 0 to test whether the CAD render hold is needed at all — the hold
// logic stays in place, it just contributes no extra dwell. Raise via
// /tmp/scene_render_ms (or bump this back up) if CAD pop-in returns.
static const int        kSlowRenderMs   = 0;
static const char      *kSlowApps[]     = { "SketchUp", "Autodesk Fusion", NULL };

// Optional debug log: SCENE_DEBUG=1 scene_restore ...  → /tmp/scene_restore.log
static FILE *gLog = NULL;
static pid_t gPid = 0;

// Milliseconds since an arbitrary start, for relative timing within one run.
static uint64_t gT0 = 0;
static double ms_since_start(void) {
    uint64_t now = mach_absolute_time();
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(now - gT0) * tb.numer / tb.denom / 1e6;
}

// Wall-clock prefix for log lines (shared across concurrent instances via PID).
static void dbg(const char *fmt, ...) {
    if (!gLog) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    fprintf(gLog, "[%02d:%02d:%02d.%03d][pid %d][+%.1fms] ",
            tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec/1000),
            gPid, ms_since_start());
    va_list ap; va_start(ap, fmt);
    vfprintf(gLog, fmt, ap);
    va_end(ap);
    fprintf(gLog, "\n");
    // Deliberately NO fflush here: a per-phase flush is a synchronous disk write
    // ON the critical path, under the display freeze, ~10× per switch — it widens
    // the frozen-frame dwell for zero user benefit. The [+Xms] timestamps are
    // captured at call time, so deferring the bytes doesn't change what's logged.
    // stdio buffers the run (~1KB, under BUFSIZ) and flushes it in one write at
    // normal process exit — which is AFTER the P7 thaw, i.e. after the frame drops.
}

// ── AX window positioning (cross-process, reliable) ───────────────────────────
static void axPosition(pid_t pid, CGRect r) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute,
                                      (CFTypeRef *)&wins) == kAXErrorSuccess
        && wins && CFArrayGetCount(wins) > 0) {

        // Target the app's MAIN document window, not window 0. Apps like Fusion
        // keep palettes (Browser, Sketch Palette, …) as separate windows that can
        // sit at index 0 — positioning index 0 would snap a palette instead of the
        // document.
        //
        // AXMain is the discriminator, queried REGARDLESS of subrole. Do NOT gate on
        // AXStandardWindow: the Maximize Viewport add-in makes Fusion's canvas
        // BORDERLESS, so macOS reports its subrole as AXDialog (not AXStandardWindow)
        // — exactly like a palette. Gating on AXStandardWindow therefore SKIPPED the
        // real canvas, left `win` at index 0, and snapped/raised a palette instead
        // (the "Fusion only partly appears / hides one of two windows" bug). The
        // canvas is the app's single AXMain window whether titled (AXStandardWindow)
        // or borderless (AXDialog); palettes/dialogs are never AXMain even when large.
        // Fall back to the first standard window, then to index 0. (Mirrors the
        // AXMain-based canvas detection in reanchor / FusionScrollFilter / slotlib.)
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(wins, 0);
        AXUIElementRef mainWin = NULL, firstStd = NULL;
        CFIndex nwins = CFArrayGetCount(wins);
        for (CFIndex i = 0; i < nwins; i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            // The real canvas: AXMain == true, any subrole.
            CFBooleanRef mainv = NULL;
            if (AXUIElementCopyAttributeValue(w, kAXMainAttribute,
                                              (CFTypeRef *)&mainv) == kAXErrorSuccess && mainv) {
                bool isMain = CFBooleanGetValue(mainv);
                CFRelease(mainv);
                if (isMain) { mainWin = w; break; }
            }
            // Fallback tracking: first AXStandardWindow (used only if no AXMain found).
            if (!firstStd) {
                CFStringRef sub = NULL;
                if (AXUIElementCopyAttributeValue(w, kAXSubroleAttribute,
                                                  (CFTypeRef *)&sub) == kAXErrorSuccess && sub) {
                    if (CFEqual(sub, kAXStandardWindowSubrole)) firstStd = w;
                    CFRelease(sub);
                }
            }
        }
        if (mainWin)        win = mainWin;
        else if (firstStd)  win = firstStd;

        CGPoint p = r.origin;
        AXValueRef av = AXValueCreate(kAXValueTypeCGPoint, &p);
        AXUIElementSetAttributeValue(win, kAXPositionAttribute, av);
        CFRelease(av);

        CGSize s = r.size;
        av = AXValueCreate(kAXValueTypeCGSize, &s);
        AXUIElementSetAttributeValue(win, kAXSizeAttribute, av);
        CFRelease(av);

        CFRelease(wins);
    }
    CFRelease(app);
}

// Frontmost on-screen, layer-0 window ID owned by `pid` (0 if none found).
static CGWindowID frontWindowForPID(pid_t pid) {
    CGWindowID result = 0;
    NSArray *wlist = CFBridgingRelease(
        CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID));
    for (NSDictionary *info in wlist) {
        if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([info[(id)kCGWindowOwnerPID] intValue] != (int)pid) continue;
        result = (CGWindowID)[info[(id)kCGWindowNumber] unsignedIntValue];
        break;
    }
    return result;
}

// Front-to-back index of `wid` among layer-0 windows (-1 if not present).
static int frontIndexOf(CGWindowID wid) {
    NSArray *wlist = CFBridgingRelease(
        CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID));
    int idx = 0;
    for (NSDictionary *info in wlist) {
        if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
        if ((CGWindowID)[info[(id)kCGWindowNumber] unsignedIntValue] == wid) return idx;
        idx++;
    }
    return -1;
}

// Have ALL the member windows landed cleanly on top of every non-member?
//
// We issue the raise via yabai (see slot_yabai_focus), but yabai --focus is
// asynchronous: the command returns before the window-server actually reorders.
// So after issuing we poll this until it's true, THEN unfreeze — otherwise the
// freeze lifts before the reorder lands and the user sees the windows pop in
// one at a time. Two conditions: (1) every member pid owns an on-screen window,
// and (2) no non-member sits above the deepest member window. CGWindowList
// reflects the reorder as it lands even while the display is frozen.
static BOOL membersOnTop(NSSet<NSNumber *> *memberPids, NSString **firstIntruder) {
    NSArray *wlist = CFBridgingRelease(
        CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID));
    NSMutableArray<NSNumber *> *pids  = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableSet<NSNumber *>   *present = [NSMutableSet set];
    for (NSDictionary *info in wlist) {
        if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *pid = info[(id)kCGWindowOwnerPID];
        [pids addObject:pid];
        [names addObject:(info[(id)kCGWindowOwnerName] ?: @"?")];
        if ([memberPids containsObject:pid]) [present addObject:pid];
    }
    if (memberPids.count == 0) return YES;
    if (present.count < memberPids.count) {           // not every member up yet
        if (firstIntruder) *firstIntruder = @"(member not on screen yet)";
        return NO;
    }
    NSInteger last = -1;
    for (NSInteger i = (NSInteger)pids.count - 1; i >= 0; i--)
        if ([memberPids containsObject:pids[i]]) { last = i; break; }
    for (NSInteger i = 0; i < last; i++)
        if (![memberPids containsObject:pids[i]]) {
            if (firstIntruder) *firstIntruder = names[i];
            return NO;
        }
    return YES;
}

// True if frame f matches one of the 7 slot tiles within tolerance — the same
// classification slotlib uses (failsafe/tile_for_geom). A layer-0 window that
// matches no tile and isn't a canon app is a "loose floater": it lives above the
// snapped scene and must never be lowered/buried by a reveal.
static BOOL isTileRect(CGRect f, int sw, int sh) { return tile_index(f, sw, sh) >= 0; }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gT0  = mach_absolute_time();
        gPid = getpid();

        if (argc > 1 && !strcmp(argv[1], "--zoom")) return zoom_glide(argc, argv);
        if (argc > 1 && !strcmp(argv[1], "--standin-test")) return standin_test(argc, argv);

        if (argc < 4) {
            fprintf(stderr, "Usage: scene_restore SW SH app:pos ...\n");
            return 1;
        }

        if (getenv("SCENE_DEBUG"))
            gLog = fopen("/tmp/scene_restore.log", "a");
        dbg("=== scene_restore fired: %s", argv[3]);  // first app as label

        int sw = atoi(argv[1]);
        int sh = atoi(argv[2]);

        // Snapshot running apps once for resolution below.
        NSArray<NSRunningApplication *> *running =
            NSWorkspace.sharedWorkspace.runningApplications;

        // Parse app:pos arguments
        NSMutableArray<NSRunningApplication *> *apps = [NSMutableArray array];
        NSMutableArray<NSValue *>              *rects = [NSMutableArray array];
        // Parallel to apps/rects: was this member positioned at a free-floating
        // geometry (literal "x,y,w,h") rather than snapped to a tile? Floating
        // members are pinned to the `above` sub-layer so they always stay on top.
        NSMutableArray<NSNumber *>             *isFloat = [NSMutableArray array];

        for (int i = 3; i < argc; i++) {
            NSString *arg  = [NSString stringWithUTF8String:argv[i]];
            NSRange colon  = [arg rangeOfString:@":" options:NSBackwardsSearch];
            if (colon.location == NSNotFound) continue;

            NSString *name = [arg substringToIndex:colon.location];
            NSString *pos  = [arg substringFromIndex:colon.location + 1];
            BOOL floating  = [pos containsString:@","];   // literal geom ⇒ unsnapped

            NSRunningApplication *ra = nil;
            for (NSRunningApplication *a in running)
                if ([a.localizedName isEqualToString:name]) { ra = a; break; }
            if (!ra)
                for (NSRunningApplication *a in running) {
                    if (a.activationPolicy != NSApplicationActivationPolicyRegular) continue;
                    if ([a.localizedName containsString:name] ||
                        [name containsString:a.localizedName]) { ra = a; break; }
                }
            if (!ra) { dbg("  app not running: %s", name.UTF8String); continue; }

            CGRect rect;
            if ([pos containsString:@","]) {                // literal "x,y,w,h"
                NSArray<NSString *> *p = [pos componentsSeparatedByString:@","];
                if (p.count == 4)
                    rect = CGRectMake([p[0] doubleValue], [p[1] doubleValue],
                                      [p[2] doubleValue], [p[3] doubleValue]);
                else
                    rect = CGRectMake(0, 0, sw, sh);
            }
            else rect = tile_rect(tile_named(pos.UTF8String), sw, sh);   // unknown → full

            [apps    addObject:ra];
            [rects   addObject:[NSValue valueWithRect:NSRectFromCGRect(rect)]];
            [isFloat addObject:@(floating)];
        }

        if (apps.count == 0) return 0;

        // Solo app WITHOUT the scripting addition: nothing to lower with, so just
        // position and activate (legacy). With the SA, a single app falls through
        // to the general reveal-by-lower path below — activation is not atomic
        // (it raises the app gradually, so a 2-app group recedes one window at a
        // time, the reverse of the multi-window pop-in), whereas lowering the
        // covers reveals the solo app in one frozen composite.
        if (apps.count == 1 && access("/tmp/.yabai_sa_loaded", F_OK) != 0) {
            NSRunningApplication *ra = apps[0];
            CGRect r = NSRectToCGRect([rects[0] rectValue]);
            axPosition(ra.processIdentifier, r);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [ra activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            dbg("  solo activate done (no SA)");
            return 0;
        }

        // ── Pre-freeze: resolve the members' yabai window ids ─────────────────
        // The yabai query + parse has variable latency (can spike past 1s under
        // load), so we do it BEFORE freezing — its cost must not count against
        // the ~1s freeze watchdog. Under the freeze we then issue only the cheap,
        // predictable `yabai -m window <id> --focus`. Args are back→front order.
        NSMutableString *raiseArgs = [NSMutableString string];
        NSMutableSet<NSNumber *> *memberPids = [NSMutableSet set];
        for (NSUInteger i = 0; i < apps.count; i++) {
            CGRect r = NSRectToCGRect([rects[i] rectValue]);
            [raiseArgs appendFormat:@"%d:%d ",
                (int)apps[i].processIdentifier, (int)r.origin.x];
            [memberPids addObject:@(apps[i].processIdentifier)];
        }

        // cadbars handshake state (function scope: used by the Phase 3 cover loop, the
        // Phase 4c bar-hide wait, and Phase 7 thaw).
        BOOL cadCoverHidden = NO;   // a Fusion/SketchUp cover is being lowered this reveal
        BOOL cadbarsPoked   = NO;   // …and cadbars was actually signalled (it's running)

        // A CAD (Fusion/SketchUp) is in the TARGET scene — drives the freeze-frame force
        // (cover the slow viewport redraw when ENTERING) and the render hold (P4b).
        // SUBSTRING match on purpose: Fusion's name flips "Fusion"/"Autodesk Fusion"
        // between launches, so the literal kSlowApps strings miss it half the time.
        BOOL sceneHasCAD = NO;
        for (NSRunningApplication *ra in apps) {
            NSString *n = ra.localizedName ?: @"";
            if ([n containsString:@"Fusion"] || [n containsString:@"SketchUp"]) { sceneHasCAD = YES; break; }
        }

        // ── Phase 0a: FIRE the freeze-frame overlay (cadbars) ─────────────────
        // Cover EVERY user-initiated switch with a pixel-identical still frame so the
        // whole transition is invisible — `freeze force` always covers, CAD or not.
        // Gated on SCENE_FREEZE (set by slotlib only for switch ops: swipe/jump/focus),
        // so background restores (reconcile/winclose/appterm) never flash a frozen frame.
        // Sent NOW — before the resolve query below — so cadbars captures the (still-
        // unchanged) screen CONCURRENTLY with that ~150ms query rather than serially
        // after it; we only WAIT for the cover later (Phase 0b, before any window moves).
        // Kill switch: `touch /tmp/.scene_nofreeze`.
        BOOL freezeFrame = (getenv("SCENE_FREEZE") != NULL)
                        && (access("/tmp/.scene_nofreeze", F_OK) != 0)
                        && sceneHasCAD;
        if (freezeFrame) {
            dbg("  P0a freeze (sceneHasCAD=%d members=%lu)", (int)sceneHasCAD, (unsigned long)apps.count);
            unlink("/tmp/cadbars_frozen");
            FILE *ff = fopen("/tmp/cadbars_fast", "w");
            if (ff) { fputs("freeze force", ff); fclose(ff); }
            freezeFrame = (system("/usr/bin/pkill -USR2 -x cadbars 2>/dev/null") == 0);
        }

        NSMutableArray<NSString *> *winIds = [NSMutableArray array];
        {
            NSString *rcmd = [@"/Users/josh/bin/slot_yabai_focus --resolve "
                              stringByAppendingString:raiseArgs];
            FILE *fp = popen(rcmd.UTF8String, "r");
            if (fp) {
                char buf[512] = {0};
                if (fgets(buf, sizeof(buf), fp)) {
                    NSString *line = [[NSString stringWithUTF8String:buf]
                        stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    for (NSString *t in [line componentsSeparatedByString:@" "])
                        if (t.length) [winIds addObject:t];
                }
                pclose(fp);
            }
            dbg("  resolved %lu win ids: %s", (unsigned long)winIds.count,
                [winIds componentsJoinedByString:@" "].UTF8String);
        }

        CGSConnectionID cid = CGSMainConnectionID();

        // ── Phase 0b: WAIT for the freeze-frame cover to be up ────────────────
        // The capture was fired in Phase 0a (before the resolve query) and ran during
        // it, so this usually returns at once. We hold here — before moving any window —
        // so the entire switch (repositioning, the leaving CAD receding, and the async
        // app-activation ripple that lands AFTER our Phase 5 unfreeze, which the window-
        // server freeze alone can't hide because it must lift to show the new scene) is
        // behind the still frame. Capped well under the freeze watchdog.
        if (freezeFrame) {
            int w = 0;
            while (access("/tmp/cadbars_frozen", F_OK) != 0 && w < 150000) { usleep(2000); w += 2000; }
            dbg("  P0b freeze-frame ack: %s after %dms",
                access("/tmp/cadbars_frozen", F_OK) == 0 ? "up" : "TIMEOUT", w / 1000);
        }

        // ── Phase 1: freeze the (global) display ──────────────────────────────
        CGError freezeErr = CGSDisableUpdate(cid);
        dbg("  P1 freeze  err=%d", (int)freezeErr);

        // ── Phase 2: position every window (AX, cross-process) ────────────────
        // Unhide first: the slot window-close hides an app to remove it from the
        // screen while it stays a member of another slot. When we restore that
        // other slot the app must be unhidden before it can be AX-positioned,
        // otherwise it reappears at its pre-hide location. unhide is a no-op for
        // apps that aren't hidden.
        for (NSRunningApplication *ra in apps) {
            if (ra.isHidden) [ra unhide];
        }
        int npos = 0;
        for (NSUInteger i = 0; i < apps.count; i++) {
            // Don't move free-floating windows: the user positions those by hand,
            // and a reveal must not yank them back to a remembered spot. Snapped
            // members still get tiled. (Floater z-order is handled by the `above`
            // sub-layer in Phase 3.)
            if (i < isFloat.count && isFloat[i].boolValue) continue;
            CGRect r = NSRectToCGRect([rects[i] rectValue]);
            axPosition(apps[i].processIdentifier, r);
            npos++;
        }
        dbg("  P2 positioned %d snapped (skipped %lu floaters)",
            npos, (unsigned long)apps.count - npos);

        // Slow-render app (SketchUp/Fusion) in the scene → their Metal/GL viewports need
        // extra draw time after activation (P4b hold). Reuse sceneHasCAD (robust substring
        // detection; the old literal kSlowApps match missed the "Fusion" name flip).
        BOOL hasSlowApp = sceneHasCAD;

        // ── Phase 3: reveal the group, WHILE frozen ───────────────────────────
        // Two strategies, chosen by whether the scripting addition is loaded.
        //
        // The problem with raising: `yabai -m window <id> --focus` raises AND
        // activates the owning app, and macOS settles sequential app-activations
        // ASYNCHRONOUSLY — measured ~200ms apart on this machine. So raising the
        // members one by one makes the last-raised (the previously-active window)
        // climb to the front a beat after the others: the user's "one appears,
        // then the other appears later" pop-in. Holding the freeze longer does
        // not help — the late reorder happens at/after unfreeze (the SA query
        // even reports the group briefly clean before the activation re-shuffles).
        //
        // SA path — reveal by LOWERING the cover, not raising the group. Pull the
        // members to a clean `normal` sub-layer baseline (undoing any `below`
        // from when one was previously a cover), then push every window that
        // currently covers them into yabai's `below` sub-layer in a single pass.
        // A `below` window CANNOT be lifted back above a `normal` one by app
        // activation, so the reveal is atomic and stays put — the activate-fight
        // is structurally impossible. Members stay at `normal`, so floaters
        // (Finder dialogs, raised later) still land above them. Finally focus the
        // target window for keyboard input; it is already on top, so the focus
        // adds no re-stagger. Cover/baseline state is derived live from the
        // window list each time, so no slot-side bookkeeping is needed.
        //
        // No-SA path — keep the legacy raise: background the `--focus` calls and
        // poll until they land, bounded under the ~1s CGSDisableUpdate watchdog.
        BOOL saLoaded = (access("/tmp/.yabai_sa_loaded", F_OK) == 0);
        double t_activated = ms_since_start();
        // Set in the SA reveal below, executed in Phase 8 (after the thaw) so the
        // focus round-trip doesn't count toward the frozen-frame dwell.
        NSString *deferredFocusId = nil;
        NSRunningApplication *deferredFocusApp = nil;   // fallback when yabai can't focus
        if (saLoaded && winIds.count > 0) {
            // Tier every member by sub-layer: floating (unsnapped) members → `above`
            // so they always stay on top; snapped members → `normal`. Covers (other
            // spaces' windows) get pushed to `below` next. A `normal` window can't be
            // lifted above an `above` one by activation, so the focus call below
            // keeps the floaters on top. isFloat is parallel to winIds (both follow
            // the apps order); guard the count in case resolve dropped an id.
            NSMutableString *tier = [NSMutableString string];
            NSMutableSet<NSNumber *> *memberWins = [NSMutableSet set];
            // winIds is now POSITIONALLY aligned with isFloat: slot_yabai_focus
            // --resolve emits "-" for any member pid it couldn't resolve to a
            // window (rather than dropping it), so winIds[i] still pairs with
            // isFloat[i]. Skipping the alignment (the old compaction) let a
            // snapped member inherit a dropped floater's `above` flag and bury the
            // rest of the scene behind it — e.g. Claude stuck over Fusion after a
            // swipe when an injected Finder floater had no window. Skip the "-".
            for (NSUInteger i = 0; i < winIds.count; i++) {
                NSString *wid = winIds[i];
                if ([wid isEqualToString:@"-"]) continue;
                [memberWins addObject:@(wid.intValue)];
                BOOL floating = (i < isFloat.count) && isFloat[i].boolValue;
                [tier appendFormat:
                    @"/usr/local/bin/yabai -m window %@ --sub-layer %s 2>/dev/null; ",
                    wid, floating ? "above" : "normal"];
            }
            system(tier.UTF8String);

            // covers = layer-0 windows sitting above the DEEPEST member
            NSArray *wlist = CFBridgingRelease(CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                kCGNullWindowID));
            NSMutableArray<NSNumber *> *layer0 = [NSMutableArray array];
            NSMutableArray<NSNumber *> *layer0pid = [NSMutableArray array];
            NSMutableArray<NSValue  *> *layer0rect = [NSMutableArray array];
            NSMutableArray<NSString *> *layer0owner = [NSMutableArray array];
            for (NSDictionary *info in wlist) {
                if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
                [layer0 addObject:info[(id)kCGWindowNumber]];
                [layer0pid addObject:info[(id)kCGWindowOwnerPID]];
                CGRect wr = CGRectZero;
                CGRectMakeWithDictionaryRepresentation(
                    (CFDictionaryRef)info[(id)kCGWindowBounds], &wr);
                [layer0rect addObject:[NSValue valueWithRect:NSRectFromCGRect(wr)]];
                [layer0owner addObject:(info[(id)kCGWindowOwnerName] ?: @"?")];
            }
            // Canon (sequence) apps are snapped-only, so a cover owned by one is a
            // different-space tile to lower, never a floater. Names are the open-
            // names slotlib passes via SLOT_CANON_NAMES (newline-separated).
            NSMutableSet<NSString *> *canon = [NSMutableSet set];
            { const char *cz = getenv("SLOT_CANON_NAMES");
              if (cz) for (NSString *n in [[NSString stringWithUTF8String:cz]
                                            componentsSeparatedByString:@"\n"])
                  if (n.length) [canon addObject:n]; }

            // Fusion's companion windows (config/fusion_companions) in a slot that
            // does not hold Fusion: never floaters here — they are Fusion's, so they
            // go under the scene like any other cover (slotlib passes the names only
            // when Fusion is NOT a member of the slot being shown).
            NSMutableSet<NSString *> *bury = [NSMutableSet set];
            { const char *bz = getenv("SLOT_BURY_NAMES");
              if (bz) for (NSString *n in [[NSString stringWithUTF8String:bz]
                                            componentsSeparatedByString:@"\n"])
                  if (n.length) [bury addObject:n]; }

            NSInteger deepest = -1;
            for (NSInteger i = 0; i < (NSInteger)layer0.count; i++)
                if ([memberWins containsObject:layer0[i]]) deepest = i;
            NSMutableString *lower = [NSMutableString string]; int ncov = 0;
            NSMutableString *floatUp = [NSMutableString string]; int nup = 0;
            for (NSInteger i = 0; i < deepest; i++) {
                // Skip the members themselves AND any other window owned by a
                // member's app (e.g. Fusion's palette windows share the document
                // window's pid) — lowering those would strand the app's own UI.
                if ([memberWins containsObject:layer0[i]]) continue;
                if ([memberPids containsObject:layer0pid[i]]) continue;
                // Skip the CAD overlay bars (cadbars). They are NOT in yabai's
                // managed set, so `yabai window --sub-layer` against them fails the
                // window lookup — and that failed lookup can take ~700ms+, which
                // here runs INSIDE the display freeze and stalls the whole reveal
                // for over a second (the "can't switch when Fusion is involved"
                // bug). cadbars owns its own sub-layer and rides the CAD window's
                // space itself, so scene_restore must never touch its windows —
                // exactly as pin_loose_above / win_list_raw / window_event.sh skip
                // them elsewhere.
                if ([layer0owner[i] isEqualToString:@"cadbars"]) continue;
                // A LOOSE FLOATER covering the scene must never be buried — it
                // lives above the snapped scene (floaters-always-on-top). Loose =
                // non-canon owner whose frame matches no tile. Pin it `above`
                // instead of lowering it; only true snapped covers go `below`.
                CGRect wr = NSRectToCGRect([layer0rect[i] rectValue]);
                if (![canon containsObject:layer0owner[i]] && !isTileRect(wr, sw, sh)
                    && ![bury containsObject:layer0owner[i]]) {
                    [floatUp appendFormat:
                        @"/usr/local/bin/yabai -m window %@ --sub-layer above 2>/dev/null; ",
                        layer0[i]];
                    nup++;
                    continue;
                }
                // This `--sub-layer below` is how EVERY cover is hidden, Fusion and
                // SketchUp included — there is deliberately NO CAD special-case here.
                //
                // If a Fusion/SketchUp cover ever bleeds through (stays on top of the
                // revealed split because this silently fails with "could not locate the
                // window to act on!"), the cause is NOT scene_restore — it's that yabai
                // lost its AX observation of that window (`has-ax-reference=false`,
                // `role=''`), which happens because Fusion is a Qt app whose canvas
                // races yabai's observer at creation. The window is a perfectly normal
                // AXStandardWindow; yabai just isn't tracking it. The fix is to make
                // yabai re-observe it (one-time `yabai --restart-service`), which is what
                // Scripts/fusion_observe_heal.sh does, wired into yabairc on Fusion
                // launch + at yabai start. DO NOT "fix" a bleed by hiding the app or
                // activating the members here — both were tried and reverted: hiding
                // flickers the app out of Cmd-Tab, and activating the members raises them
                // via async app activation whose tail lands after the unfreeze = a
                // one-window-before-the-other stagger. Heal the observation instead.
                [lower appendFormat:
                    @"/usr/local/bin/yabai -m window %@ --sub-layer below 2>/dev/null; ",
                    layer0[i]];
                ncov++;
                // A CAD app is leaving the foreground (its window is a cover we're
                // burying). Its cadbars overlay lives in a separate process and would
                // otherwise drop a frame or two AFTER this reveal composites — the
                // bars flashing over the target. Flag it so we poke cadbars to lower
                // the bars NOW, while still frozen (Phase 4c). (Owner name is unstable
                // for Fusion — "Fusion" or "Autodesk Fusion" — so match a substring.)
                if ([layer0owner[i] containsString:@"Fusion"] ||
                    [layer0owner[i] containsString:@"SketchUp"])
                    cadCoverHidden = YES;
            }
            // Diagnostics (kept on purpose — this is the hard-to-reason-about part of
            // the reveal). With SCENE_DEBUG the log shows the exact front→back stack the
            // cover pass saw (`*`=member, `[DEEP]`=deepest member) and the per-call
            // sub-layer timing — enough to tell a real bleed (a CAD cover still on top)
            // from an observation gap, without re-instrumenting.
            if (getenv("SCENE_DEBUG")) {
                NSMutableString *stk = [NSMutableString string];
                for (NSInteger i = 0; i < (NSInteger)layer0.count; i++) {
                    BOOL mem = [memberWins containsObject:layer0[i]];
                    [stk appendFormat:@"%@%@%@ ", i==deepest?@"[DEEP]":@"",
                        mem?@"*":@"", layer0owner[i]];
                }
                dbg("    stack(front→back, deepest=%ld): %s", (long)deepest, stk.UTF8String);
            }
            double t_fu0 = ms_since_start();
            if (floatUp.length) system(floatUp.UTF8String);
            double t_fu1 = ms_since_start();
            if (lower.length) system(lower.UTF8String);
            double t_lo1 = ms_since_start();
            dbg("    sublayer calls: floatUp(%d)=%.0fms lower(%d)=%.0fms",
                nup, t_fu1 - t_fu0, ncov, t_lo1 - t_fu1);

            // CAD overlay (cadbars) bleed fix — poke as early as possible so cadbars
            // lowers its bars WHILE we hold the freeze. Its SLSSetWindowSubLevel can't
            // composite until our Phase 5 unfreeze, so the single reveal composite
            // shows the target already clean. cadbars owns its bars in another process
            // (yabai can't touch them — see the cadbars skip above), so we can't lower
            // them here; we signal it and wait (capped, Phase 4c) for its sentinel.
            // pkill returns 0 only if cadbars is actually running — gate the wait on it
            // so a toggled-off cadbars never costs us the timeout.
            if (cadCoverHidden) {
                unlink("/tmp/cadbars_done");
                FILE *cf = fopen("/tmp/cadbars_fast", "w");
                if (cf) { fputs("hide", cf); fclose(cf); }
                int rc = system("/usr/bin/pkill -USR2 -x cadbars 2>/dev/null");
                cadbarsPoked = (rc == 0);
                dbg("    cadbars hide poke: %s", cadbarsPoked ? "sent" : "no proc");
            }

            // keyboard focus → the target (last REAL) window. Sub-layers fix the
            // z-order structurally, so focusing the target can't pull it above the
            // floaters. Skip a trailing "-" placeholder (focus member unresolved).
            NSString *focusId = nil;
            for (NSString *w in winIds) if (![w isEqualToString:@"-"]) focusId = w;
            // The TARGET itself unresolved but on screen (yabai lost its AX handle —
            // Fusion's canvas does this, see fusion_observe_heal.sh): don't hand focus
            // to an earlier member; Phase 8 activates the target app directly instead.
            NSRunningApplication *target = apps.lastObject;
            if (frontWindowForPID(target.processIdentifier) != 0) {
                if (winIds.count == apps.count && [winIds.lastObject isEqualToString:@"-"])
                    focusId = nil;
                deferredFocusApp = target;
            }
            // DON'T focus here. The sub-layer pass above already put the target on top,
            // so `--focus` is keyboard-only now and can't restack the (non-overlapping)
            // tiles — but it IS a synchronous yabai round-trip (~tens–150ms under switch-
            // time queue contention). Running it under the freeze widens the frozen-frame
            // dwell for no visible gain. Defer to Phase 8, after the thaw.
            deferredFocusId = focusId;
            int nfloat = 0;
            for (NSNumber *f in isFloat) if (f.boolValue) nfloat++;
            dbg("  P3 reveal sa: members=%lu floaters=%d covers=%d floatUp=%d focus=%s",
                (unsigned long)winIds.count, nfloat, ncov, nup,
                focusId ? focusId.UTF8String : "-");
        } else if (winIds.count > 0) {
            NSMutableString *fcmd = [NSMutableString string];
            for (NSString *wid in winIds) {
                if ([wid isEqualToString:@"-"]) continue;  // unresolved pid
                [fcmd appendFormat:
                    @"/usr/local/bin/yabai -m window %@ --focus 2>/dev/null; ", wid];
            }
            NSString *bg = [NSString stringWithFormat:@"( %@ ) &", fcmd];
            system(bg.UTF8String);
            int polls = 0; BOOL clean = NO; NSString *intruder = nil;
            for (; polls < kLandMaxPolls; polls++) {
                intruder = nil;
                if (membersOnTop(memberPids, &intruder)) { clean = YES; break; }
                usleep(kPollInterval);
            }
            dbg("  P3 raise (legacy) clean=%s polls=%d (~%.0fms)",
                clean ? "yes" : "NO(capped)", polls, (double)polls * kPollInterval / 1000.0);
        }

        // ── Phase 4b: slow-render hold ────────────────────────────────────────
        // The stacking-order poll exits as soon as window positions are correct,
        // but Metal/GL viewports (SketchUp, Fusion) need more time to actually
        // draw their first frame. Hold the freeze until kSlowRenderMs have
        // elapsed since activation so the unfreeze reveals a fully-rendered scene.
        // DIAGNOSTIC: /tmp/scene_render_ms, if present, overrides the hold and
        // applies it to EVERY multi-window restore (not just CAD). This is to
        // pin down the residual pop-in: if a longer hold removes it, the windows
        // ARE redrawing under the freeze and we just need more budget; if even a
        // large value does nothing, the redraw is deferred until the window is
        // actually revealed (post-unfreeze) and the real fix is to pre-render the
        // target windows before the switch (the staging approach). Change the
        // value with `echo 600 > /tmp/scene_render_ms`; remove the file to revert.
        int  renderMs  = kSlowRenderMs;
        BOOL forceAll  = NO;
        { FILE *rf = fopen("/tmp/scene_render_ms", "r");
          if (rf) { int v; if (fscanf(rf, "%d", &v) == 1) { renderMs = v; forceAll = YES; }
                    fclose(rf); } }
        if (hasSlowApp || forceAll) {
            double elapsed = ms_since_start() - t_activated;
            double remaining = renderMs - elapsed;
            if (remaining > 0) {
                dbg("  P4b render hold: %.0fms remaining of %dms (forceAll=%d)",
                    remaining, renderMs, (int)forceAll);
                usleep((useconds_t)(remaining * 1000));
            } else {
                dbg("  P4b render hold: already elapsed (%.0fms >= %dms, forceAll=%d)",
                    elapsed, renderMs, (int)forceAll);
            }
        }

        // ── Phase 4c: cadbars handshake — wait for the bars to drop before unfreeze
        // cadbars writes /tmp/cadbars_done from its SIGUSR2 handler once it has lowered
        // the bars' sub-level (a synchronous window-server write that's queued behind
        // our freeze). Waiting for it means the single Phase 5 composite shows the bars
        // already hidden — no flash over the target. Capped tiny and far under the ~1s
        // freeze watchdog; the render hold above usually already gave cadbars its time,
        // so in practice this returns immediately.
        if (cadbarsPoked) {
            int waited = 0;
            while (access("/tmp/cadbars_done", F_OK) != 0 && waited < 80000) {
                usleep(2000); waited += 2000;
            }
            dbg("  P4c cadbars handshake: %s after %dms",
                access("/tmp/cadbars_done", F_OK) == 0 ? "confirmed" : "TIMEOUT",
                waited / 1000);
        }

        // ── Phase 5: unfreeze — one composite reveals the finished scene ──────
        CGError unfreezeErr = CGSReenableUpdate(cid);
        dbg("  P5 unfreeze err=%d", (int)unfreezeErr);

        // Phase 6 (focus re-assert) intentionally removed — yabai in do_restore
        // owns focus now, and an activateWithOptions here would only race it.

        // ── Phase 7: thaw the freeze-frame overlay (cadbars) ──────────────────
        // Hold the still frame a touch past the unfreeze so the post-unfreeze async
        // app-activation ripple settles BEHIND it, then drop it in one clean cut.
        // cadbars' own 1.5s watchdog is the backstop if this thaw never lands.
        if (freezeFrame) {
            // Hold the still frame a touch past the unfreeze so the post-unfreeze ripple
            // settles behind it, then cut. 55ms tuned by feel (snappy but still clean).
            // Tunable live while watching: /tmp/cadbars_thaw_ms (leave/normal) and
            // /tmp/cadbars_thaw_cad_ms (entering a CAD — separate so tuning one viewport-
            // heavy case can't regress the other). `echo 90 > /tmp/cadbars_thaw_ms`.
            int thawMs = 55;
            const char *tf_path = sceneHasCAD ? "/tmp/cadbars_thaw_cad_ms" : "/tmp/cadbars_thaw_ms";
            { FILE *tf = fopen(tf_path, "r");
              if (tf) { int v; if (fscanf(tf, "%d", &v) == 1) thawMs = v; fclose(tf); } }
            if (thawMs > 0) usleep((useconds_t)thawMs * 1000);
            FILE *tf = fopen("/tmp/cadbars_fast", "w");
            if (tf) { fputs("thaw", tf); fclose(tf); }
            system("/usr/bin/pkill -USR2 -x cadbars 2>/dev/null");
            dbg("  P7 freeze-frame thaw sent (held +%dms)", thawMs);
        }

        // ── Phase 8: deferred keyboard focus — AFTER the frame is dropping ─────
        // Moved out of the frozen Phase 3 reveal so its yabai round-trip no longer
        // adds to the still-frame dwell. The sub-layer pass already fixed z-order, so
        // this sets keyboard focus only — no visible restack. (The no-SA path focuses
        // in its own raise loop and never sets deferredFocusId, so it's unaffected.)
        // If yabai can't act on the window ("could not locate the window") the app is
        // revealed but never activated — keyboard stays on the previous slot's app, and
        // anything keyed to activation (FusionDock's show) never fires. Activate the
        // app directly then; it's already on top, so this restacks nothing visible.
        BOOL focused = NO;
        if (deferredFocusId) {
            NSString *fc = [NSString stringWithFormat:
                @"/usr/local/bin/yabai -m window %@ --focus 2>/dev/null", deferredFocusId];
            focused = (system(fc.UTF8String) == 0);
            dbg("  P8 deferred focus → %s (%s)", deferredFocusId.UTF8String, focused ? "ok" : "FAILED");
        }
        if (!focused && deferredFocusApp && !deferredFocusApp.active) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [deferredFocusApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            dbg("  P8 fallback activate → %s", deferredFocusApp.localizedName.UTF8String);
        }

        dbg("  done (positioned %lu, z-order/focus → yabai)  total=%.1fms",
            (unsigned long)apps.count, ms_since_start());
    }
    return 0;
}

// ── Zoom glide (ui_zoom.sh § Screen zoom) ─────────────────────────────────────
//   scene_restore --zoom SW SH TO SECS
//
// Glides the window server's screen zoom from wherever it is to TO (1 = off),
// pinned top-left, and keeps every tiled window on screen fitted to its tile of the
// VISIBLE rect (SW/z × SH/z — SW SH = the unzoomed screen in points) on every frame:
// a full window always fills the screen, a left/right pair always splits it, while
// the content grows. The zoom ticks at the panel's 165 Hz on its own steady clock and
// the windows follow the same curve, two ways:
//   • Windows pinned at the left (full, left, left quadrants) only change SIZE: each has
//     its own queue that keeps setting it (AX) to the LATEST target — one set in flight,
//     coalesced, so a slow app skips sizes instead of queueing them. Smooth: AX resizes
//     that leave the origin alone are (Claude, measured by eye 2026-10-20).
//   • The front window off the left edge (right / right quadrants) is LIVE-RESIZED: a
//     real drag on its bottom-right corner, posted into the session event stream, with
//     its position moved alongside (AX). Only a real drag puts an app in live resize,
//     where it holds each frame until its content is redrawn at the new size; an AX
//     resize doesn't, and Chrome's page visibly jumped. (Events posted to the app's pid
//     don't start one; AppKit sizes the drag from the window's CURRENT origin, so moving
//     it mid-drag is fine — both measured 2026-10-20.) One mouse, so one window. The
//     real pointer does the drag hidden, a stand-in image of it is drawn where it was,
//     and trackpad motion is ignored for the glide (it would fight the drag).
// No overhangs: an edge reaching past its tile has to come back at the end, which
// changes the window's width once more — a reflow jump. Tried and dropped
// 2026-10-20: a per-frame display freeze waiting on every app (lockstep, uneven
// frames: jitter); the zoom following the slowest window (judder); the server's own
// animated zoom (2nd double: smooth but leads the windows). Windows fully behind
// others are sized once, at the end. The tick thread only sets targets and the zoom
// (real-time priority); window-server reads live on a sampler thread — on the tick
// they stalled the zoom 40–100 ms at a time (2026-10-20). Prints the final visible
// "W H" (screen_dims).

#include <stdatomic.h>
#include <signal.h>
#include <notify.h>
#include "screen_frame.h"


typedef struct {
    AXUIElementRef win; CGWindowID wid; int tile; BOOL hidden;
    int order;                           // front-to-back position among on-screen windows
    BOOL dragged;                        // live-resized by the drag: AX moves it, never sizes it
    useconds_t pace;                     // least time between two sets (an app that blanks while it repaints)
    char bundle[96];                     // the app's bundle id (its lag is remembered under it)
    double lead;                         // s: how far ahead on the curve its target is sent
    // Lag measuring: the widths sent and when, and the gaps seen until they showed up.
    double issT[512]; int issW[512], lastSeen; _Atomic int nIss;
    CGPoint setAt;                       // the origin last set (moves only when it changes)
    double lag[512]; int nLag;
    dispatch_queue_t q;
    _Atomic int busy;                    // a set is in flight on q
    _Atomic int64_t want;                // target visible size, (sw << 32) | sh; -1 none
    _Atomic int done;                    // sets completed (SCENE_DEBUG: each app's resize rate)
} ZoomWin;

static _Atomic double gZoomShown;          // the zoom on screen now (for the sampler)
static _Atomic int gZoomSampling;

// The tick thread as a real-time one (like audio / display threads): at default
// priority it was descheduled for tens of ms while the apps it drives were busy.
static void zoom_realtime(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double ms = 1e6 * tb.denom / tb.numer;             // absolute-time units per ms
    thread_time_constraint_policy_data_t p = {
        .period = (uint32_t)(ms * 1000 / 165), .computation = (uint32_t)(ms * 1),
        .constraint = (uint32_t)(ms * 4), .preemptible = 1 };
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY,
                      (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static void zoom_set(ZoomWin *w, int64_t want) {
    int sw = (int)(want >> 32), sh = (int)(want & 0xffffffff);
    CGRect r = tile_rect(w->tile, sw, sh);
    // Only when it moves: each AX set is a round trip through the app's main thread,
    // and a window pinned at the left would spend half its sets on a no-op move.
    if (!CGPointEqualToPoint(r.origin, w->setAt)) {
        AXValueRef p = AXValueCreate(kAXValueTypeCGPoint, &r.origin);
        AXUIElementSetAttributeValue(w->win, kAXPositionAttribute, p);
        CFRelease(p);
        w->setAt = r.origin;
    }
    if (w->dragged) return;
    AXValueRef s = AXValueCreate(kAXValueTypeCGSize, &r.size);
    AXUIElementSetAttributeValue(w->win, kAXSizeAttribute, s);
    CFRelease(s);
}

// The live-resize drag's mouse button, so a kill mid-glide can let go of it.
static _Atomic int gZoomDragDown = 0;
static void zoom_drag_post(CGEventType type, CGPoint p) {
    static CGEventSourceRef src;
    if (!src) src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef e = CGEventCreateMouseEvent(src, type, p, kCGMouseButtonLeft);
    CGEventPost(kCGSessionEventTap, e);
    CFRelease(e);
}
static void zoom_drag_abort(int sig) {
    if (atomic_exchange(&gZoomDragDown, 0)) {
        CGEventRef e = CGEventCreate(NULL); CGPoint p = CGEventGetLocation(e); CFRelease(e);
        zoom_drag_post(kCGEventLeftMouseUp, p);
    }
    CGAssociateMouseAndMouseCursorPosition(true);
    _exit(128 + sig);
}

// Bring w to its latest target: one worker per window, which re-reads the target after
// each set, so a slow app skips the sizes it was too slow for instead of queueing them.
static void zoom_push(ZoomWin *w) {
    if (atomic_exchange(&w->busy, 1)) return;          // the running worker will see it
    dispatch_async(w->q, ^{
        int64_t done = -1;
        for (;;) {
            int64_t want = atomic_load(&w->want);
            if (want != done && want >= 0) {
                zoom_set(w, want); done = want;
                atomic_fetch_add(&w->done, 1);
                if (w->pace) usleep(w->pace);
                continue;
            }
            atomic_store(&w->busy, 0);
            if (atomic_load(&w->want) == done || atomic_exchange(&w->busy, 1)) return;
        }
    });
}

static double zoom_now(CGSConnectionID cid) {
    CGPoint c; double s = 1; unsigned char sm;
    if (CGSGetZoomParameters(cid, &c, &s, &sm) || s < 1) s = 1;
    return s;
}

// Each app's resize lag (s), learned from past glides: "<bundle id> <seconds>" lines.
// An app lands a size ~35 ms (Claude) to ~70 ms (Chrome) after it is sent (measured
// 2026-10-20); sending each window its target that far ahead on the curve lands it on
// the frame the zoom shows that size.
#define ZOOM_LAG_FILE "/tmp/.zoom_lag"
static double zoom_lag_get(const char *bundle) {
    FILE *f = fopen(ZOOM_LAG_FILE, "r");
    char b[128]; double s, found = 0.04;               // unknown app: a middling guess
    while (f && fscanf(f, "%127s %lf", b, &s) == 2) if (!strcmp(b, bundle)) found = s;
    if (f) fclose(f);
    return found;
}
static void zoom_lag_put(const char *bundle, double s) {
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    FILE *f = fopen(ZOOM_LAG_FILE, "r");
    char b[128]; double v;
    while (f && fscanf(f, "%127s %lf", b, &v) == 2) all[@(b)] = @(v);
    if (f) fclose(f);
    all[@(bundle)] = @(s);
    f = fopen(ZOOM_LAG_FILE, "w");
    for (NSString *k in all) fprintf(f, "%s %.4f\n", k.UTF8String, [all[k] doubleValue]);
    if (f) fclose(f);
}
static double zoom_curve(double from, double to, double t) {   // WindowShell's S-curve
    if (t > 1) t = 1;
    if (t < 0) t = 0;
    double e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
    return from + (to - from) * e;
}

// ── Stand-in glide (the default) ─────────────────────────────────────────────────
// Apps can't resize smoothly from outside (each lands frames at its own uneven pace,
// and an AX resize shows the new frame before its content), so during the glide every
// visible window is covered by snapshots of ITSELF that we lay out, in our own window,
// in step with the zoom on every tick. The snapshots are cut into parts that move the
// way the app's own layout moves when it is resized (ui_zoom/stand_in.json — per app:
// a sidebar stays at the left, the composer at the bottom, a panel at the right…).
//   A — the window as it was, laid out at each in-between size.
//   B — the window at its FINAL size: it is resized once, right away, out of sight
//       under the stand-in, then snapshotted — again and again until the glide is
//       over, so B is never a half-repainted picture; B fades in over A as it runs.
// Where the parts are is MEASURED on each snapshot (stand_in.json `scans`: the
// sidebar's edge, the composer's sides…), A and B separately, and blended A→B in step
// with B's fade — never hard-coded, so the cut matches the interface at any zoom.
// At the end B is laid out at the final size, which is exactly what the real window
// shows underneath, so the stand-in can go without a visible change. Parts that
// don't move between A and B (sidebar, header…) look the same in both, so only
// what reflows (text) cross-fades.
typedef CGImageRef (*SnapFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
static SnapFn gSnap;                               // CGWindowListCreateImage (gone from the SDK, not the OS)
static CGImageRef si_snap(CGWindowID wid) {        // the window's own pixels, even when covered
    return gSnap ? gSnap(CGRectNull, kCGWindowListOptionIncludingWindow, wid,
                         kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution) : NULL;
}

static double sx_num(id e, NSDictionary *vars) {   // a recipe number or NSExpression
    if ([e isKindOfClass:[NSNumber class]]) return [e doubleValue];
    static NSMutableDictionary *cache;
    // The tick and every B capture thread evaluate recipes at once.
    @synchronized ([NSExpression class]) {
        if (!cache) cache = [[NSMutableDictionary alloc] init];
        NSExpression *x = cache[e];
        if (!x) {
            @try { x = [NSExpression expressionWithFormat:e]; }
            @catch (NSException *ex) {
                fprintf(stderr, "stand_in: bad expression '%s'\n", [e description].UTF8String);
                x = [NSExpression expressionForConstantValue:@0];
            }
            cache[e] = x;
        }
        id v = nil;
        @try { v = [x expressionValueWithObject:nil context:(NSMutableDictionary *)vars]; }
        @catch (NSException *ex) { v = @0; }
        return [v doubleValue];
    }
}

static CGRect si_rect(NSArray *r, NSDictionary *v) {
    double l = sx_num(r[0], v), t = sx_num(r[1], v), rr = sx_num(r[2], v), b = sx_num(r[3], v);
    return CGRectMake(l, t, fmax(0, rr - l), fmax(0, b - t));
}

// One pixel of the snapshot at point (x, y), in the image's own colour space.
static CGColorRef si_colour(CGImageRef im, double scale, double x, double y, unsigned char out[4]) {
    long iw = (long)CGImageGetWidth(im), ih = (long)CGImageGetHeight(im);
    long px = MAX(0, MIN(iw - 1, lround(x * scale))), py = MAX(0, MIN(ih - 1, lround(y * scale)));
    CGColorSpaceRef cs = CGImageGetColorSpace(im);
    if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    else CGColorSpaceRetain(cs);
    unsigned char buf[4] = { 0 };
    CGContextRef c = CGBitmapContextCreate(buf, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
    CGImageRef one = CGImageCreateWithImageInRect(im, CGRectMake(px, py, 1, 1));
    if (c && one) CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), one);
    if (one) CGImageRelease(one);
    if (c) CGContextRelease(c);
    if (out) memcpy(out, buf, 4);
    CGFloat comp[4] = { buf[0] / 255.0, buf[1] / 255.0, buf[2] / 255.0, 1 };
    CGColorRef col = CGColorCreate(cs, comp);
    CGColorSpaceRelease(cs);
    return col;                                    // +1
}

typedef struct {
    CALayer *clip, *img;                           // img nil: a plain fill
    CGRect src;                                    // its rect in the snapshot
    BOOL there;                                    // its 'when' held at the snapshot's size
    double hold;                                   // s it stays after the glide (a mask)
} SIPart;

typedef struct {                                   // one snapshot, laid out by a recipe
    CALayer *layer;
    NSDictionary *recipe;
    NSDictionary *meas;                            // its probes + scans, at its own size
    double W0, H0;                                 // that size
    double z0;                                     // the screen zoom it was taken at (`freeze` parts)
    int np; SIPart part[24];
} SILook;

// ── Reading the snapshot (where its interface really is) ─────────────────────────
// The recipes don't hard-code where things are: each snapshot is measured — its
// sidebar's edge, its composer's sides, its panel… (stand_in.json `scans`) — so the
// cut follows the interface as it is at THAT size, whatever the zoom, the sidebar
// width or the panel. A and B are measured separately, and in between each value
// glides from where A has it to where B has it (si_blend), relative to the edge it
// hangs from: so at the start the cut is exactly A, at the end exactly B.
typedef struct {
    unsigned char *px;                             // RGBA rows, top first, in the image's colour space
    long w, h;                                     // pixels
    double scale;                                  // pixels per point
    CGColorSpaceRef cs;
} SIPix;

static SIPix si_pix(CGImageRef im, double ptW) {
    SIPix p = { 0 };
    p.w = (long)CGImageGetWidth(im); p.h = (long)CGImageGetHeight(im);
    p.scale = ptW > 0 ? p.w / ptW : 1;
    CGColorSpaceRef cs = CGImageGetColorSpace(im);
    if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    else CGColorSpaceRetain(cs);
    p.cs = cs;
    p.px = calloc((size_t)(p.w * p.h), 4);
    CGContextRef c = p.px ? CGBitmapContextCreate(p.px, p.w, p.h, 8, p.w * 4, cs, kCGImageAlphaPremultipliedLast) : NULL;
    if (c) {
        CGContextSetBlendMode(c, kCGBlendModeCopy);
        CGContextDrawImage(c, CGRectMake(0, 0, p.w, p.h), im);
        CGContextRelease(c);
    }
    return p;
}
static void si_pix_free(SIPix *p) {
    free(p->px);
    if (p->cs) CGColorSpaceRelease(p->cs);
    memset(p, 0, sizeof *p);
}
static const unsigned char *si_at(const SIPix *p, double x, double y) {   // point (x, y), top-left origin
    static const unsigned char none[4] = { 0 };
    if (!p->px) return none;
    long px = MAX(0, MIN(p->w - 1, lround(x * p->scale))), py = MAX(0, MIN(p->h - 1, lround(y * p->scale)));
    return p->px + (py * p->w + px) * 4;
}
static int si_dif(const unsigned char *a, const unsigned char *b) {
    return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]);
}
#define SI_EDGE 24                                 // a colour step that counts as an edge (sum of RGB)
static CGColorRef si_pcolour(const SIPix *p, double x, double y) {   // +1
    const unsigned char *c = si_at(p, x, y);
    CGFloat comp[4] = { c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, 1 };
    return CGColorCreate(p->cs, comp);
}
// The picture as a grid of 32 px block hashes: how much of it changed between two
// captures (a caret or a spinner is a block or two; a reflow is most of them).
#define SI_BLOCK 32
static uint64_t *si_blocks(const SIPix *p, long *n) {
    long bx = (p->w + SI_BLOCK - 1) / SI_BLOCK, by = (p->h + SI_BLOCK - 1) / SI_BLOCK;
    *n = p->px ? bx * by : 0;
    uint64_t *b = calloc(MAX(1, *n), sizeof *b);
    for (long y = 0; p->px && y < p->h; y++) {
        const uint32_t *row = (const uint32_t *)(p->px + y * p->w * 4);
        uint64_t *br = b + (y / SI_BLOCK) * bx;
        for (long x = 0; x < p->w; x++) {
            uint64_t *h = &br[x / SI_BLOCK];
            *h = (*h ^ row[x]) * 1099511628211ULL + 1;
        }
    }
    return b;
}
static long si_changed(const uint64_t *a, const uint64_t *b, long n) {   // blocks that differ
    long c = 0;
    for (long i = 0; i < n; i++) c += a[i] != b[i];
    return c;
}
// The changed blocks' bounding box in points (log).
static CGRect si_changed_box(const uint64_t *a, const uint64_t *b, long n, const SIPix *p) {
    long bx = (p->w + SI_BLOCK - 1) / SI_BLOCK;
    CGRect r = CGRectNull;
    for (long i = 0; i < n; i++)
        if (a[i] != b[i])
            r = CGRectUnion(r, CGRectMake((i % bx) * SI_BLOCK / p->scale, (i / bx) * SI_BLOCK / p->scale,
                                          SI_BLOCK / p->scale, SI_BLOCK / p->scale));
    return r;
}

// One scan (stand_in.json `scans`: [name, anchor, kind, args…, default]).
static double si_scan(const SIPix *p, NSArray *s, NSDictionary *v) {
    NSString *kind = s[2];
    NSUInteger n = s.count;
    double dflt = sx_num(s[n - 1], v);
#define ARG(i) ((i) < n - 1 ? sx_num(s[i], v) : 0)
    if ([kind isEqualToString:@"vline"] || [kind isEqualToString:@"hline"]) {
        // [a0, a1, b0, b1, share]: the first position a in [a0, a1) where the most of the
        // samples b in [b0, b1) step in colour from a-1 to a, if at least `share` of them do.
        BOOL vert = [kind isEqualToString:@"vline"];
        double a0 = ARG(3), a1 = ARG(4), b0 = ARG(5), b1 = ARG(6), share = ARG(7);
        double step = fmax(1, (b1 - b0) / 200);
        int total = 0, best = -1;
        for (double b = b0; b < b1; b += step) total++;
        double at = dflt;
        for (double a = ceil(a0); a < a1 && total; a += 1) {
            int cnt = 0;
            for (double b = b0; b < b1; b += step)
                if (si_dif(vert ? si_at(p, a - 1, b) : si_at(p, b, a - 1), vert ? si_at(p, a, b) : si_at(p, b, a)) > SI_EDGE) cnt++;
            if (cnt > best) { best = cnt; at = a; }
        }
        return total && best >= share * total ? at : dflt;
    }
    if ([kind isEqualToString:@"until"]) {
        // [x, y, dx, dy, steps]: walk from (x, y) until the colour changes; where it does.
        double x = ARG(3), y = ARG(4), dx = ARG(5), dy = ARG(6), lim = ARG(7);
        const unsigned char *c0 = si_at(p, x, y);
        for (double i = 1; i <= lim; i++)
            if (si_dif(si_at(p, x + dx * i, y + dy * i), c0) > SI_EDGE) return dx ? x + dx * i : y + dy * i;
        return dflt;
    }
    if ([kind isEqualToString:@"rows"] || [kind isEqualToString:@"cols"]) {
        // [from, to, c0, c1]: the first row (column) from `from` towards `to` with anything
        // on it between c0 and c1 that isn't the colour at (c0, from) — where content starts.
        BOOL rows = [kind isEqualToString:@"rows"];
        double f = ARG(3), t = ARG(4), c0 = ARG(5), c1 = ARG(6), dir = t >= f ? 1 : -1;
        unsigned char bg[4];
        memcpy(bg, rows ? si_at(p, c0, f) : si_at(p, f, c0), 4);
        double step = fmax(1, (c1 - c0) / 400);
        for (double a = f; dir > 0 ? a <= t : a >= t; a += dir)
            for (double c = c0; c < c1; c += step)
                if (si_dif(rows ? si_at(p, c, a) : si_at(p, a, c), bg) > SI_EDGE) return a;
        return dflt;
    }
#undef ARG
    return dflt;
}

// Every probe and scan of a recipe on one snapshot of size W×H, in that order (a scan
// can use the ones before it).
static NSDictionary *si_measure(const SIPix *p, NSDictionary *recipe, double W, double H) {
    NSMutableDictionary *v = [NSMutableDictionary dictionaryWithDictionary:@{ @"W": @(W), @"H": @(H) }];
    for (NSArray *q in recipe[@"probes"]) {
        const unsigned char *a = si_at(p, sx_num(q[1], v), sx_num(q[2], v)), *b = si_at(p, sx_num(q[3], v), sx_num(q[4], v));
        v[q[0]] = @(si_dif(a, b) > SI_EDGE ? 1 : 0);
    }
    for (NSArray *s in recipe[@"scans"]) if (s.count >= 4) v[s[0]] = @(si_scan(p, s, v));
    [v removeObjectsForKeys:@[ @"W", @"H" ]];
    return v;
}

// A scan's value relative to the edge it hangs from, and back.
static double si_rel(unichar a, double v, double W, double H) {
    switch (a) { case 'r': return W - v; case 'b': return H - v; case 'c': return v - W / 2; case 'm': return v - H / 2; }
    return v;                                      // 'l' / 't'
}
static double si_abs(unichar a, double r, double W, double H) {
    switch (a) { case 'r': return W - r; case 'b': return H - r; case 'c': return r + W / 2; case 'm': return r + H / 2; }
    return r;
}

// The recipe's variables at size W×H, k of the way from A's measurements to B's
// (k = 0 / no B: A's), then its defs.
static NSMutableDictionary *si_blend(NSDictionary *recipe, SILook *A, SILook *B, double k, double W, double H) {
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    if (!B) k = 0;
    for (NSArray *q in recipe[@"probes"])          // 0/1: no in-between
        v[q[0]] = (k >= 0.5 ? B : A)->meas[q[0]] ?: @0;
    for (NSArray *s in recipe[@"scans"]) {
        if (s.count < 4) continue;
        unichar an = [s[1] length] ? [s[1] characterAtIndex:0] : 'l';
        double a = si_rel(an, [A->meas[s[0]] doubleValue], A->W0, A->H0);
        double b = B ? si_rel(an, [B->meas[s[0]] doubleValue], B->W0, B->H0) : a;
        v[s[0]] = @(si_abs(an, a + (b - a) * k, W, H));
    }
    v[@"W"] = @(W); v[@"H"] = @(H);
    [v addEntriesFromDictionary:recipe[@"_vars"] ?: @{}];   // insets_from (zoom_standin)
    for (NSArray *d in recipe[@"defs"]) v[d[0]] = @(sx_num(d[1], v));
    return v;
}

static NSMutableDictionary *si_vars(SILook *L, double W, double H) {   // the look's own, at its own size
    return si_blend(L->recipe, L, NULL, 0, W, H);
}

// A frame given top-left-down, in a parent of height ph (layers here are y-up).
static CGRect si_flip(CGRect r, double ph) {
    return CGRectMake(r.origin.x, ph - r.origin.y - r.size.height, r.size.width, r.size.height);
}

// A snapshot (sw×sh points) cut into the recipe's parts; `meas` = si_measure of it.
static SILook *si_look(CGImageRef im, const SIPix *pix, NSDictionary *meas, NSDictionary *recipe, double sw, double sh) {
    SILook *L = calloc(1, sizeof *L);
    L->recipe = [recipe retain];
    L->meas = [meas retain];
    L->W0 = sw; L->H0 = sh;
    double scale = CGImageGetWidth(im) / sw;
    NSMutableDictionary *v = si_vars(L, sw, sh);
    L->layer = [[CALayer layer] retain];
    L->layer.anchorPoint = CGPointZero;
    CGRect whole = CGRectMake(0, 0, sw, sh);
    for (NSDictionary *p in recipe[@"parts"]) {
        if (L->np >= 24) break;
        SIPart *q = &L->part[L->np++];
        q->there = !p[@"when"] || sx_num(p[@"when"], v) != 0;
        q->hold = [p[@"hold"] doubleValue];
        q->clip = [[CALayer layer] retain];
        q->clip.masksToBounds = YES; q->clip.anchorPoint = CGPointZero;
        if (p[@"fill"]) {
            CGColorRef c = si_pcolour(pix, sx_num(p[@"fill"][0], v), sx_num(p[@"fill"][1], v));
            q->clip.backgroundColor = c; CGColorRelease(c);
        }
        if (p[@"src"]) {
            q->src = CGRectIntersection(si_rect(p[@"src"], v), whole);
            if (!CGRectIsEmpty(q->src)) {
                CGImageRef cut = CGImageCreateWithImageInRect(im, CGRectMake(
                    q->src.origin.x * scale, q->src.origin.y * scale, q->src.size.width * scale, q->src.size.height * scale));
                q->img = [[CALayer layer] retain];
                q->img.anchorPoint = CGPointZero;
                q->img.contents = (id)cut;
                q->img.contentsGravity = kCAGravityResize;
                q->img.minificationFilter = q->img.magnificationFilter = kCAFilterNearest;   // crisp at 1:1; slices stretch cleanly
                if (cut) CGImageRelease(cut);
                [q->clip addSublayer:q->img];
            }
        }
        [L->layer addSublayer:q->clip];
    }
    return L;
}

static void si_look_free(SILook *L) {
    if (!L) return;
    [L->layer removeFromSuperlayer];
    for (int i = 0; i < L->np; i++) { [L->part[i].img release]; [L->part[i].clip release]; }
    [L->layer release]; [L->recipe release]; [L->meas release];
    free(L);
}

// Lay L out at W×H with the variables v (si_blend at W×H: the same for A and B, so
// their parts sit on each other). A part is there or not by the look's OWN
// measurements ('when' at its snapshot's size).
static void si_layout(SILook *L, double W, double H, NSDictionary *v) {
    NSArray *parts = L->recipe[@"parts"];
    for (int i = 0; i < L->np; i++) {
        SIPart *q = &L->part[i];
        NSDictionary *p = parts[i];
        q->clip.hidden = !q->there;
        if (!q->there) continue;
        CGRect d = si_rect(p[@"dst"] ?: p[@"src"], v);
        static int dbg = -1; if (dbg < 0) dbg = getenv("SI_DEBUG") != NULL;
        if (dbg) fprintf(stderr, "  %-22s src %.0f,%.0f %.0fx%.0f  dst %.0f,%.0f %.0fx%.0f\n", [p[@"name"] UTF8String], q->src.origin.x, q->src.origin.y, q->src.size.width, q->src.size.height, d.origin.x, d.origin.y, d.size.width, d.size.height);
        q->clip.frame = si_flip(d, H);
        if (!q->img) continue;
        if ([p[@"freeze"] boolValue]) {
            // Still on the glass: the snapshot at its own zoom's scale, z0/Z of it now, about
            // the tile's corner — which itself stays put on the glass at any zoom.
            double f = L->z0 > 0 && [v[@"Z"] doubleValue] > 0 ? L->z0 / [v[@"Z"] doubleValue] : 1;
            q->img.frame = si_flip(CGRectMake(q->src.origin.x * f - d.origin.x, q->src.origin.y * f - d.origin.y,
                                              q->src.size.width * f, q->src.size.height * f), d.size.height);
            continue;
        }
        NSString *pin = [p[@"pin"] length] == 2 ? p[@"pin"] : @"tl";
        unichar pv = [pin characterAtIndex:0], ph = [pin characterAtIndex:1];
        double sw = q->src.size.width, sh = q->src.size.height, x = 0, y = 0;
        if (ph == 'r') x = d.size.width - sw; else if (ph == 'c') x = (d.size.width - sw) / 2;
        else if (ph == 's') sw = d.size.width;               // stretched to fill (a plain slice)
        if (pv == 'b') y = d.size.height - sh; else if (pv == 'c') y = (d.size.height - sh) / 2;
        else if (pv == 's') sh = d.size.height;
        q->img.frame = si_flip(CGRectMake(x, y, sw, sh), d.size.height);
    }
    L->layer.frame = CGRectMake(0, 0, W, H);
}

typedef struct {
    ZoomWin *w;
    CALayer *tile;
    SILook *A, *B;
    NSDictionary *recipe;
    _Atomic(void *) shot;                          // the newest B capture not laid out yet (SIShot *)
    _Atomic double freshAt;                        // s: when the newest B capture began (new or the same picture)
    _Atomic int stop;                              // the glide is over: stop capturing B
    _Atomic int unsettled;                         // B captures dropped as mid-repaint (log)
    uint64_t *bBlocks; long nBlocks;               // the B picture on screen, as blocks (log)
    double bE;                                     // glide progress when B arrived
    double bAt;                                    // ms (trace)
    int nShots;                                    // B pictures laid out (trace)
} SITile;

// A B capture, measured on its capture thread; the tick lays it out.
typedef struct { CGImageRef im; SIPix pix; NSDictionary *meas; uint64_t *blocks; long nBlocks; } SIShot;
static void si_shot_free(SIShot *sh) {
    if (!sh) return;
    CGImageRelease(sh->im); si_pix_free(&sh->pix); [sh->meas release]; free(sh->blocks);
    free(sh);
}

// screen_frame's black edge (bin/screen_frame.m), drawn here in step with the zoom:
// everything outside the visible part's rounded rect, inset by its stroke (y-up),
// notched at the seams screen_frame last found (screen_frame.h, SEAM_FILE).
static CGPathRef si_frame_path(double W, double H, double z, double scale) {
    const char *e = getenv("SCREEN_FRAME_RADIUS");
    double px = 2.0 / scale / z, r = (e ? atof(e) : 16.0) / z;
    CGRect v = CGRectMake(0, H - H / z, W / z, H / z);
    double seam[4] = {-1, -1, -1, -1};
    FILE *f = fopen(SEAM_FILE, "r");
    if (f) {
        if (fscanf(f, "%lf %lf %lf %lf", &seam[0], &seam[1], &seam[2], &seam[3]) != 4) seam[0] = seam[2] = -1;
        fclose(f);
    }
    for (int i = 0; i < 4; i++) if (seam[i] >= 0) seam[i] *= v.size.width;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddRect(p, NULL, CGRectMake(0, 0, W, H));
    sf_hole(p, CGRectInset(v, px, px), r, px / 2, seam);
    return p;
}

#define ZOOM_LOG "/tmp/zoom_standin.log"
static int zoom_standin(ZoomWin *ws, int n, double SW, double SH, double from, double to, double secs) {
    CGSConnectionID cid = CGSMainConnectionID();
    CGPoint pin = { 0, 0 };
    BOOL trace = getenv("SCENE_DEBUG") != NULL;
    double paint = getenv("ZOOM_PAINT_MS") ? atof(getenv("ZOOM_PAINT_MS")) / 1000 : 0.07;
    double fade = getenv("ZOOM_FADE_MS") ? atof(getenv("ZOOM_FADE_MS")) / 1000 : 0.09;
    double tA = ms_since_start();
    NSDictionary *recipes = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:@"/Users/josh/Code/Scripts/ui_zoom/stand_in.json"] ?: [NSData data]
                                                           options:0 error:NULL];
    if (![recipes isKindOfClass:[NSDictionary class]]) recipes = @{};
    NSDictionary *fallback = recipes[@"default"] ?: @{ @"parts": @[ @{ @"src": @[@0, @0, @"$W", @"$H"], @"pin": @"tl" } ] };

    // A: every visible window as it is now.
    SITile tiles[32]; int nt = 0;
    for (int i = 0; i < n; i++) {
        ZoomWin *w = &ws[i];
        if (w->hidden || nt >= 32) continue;
        CGRect r = tile_rect(w->tile, (int)(SW / from), (int)(SH / from));
        CGImageRef a = si_snap(w->wid);
        if (!a) continue;
        SITile *s = &tiles[nt++];
        memset(s, 0, sizeof *s);
        s->w = w;
        s->recipe = recipes[@(w->bundle)] ?: fallback;
        // insets_from: a file whose last four numbers are a rect of the window's in global
        // top-left points (x y w h) → $CL $CT $CR $CB, its insets from the window's edges,
        // which hold at any size; $INSETS = 1 when it was read and sits inside the window.
        if (s->recipe[@"insets_from"]) {
            NSArray *num = [[[NSString stringWithContentsOfFile:s->recipe[@"insets_from"] encoding:NSUTF8StringEncoding
                                                          error:NULL] ?: @"" componentsSeparatedByCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet] filteredArrayUsingPredicate:
                            [NSPredicate predicateWithFormat:@"length > 0"]];
            NSMutableDictionary *iv = [NSMutableDictionary dictionaryWithDictionary:@{ @"INSETS": @0 }];
            if (num.count >= 4) {
                NSUInteger o = num.count - 4;
                double x = [num[o] doubleValue], y = [num[o + 1] doubleValue], cw = [num[o + 2] doubleValue], ch = [num[o + 3] doubleValue];
                double cl = x - r.origin.x, ct = y - r.origin.y, cr = CGRectGetMaxX(r) - x - cw, cb = CGRectGetMaxY(r) - y - ch;
                if (cw > 50 && ch > 50 && cl >= 0 && ct >= 0 && cr >= 0 && cb >= 0)
                    [iv addEntriesFromDictionary:@{ @"INSETS": @1, @"CL": @(cl), @"CT": @(ct), @"CR": @(cr), @"CB": @(cb) }];
            }
            NSMutableDictionary *rc = [s->recipe mutableCopy];
            rc[@"_vars"] = iv;
            s->recipe = rc;                        // kept for the process (B threads read it)
        }
        SIPix px = si_pix(a, r.size.width);
        s->A = si_look(a, &px, si_measure(&px, s->recipe, r.size.width, r.size.height), s->recipe,
                       r.size.width, r.size.height);
        s->A->z0 = from;
        si_pix_free(&px);
        CGImageRelease(a);
    }
    double tSnap = ms_since_start();

    // The line between a left and a right window: the 1 pt gap between them, where the
    // borders line behind shows. It stays put on the glass, so it's drawn on top of the
    // stand-ins in its colour of now (sampled), never chased.
    BOOL seamL = NO, seamR = NO;
    for (int k = 0; k < nt; k++) {
        int t = tiles[k].w->tile;
        if (t == 1 || t == 3 || t == 5) seamL = YES;
        if (t == 2 || t == 4 || t == 6) seamR = YES;
    }
    CGColorRef seamCol = NULL;
    if (seamL && seamR && gSnap) {
        double hw0 = (int)(SW / from) / 2;
        CGImageRef px = gSnap(CGRectMake(hw0 - 1, (int)(SH / from) / 2, 1, 1), kCGWindowListOptionOnScreenOnly,
                              kCGNullWindowID, kCGWindowImageNominalResolution);
        if (px) { seamCol = si_colour(px, CGImageGetWidth(px), 0, 0, NULL); CGImageRelease(px); }
    }

    // Our window over them, at the floating level: ordering it just above the frontmost
    // tiled window instead (to keep floaters on top) silently lands it BELOW that window
    // when it belongs to the active app (measured 2026-10-20: Claude showed through).
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect scr = NSScreen.screens.firstObject.frame;
    NSWindow *ov = [[NSWindow alloc] initWithContentRect:scr styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    ov.opaque = NO; ov.backgroundColor = NSColor.clearColor; ov.hasShadow = NO;
    ov.ignoresMouseEvents = YES; ov.level = NSFloatingWindowLevel;
    ov.collectionBehavior = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    NSView *view = ov.contentView;
    view.wantsLayer = YES;
    CALayer *root = view.layer;
    double screenH = scr.size.height;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int k = 0; k < nt; k++) {
        SITile *s = &tiles[k];
        s->tile = [[CALayer layer] retain];
        s->tile.anchorPoint = CGPointZero;
        s->tile.masksToBounds = YES;
        s->tile.cornerRadius = 18;                 // the window's own (macOS 26)
        if (@available(macOS 11.0, *)) s->tile.cornerCurve = kCACornerCurveContinuous;
        CGRect r = tile_rect(s->w->tile, (int)(SW / from), (int)(SH / from));
        s->tile.frame = si_flip(r, screenH);
        si_layout(s->A, r.size.width, r.size.height, si_vars(s->A, r.size.width, r.size.height));
        [s->tile addSublayer:s->A->layer];
        [root addSublayer:s->tile];
    }
    CALayer *seam = nil;
    if (seamCol) {
        seam = [[CALayer layer] retain];
        seam.anchorPoint = CGPointZero;
        seam.backgroundColor = seamCol;
        double hw = (int)(SW / from) / 2;
        seam.frame = si_flip(CGRectMake(hw - 1, 0, 1, (int)(SH / from)), screenH);
        [root addSublayer:seam];
    }
    [CATransaction commit];
    [ov orderFrontRegardless];

    // screen_frame's edge, ours now: the same drawing, at its level, moved with the zoom
    // in the same transaction as everything else. screen_frame hides its own meanwhile.
    double scale = NSScreen.screens.firstObject.backingScaleFactor ?: 1;
    NSWindow *fw = [[NSWindow alloc] initWithContentRect:scr styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    fw.opaque = NO; fw.backgroundColor = NSColor.clearColor; fw.hasShadow = NO;
    fw.ignoresMouseEvents = YES;
    fw.level = CGWindowLevelForKey(kCGMaximumWindowLevelKey) - 1;
    fw.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
                          | NSWindowCollectionBehaviorIgnoresCycle;
    fw.contentView.wantsLayer = YES;
    CAShapeLayer *edge = [CAShapeLayer layer];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    edge.frame = CGRectMake(0, 0, scr.size.width, scr.size.height);
    edge.fillRule = kCAFillRuleEvenOdd;
    edge.fillColor = CGColorGetConstantColor(kCGColorBlack);
    CGPathRef ep = si_frame_path(scr.size.width, scr.size.height, from, scale);
    edge.path = ep; CGPathRelease(ep);
    [fw.contentView.layer addSublayer:edge];
    [CATransaction commit];
    [fw orderFrontRegardless];
    [CATransaction flush];
    usleep(17000);                                 // on the glass before anything moves under it
    notify_post("com.callis.screenzoom.hold");
    double tShown = ms_since_start();

    // Resize the real windows to their final size now, under the stand-in, and take B
    // once each has landed and painted — then AGAIN every ~25 ms until the glide is
    // over, each new picture replacing the last. An app can show the new size before
    // all of its content has caught up (Chrome: parts of the old layout for a moment);
    // a single early B kept those, and at the end they showed in the old place for a
    // split second before the real window came through (2026-10-20). The glide only
    // ends on a B taken after it finished.
    // An app busy on its main thread (Claude streaming a reply) can let an AX set time
    // out and drop it — the window then stayed at the old size under a finished glide
    // (2026-10-20). So: a longer timeout, and the size is checked on the window server
    // and sent again until it shows.
    int64_t final = ((int64_t)(int)(SW / to) << 32) | (int64_t)(int)(SH / to);
    for (int k = 0; k < nt; k++) {
        SITile *s = &tiles[k];
        ZoomWin *w = s->w;
        CGRect want = tile_rect(w->tile, (int)(SW / to), (int)(SH / to));
        atomic_store(&w->want, final);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            AXUIElementSetMessagingTimeout(w->win, 1.0);
            BOOL ok = NO;
            for (int attempt = 0; attempt < 6 && !ok; attempt++) {
                if (attempt) w->setAt = CGPointMake(-1e9, -1e9);   // send the move again too
                dispatch_sync(w->q, ^{ zoom_set(w, final); atomic_fetch_add(&w->done, 1); });
                for (int spin = 0; spin < 25 && !ok; spin++) {    // up to 250 ms to show
                    CGRect f = CGRectNull;
                    CFArrayRef one = CFArrayCreate(NULL, (const void **)&w->wid, 1, NULL);
                    NSArray *d = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(one));
                    CFRelease(one);
                    if (d.count) CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)d[0][(id)kCGWindowBounds], &f);
                    ok = CGRectEqualToRect(f, want);
                    if (!ok) usleep(10000);
                }
                if (!ok) fprintf(stderr, "stand-in: %s not at its size yet (attempt %d)\n", w->bundle, attempt + 1);
            }
            usleep((useconds_t)(paint * 1e6));
            // A picture is used only once the window has SETTLED: at most 2% of it changed
            // since the capture before (a caret, a spinner). Mid-repaint frames — half the
            // old layout, half the new — were what flashed at the end of a glide in apps
            // other than Chrome (2026-10-20). Something that never settles (a video) is
            // taken anyway after 4 tries.
            uint64_t *prev = NULL, *shown = NULL;
            long nb = 0;
            int restless = 0;
            while (!atomic_load(&s->stop)) @autoreleasepool {
                double at = ms_since_start() / 1000;
                CGImageRef im = si_snap(w->wid);
                if (im) {
                    SIPix px = si_pix(im, want.size.width);
                    uint64_t *bl = si_blocks(&px, &nb);
                    BOOL settled = prev && si_changed(bl, prev, nb) <= nb / 50;
                    free(prev); prev = bl;
                    if (!settled && ++restless < 4) {
                        if (restless > 1) atomic_fetch_add(&s->unsettled, 1);
                        CGImageRelease(im); si_pix_free(&px);
                    } else {
                        restless = 0;
                        if (!shown || si_changed(bl, shown, nb)) {
                            free(shown);
                            shown = memcpy(malloc(nb * sizeof *bl), bl, nb * sizeof *bl);
                            SIShot *sh = calloc(1, sizeof *sh);
                            sh->im = im; sh->pix = px;
                            sh->meas = [si_measure(&px, s->recipe, want.size.width, want.size.height) retain];
                            sh->blocks = memcpy(malloc(nb * sizeof *bl), bl, nb * sizeof *bl); sh->nBlocks = nb;
                            si_shot_free(atomic_exchange(&s->shot, sh));
                        } else { CGImageRelease(im); si_pix_free(&px); }
                        atomic_store(&s->freshAt, at);
                    }
                }
                usleep(25000);
            }
            free(prev); free(shown);
        });
    }

    zoom_realtime();
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t tick = (uint64_t)(1e9 / 165 * tb.denom / tb.numer), next = mach_absolute_time();
    double t0 = ms_since_start() / 1000, z = from, end = 0;
    int frames = 0;
    for (;;) {
        @autoreleasepool {
            double now = ms_since_start() / 1000;
            double t = secs > 0 ? (now - t0) / secs : 1;
            if (t > 1) t = 1;
            double e = zoom_curve(0, 1, t);
            z = t >= 1 ? to : from + (to - from) * e;
            BOOL missing = NO, stale = NO;
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            for (int k = 0; k < nt; k++) {
                SITile *s = &tiles[k];
                // In between: the exact size; at the end: the real window's whole points.
                CGRect r = t >= 1 ? tile_rect(s->w->tile, (int)(SW / to), (int)(SH / to))
                                  : tile_rect_d(s->w->tile, SW / z, SH / z);
                s->tile.frame = si_flip(r, screenH);
                SIShot *sh = atomic_exchange(&s->shot, NULL);
                if (sh) {                          // a new picture of B: it replaces the last
                    CGRect f = tile_rect(s->w->tile, (int)(SW / to), (int)(SH / to));
                    SILook *nb = si_look(sh->im, &sh->pix, sh->meas, s->recipe, f.size.width, f.size.height);
                    nb->z0 = to;
                    free(s->bBlocks); s->bBlocks = sh->blocks; s->nBlocks = sh->nBlocks; sh->blocks = NULL;
                    si_shot_free(sh);
                    if (!s->B) {
                        s->bE = e < 0.98 ? e : 0.98;
                        s->bAt = ms_since_start() - t0 * 1000;
                    }
                    si_look_free(s->B);
                    s->B = nb;
                    [s->tile addSublayer:nb->layer];
                    s->nShots++;
                }
                // A and B laid out alike: each measured value k of the way from A's to B's.
                double k = !s->B ? 0 : t >= 1 ? 1 : fmax(0, fmin(1, (e - s->bE) / (1 - s->bE)));
                NSMutableDictionary *v = si_blend(s->recipe, s->A, s->B, k, r.size.width, r.size.height);
                v[@"Z"] = @(z);
                si_layout(s->A, r.size.width, r.size.height, v);
                if (s->B) {
                    si_layout(s->B, r.size.width, r.size.height, v);
                    s->B->layer.opacity = (float)k;
                    if (atomic_load(&s->freshAt) < t0 + secs || atomic_load(&s->shot)) stale = YES;
                } else missing = YES;
            }
            if (seam) {
                double hw = t >= 1 ? (int)(SW / to) / 2 : SW / z / 2;
                seam.frame = si_flip(CGRectMake(hw - 1, 0, 1, SH / z), screenH);
            }
            CGPathRef p = si_frame_path(scr.size.width, scr.size.height, z, scale);
            edge.path = p; CGPathRelease(p);
            [CATransaction commit];
            [CATransaction flush];
            CGSSetZoomParameters(cid, &pin, z, 0, 1, 0);
            frames++;
            // Done once every window's B is a picture taken after the glide (capped).
            if (t >= 1 && ((!missing && !stale) || now - t0 > secs + 0.5)) {
                end = now; break;
            }
        }
        next += tick;
        uint64_t tnow = mach_absolute_time();
        if (next < tnow) next = tnow;
        mach_wait_until(next);
    }
    for (int k = 0; k < nt; k++) atomic_store(&tiles[k].stop, 1);

    // B on top at the final size = what the real window shows: let the stand-in go —
    // all but the recipe's masks (a scrollbar the resize flashed), which stay their 'hold'.
    notify_post("com.callis.screenzoom.done");     // screen_frame back, at the final zoom
    usleep(17000);
    double holdFor = 0;
    for (double f0 = ms_since_start() / 1000, a = 1; a > 0; ) {
        a = fade > 0 ? fmax(0, 1 - (ms_since_start() / 1000 - f0) / fade) : 0;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        for (int k = 0; k < nt; k++) {
            SITile *s = &tiles[k];
            s->A->layer.opacity = a;
            for (int j = 0; s->B && j < s->B->np; j++) {
                if (s->B->part[j].hold > 0 && !s->B->part[j].clip.hidden) {
                    holdFor = fmax(holdFor, s->B->part[j].hold);
                    continue;
                }
                s->B->part[j].clip.opacity = a;
            }
        }
        seam.opacity = a;
        [CATransaction commit];
        [CATransaction flush];
        usleep(6000);
    }
    [fw orderOut:nil];
    [CATransaction flush];

    // After: does the real window still change once the stand-in is gone? That is what
    // the eye sees as a flash at the end. One line per window in ZOOM_LOG — blocks
    // changed vs the last B shown, at +80 / +300 / +800 ms, and where.
    FILE *lf0 = fopen(ZOOM_LOG, "a");
    if (lf0) {
        time_t tt = time(NULL); char ts[32]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&tt));
        fprintf(lf0, "%s stand-in %.2f→%.2f, glide %.0f ms (+%.0f waiting for settled B)\n", ts, from, to,
                (end - t0) * 1000, fmax(0, (end - t0 - secs) * 1000));
        fclose(lf0);
    }
    dispatch_group_t after = dispatch_group_create();
    double fadedAt = ms_since_start() / 1000;
    for (int k = 0; k < nt; k++) {
        SITile *s = &tiles[k];
        if (!s->bBlocks) continue;
        dispatch_group_async(after, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool {
            CGRect f = tile_rect(s->w->tile, (int)(SW / to), (int)(SH / to));
            char line[512]; int len = snprintf(line, sizeof line, "  %-32s %2d pictures, %d mid-repaint dropped, after:",
                                               s->w->bundle, s->nShots, atomic_load(&s->unsettled));
            for (int i = 0; i < 3; i++) {
                double waitTo = fadedAt + (double[]){ 0.08, 0.3, 0.8 }[i], d = waitTo - ms_since_start() / 1000;
                if (d > 0) usleep((useconds_t)(d * 1e6));
                CGImageRef im = si_snap(s->w->wid);
                if (!im) continue;
                SIPix px = si_pix(im, f.size.width);
                long nb; uint64_t *bl = si_blocks(&px, &nb);
                long c = nb == s->nBlocks ? si_changed(bl, s->bBlocks, nb) : -1;
                CGRect r = c > 0 ? si_changed_box(bl, s->bBlocks, nb, &px) : CGRectZero;
                len += snprintf(line + len, sizeof line - len, c > 0 ? "  %ld (%.0f,%.0f %.0fx%.0f)" : "  %ld",
                                c, r.origin.x, r.origin.y, r.size.width, r.size.height);
                free(bl); si_pix_free(&px); CGImageRelease(im);
            }
            FILE *lf = fopen(ZOOM_LOG, "a");
            if (lf) { fprintf(lf, "%s\n", line); fclose(lf); }
        }});
    }

    // The covered ones, now (each app's own pace; capped).
    for (int i = 0; i < n; i++) if (ws[i].hidden) { atomic_store(&ws[i].want, final); zoom_push(&ws[i]); }
    for (int i = 0; i < n; i++) dispatch_sync(ws[i].q, ^{});
    // The size goes out now (ui_zoom.sh reads one line and moves on); the masks stay on
    // their own. A newer glide ends this process (zoom_glide's start).
    printf("%d %d\n", (int)(SW / z), (int)(SH / z));
    fflush(stdout);
    if (holdFor > 0) {
        usleep((useconds_t)(holdFor * 1e6));
        for (double f0 = ms_since_start() / 1000, a = 1; a > 0; ) {
            a = fmax(0, 1 - (ms_since_start() / 1000 - f0) / 0.15);
            ov.alphaValue = a;
            [CATransaction flush];
            usleep(6000);
        }
    }
    [ov orderOut:nil];
    [CATransaction flush];
    dispatch_group_wait(after, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    if (trace) {
        fprintf(stderr, "stand-in %.3f→%.3f %d windows (%d stood in): snap %.0fms, shown %.0fms, %d frames, glide %.0fms\n",
                from, to, n, nt, tSnap - tA, tShown - tA, frames, (end - t0) * 1000);
        for (int k = 0; k < nt; k++)
            fprintf(stderr, "  %-34s B at %.0fms (progress %.2f), %d pictures%s\n", tiles[k].w->bundle, tiles[k].bAt, tiles[k].bE, tiles[k].nShots,
                    recipes[@(tiles[k].w->bundle)] ? "" : "  [default recipe]");
    }
    for (int i = 0; i < n; i++) CFRelease(ws[i].win);
    return 0;
}

// scene_restore --standin-test <bundle id> <A.png> <W> <H> <out.png> [<B.png> <k>]
// Lays snapshot A out at W×H by the app's recipe and writes what the stand-in would
// show — compare it with a real capture of the window at that size (tuning recipes).
// With B (a capture at another size) and k: the glide's frame k of the way from A to
// B (B over A at opacity k). Prints what was measured on each.
static SILook *standin_load(const char *path, NSDictionary *recipe, CGImageRef *imOut) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:@(path)], NULL);
    CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (!im) { fprintf(stderr, "can't read %s\n", path); return NULL; }
    double w = CGImageGetWidth(im), h = CGImageGetHeight(im);
    SIPix px = si_pix(im, w);
    NSDictionary *m = si_measure(&px, recipe, w, h);
    fprintf(stderr, "%s (%.0fx%.0f):", path, w, h);
    for (NSArray *s in recipe[@"scans"]) fprintf(stderr, " %s=%.0f", [s[0] UTF8String], [m[s[0]] doubleValue]);
    for (NSArray *q in recipe[@"probes"]) fprintf(stderr, " %s=%.0f", [q[0] UTF8String], [m[q[0]] doubleValue]);
    fprintf(stderr, "\n");
    SILook *L = si_look(im, &px, m, recipe, w, h);
    si_pix_free(&px);
    *imOut = im;
    return L;
}
static int standin_test(int argc, const char *argv[]) {
    if (argc < 7) { fprintf(stderr, "usage: scene_restore --standin-test BUNDLE A.png W H OUT.png [B.png k]\n"); return 2; }
    NSDictionary *recipes = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:@"/Users/josh/Code/Scripts/ui_zoom/stand_in.json"] options:0 error:NULL];
    NSDictionary *recipe = recipes[@(argv[2])] ?: recipes[@"default"];
    CGImageRef im = NULL, imB = NULL;
    SILook *A = standin_load(argv[3], recipe, &im), *B = NULL;
    if (!A) return 1;
    if (argc >= 9 && !(B = standin_load(argv[7], recipe, &imB))) return 1;
    double W = atof(argv[4]), H = atof(argv[5]), k = argc >= 9 ? atof(argv[8]) : 0;
    NSDictionary *v = si_blend(recipe, A, B, k, W, H);
    CALayer *root = [CALayer layer];
    root.anchorPoint = CGPointZero; root.frame = CGRectMake(0, 0, W, H);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    si_layout(A, W, H, v);
    [root addSublayer:A->layer];
    if (B) { si_layout(B, W, H, v); B->layer.opacity = k; [root addSublayer:B->layer]; }
    [CATransaction commit];
    CGColorSpaceRef cs = CGImageGetColorSpace(im);
    CGContextRef c = CGBitmapContextCreate(NULL, (size_t)W, (size_t)H, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    [root renderInContext:c];
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((CFURLRef)[NSURL fileURLWithPath:@(argv[6])],
                                                              CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, out, NULL);
    CGImageDestinationFinalize(d);
    return 0;
}

// ── Lockstep glide (ZOOM_LOCKSTEP=1; also every no-glide fit) ────────────────────
// Every frame on screen is one consistent picture: freeze the display, send every
// visible window this frame's size, wait until all have landed (+ ZOOM_SETTLE_MS for
// their content to catch up), set the zoom, release — one composite shows the new
// sizes and the new zoom together. So the frame rate is the slowest app's. To keep it
// from stumbling, frames are put on an even beat (the period follows the slowest
// app's recent resize time) and each frame's zoom is the curve at the moment it is
// shown. Within a frame the faster apps are sent their size later, by the difference,
// so all land together and the freeze is as short as the slowest app needs.
static int zoom_lockstep(ZoomWin *ws, int n, double SW, double SH, double from, double to, double secs) {
    CGSConnectionID cid = CGSMainConnectionID();
    CGPoint pin = { 0, 0 };
    BOOL trace = getenv("SCENE_DEBUG") != NULL;
    NSMutableString *log = trace ? [NSMutableString string] : nil;
    double settle = getenv("ZOOM_SETTLE_MS") ? atof(getenv("ZOOM_SETTLE_MS")) / 1000 : 0;
    double minP = getenv("ZOOM_MIN_MS") ? atof(getenv("ZOOM_MIN_MS")) / 1000 : 0.012;
    double cost[32];                                    // each window's recent resize time (s)
    for (int i = 0; i < n; i++) cost[i] = 0.02;
    double *costp = cost;
    double period = 0.03;
    if (fabs(to - from) < 0.001) secs = 0;
    double t0 = ms_since_start() / 1000, show = t0, z = from;
    int frames = 0, late = 0;
    zoom_realtime();
    notify_post("com.callis.screenzoom");               // screen_frame follows the zoom
    for (;;) {
        double slow = 0;
        for (int i = 0; i < n; i++) if (!ws[i].hidden && cost[i] > slow) slow = cost[i];
        double work = slow + settle;
        period = fmax(minP, 0.8 * period + 0.2 * (work * 1.15 + 0.002));
        show += period;                                  // this frame's moment on the beat
        double now = ms_since_start() / 1000;
        if (show < now + work) show = now + work;        // can't make it: as soon as it can
        double t = secs > 0 ? (show - t0) / secs : 1;
        if (t > 1) t = 1;
        double zk = t >= 1 ? to : zoom_curve(from, to, t);
        int64_t want = ((int64_t)(int)(SW / zk) << 32) | (int64_t)(int)(SH / zk);

        // Start the work so it ends on the beat.
        double start = show - work;
        if (start > now) usleep((useconds_t)((start - now) * 1e6));
        double f0 = ms_since_start();
        CGSDisableUpdate(cid);
        dispatch_group_t g = dispatch_group_create();
        for (int i = 0; i < n; i++) {
            ZoomWin *w = &ws[i];
            if (w->hidden && t < 1) continue;            // covered: sized once, at the end
            if (atomic_load(&w->want) == want) continue;
            atomic_store(&w->want, want);
            double after = w->hidden ? 0 : slow - cost[i];
            dispatch_group_enter(g);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * 1e9)), w->q, ^{
                double a = ms_since_start();
                zoom_set(w, want);
                atomic_fetch_add(&w->done, 1);
                if (!w->hidden) costp[i] = 0.6 * costp[i] + 0.4 * (ms_since_start() - a) / 1000;
                dispatch_group_leave(g);
            });
        }
        // Bounded well under the freeze's ~1 s watchdog; a stuck app is let go.
        if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC))) late++;
        double landed = ms_since_start();
        if (settle > 0) usleep((useconds_t)(settle * 1e6));
        now = ms_since_start() / 1000;
        if (show > now) usleep((useconds_t)((show - now) * 1e6));
        CGSSetZoomParameters(cid, &pin, zk, 0, 1, 0);
        CGSReenableUpdate(cid);
        z = zk; frames++;
        if (trace) {
            [log appendFormat:@"%6.1fms z=%.4f frozen %.1f landed %.1f |", ms_since_start() - t0 * 1000, zk,
                 ms_since_start() - f0, landed - f0];
            for (int i = 0; i < n; i++) if (!ws[i].hidden) [log appendFormat:@" %.1f", cost[i] * 1000];
            [log appendString:@"\n"];
        }
        if (t >= 1) break;
    }
    for (int i = 0; i < n; i++) dispatch_sync(ws[i].q, ^{});   // any late set is in
    if (trace) {
        fputs(log.UTF8String, stderr);
        fprintf(stderr, "lockstep %.3f→%.3f %d windows %d frames (%.0f fps) %d late %.0fms\n",
                from, to, n, frames, frames / fmax(secs, 0.001), late, ms_since_start() - t0 * 1000);
    }
    for (int i = 0; i < n; i++) CFRelease(ws[i].win);
    printf("%d %d\n", (int)(SW / z), (int)(SH / z));
    return 0;
}

static int zoom_glide(int argc, const char *argv[]) {
    if (argc < 6) { fprintf(stderr, "usage: scene_restore --zoom SW SH TO SECS\n"); return 2; }
    double SW = atof(argv[2]), SH = atof(argv[3]), to = atof(argv[4]), secs = atof(argv[5]);
    if (to < 1) to = 1;
    CGSConnectionID cid = CGSMainConnectionID();
    // Snapshots (the stand-in glide): the first capture in a process costs ~70 ms of
    // setup — pay it on another thread while the windows are gathered.
    gSnap = (SnapFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    // An earlier glide still holding a mask (the press lock only covers the glide): end it.
    {
        char me[PROC_PIDPATHINFO_MAXSIZE], it[PROC_PIDPATHINFO_MAXSIZE];
        pid_t pids[4096];
        if (proc_pidpath(getpid(), me, sizeof me) > 0) {
            int np = proc_listallpids(pids, sizeof pids) ;
            for (int i = 0; i < np; i++)
                if (pids[i] != getpid() && proc_pidpath(pids[i], it, sizeof it) > 0 && !strcmp(it, me)) {
                    char args[64] = { 0 };
                    // only glides: other scene_restore modes (scene layouts) are left alone
                    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pids[i] };
                    char buf[4096]; size_t len = sizeof buf;
                    if (sysctl(mib, 3, buf, &len, NULL, 0) == 0 && len > sizeof(int)) {
                        int argc0; memcpy(&argc0, buf, sizeof argc0);
                        char *q = buf + sizeof argc0, *e = buf + len;
                        q += strnlen(q, e - q);                    // exec path
                        while (q < e && !*q) q++;                  // padding
                        q += strnlen(q, e - q) + 1;                // argv[0]
                        if (q < e) snprintf(args, sizeof args, "%s", q);
                    }
                    if (!strcmp(args, "--zoom")) kill(pids[i], SIGTERM);
                }
        }
    }
    if (gSnap) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        CGImageRef warm = gSnap(CGRectMake(0, 0, 1, 1), kCGWindowListOptionOnScreenOnly, kCGNullWindowID,
                                kCGWindowImageNominalResolution);
        if (warm) CGImageRelease(warm);
    });
    double from = zoom_now(cid);
    int sw0 = (int)(SW / from), sh0 = (int)(SH / from);

    // The tiled windows on screen now, at the current zoom's tiles.
    ZoomWin ws[32]; int n = 0;
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableDictionary<NSNumber *, NSNumber *> *tileOf = [NSMutableDictionary dictionary],
                                                *orderOf = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set], *covered = [NSMutableSet set];
    CGRect above[64]; int na = 0;                      // layer-0 windows in front, so far
    for (NSDictionary *info in list) {
        if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect f;
        if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &f)) continue;
        int k = tile_index(f, sw0, sh0);
        // On another zoom level's tile: shown at that zoom, then never re-fitted (a
        // glide only reaches the windows on screen) or framed by slots meanwhile. It is
        // brought to the final size too — once, at the end, like a covered one: the
        // stand-in's snapshot cuts assume the window sits on this zoom's tile.
        BOOL stale = NO;
        for (int p = UIZOOM_MIN_PCT; k < 0 && p <= UIZOOM_MAX_PCT; p += UIZOOM_STEP_PCT)
            if ((k = tile_index(f, (int)(SW * 100 / p), (int)(SH * 100 / p))) >= 0) stale = YES;
        if (k >= 0) {
            tileOf[info[(id)kCGWindowNumber]] = @(k);
            orderOf[info[(id)kCGWindowNumber]] = @(na);
            [pids addObject:info[(id)kCGWindowOwnerPID]];
            // Fully behind the windows in front of it (sampled on a grid)? Then it only
            // needs its size once, at the end — nobody sees it in between.
            BOOL all = YES;
            for (int gx = 0; gx <= 8 && all; gx++)
                for (int gy = 0; gy <= 8 && all; gy++) {
                    CGPoint p = { f.origin.x + 4 + (f.size.width - 8) * gx / 8,
                                  f.origin.y + 4 + (f.size.height - 8) * gy / 8 };
                    BOOL hit = NO;
                    for (int a = 0; a < na && !hit; a++) hit = CGRectContainsPoint(above[a], p);
                    all = hit;
                }
            if (all || stale) [covered addObject:info[(id)kCGWindowNumber]];
        }
        if (na < 64) above[na++] = f;
    }
    for (NSNumber *pid in pids) {
        AXUIElementRef app = AXUIElementCreateApplication(pid.intValue);
        CFArrayRef axw = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&axw) == kAXErrorSuccess && axw) {
            for (CFIndex i = 0; i < CFArrayGetCount(axw) && n < 32; i++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(axw, i);
                CGWindowID wid = 0;
                if (_AXUIElementGetWindow(w, &wid) || !tileOf[@(wid)]) continue;
                AXUIElementSetMessagingTimeout(w, 0.1);
                ZoomWin *z = &ws[n++];
                z->win = (AXUIElementRef)CFRetain(w); z->wid = wid;
                z->tile = tileOf[@(wid)].intValue; z->hidden = [covered containsObject:@(wid)];
                z->order = orderOf[@(wid)].intValue;
                z->dragged = NO;
                // Chrome blanks its page on every resize until its renderer paints the new
                // size (screen recording, 2026-10-20: the page was black through the whole
                // glide at ~100 sets/s). Pace it. Experiment knob: ZOOM_CHROME_MS.
                // (Not reproduced once Chrome had recovered from the drag test: off by
                // default, the knob kept.)
                z->pace = 0;
                NSRunningApplication *ra = [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
                if ([ra.bundleIdentifier hasPrefix:@"com.google.Chrome"] && getenv("ZOOM_CHROME_MS"))
                    z->pace = (useconds_t)(1000 * atof(getenv("ZOOM_CHROME_MS")));
                snprintf(z->bundle, sizeof z->bundle, "%s", ra.bundleIdentifier.UTF8String ?: "?");
                z->lead = zoom_lag_get(z->bundle);
                z->nLag = 0; z->lastSeen = -1; atomic_init(&z->nIss, 0);
                z->setAt = CGPointMake(-1e9, -1e9);
                z->q = dispatch_queue_create("zoom.win", dispatch_queue_attr_make_with_qos_class(
                           DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
                atomic_init(&z->busy, 0); atomic_init(&z->want, -1); atomic_init(&z->done, 0);
            }
            CFRelease(axw);
        }
        CFRelease(app);
    }

    if (getenv("ZOOM_LOCKSTEP") || secs <= 0 || fabs(to - from) < 0.001)
        return zoom_lockstep(ws, n, SW, SH, from, to, secs);
    if (!getenv("ZOOM_FREE")) return zoom_standin(ws, n, SW, SH, from, to, secs);

    // ── Free-running glide (ZOOM_FREE=1): the zoom on its own clock, windows chase it ──
    // The window to live-resize: the frontmost visible one off the left edge, if its
    // bottom-right corner is really its own on screen (nothing in front there).
    // OFF unless ZOOM_DRAG=1: measured 2026-10-20 (SCENE_DEBUG frame log), Chrome in
    // live resize managed ~27 resizes/s, started ~180 ms late and its x drifted
    // against the AX moves — worse than AX resizing (~100/s, ~40 ms behind).
    ZoomWin *drag = NULL;
    for (int i = 0; i < n && getenv("ZOOM_DRAG"); i++) {
        if (ws[i].hidden || tile_rect(ws[i].tile, sw0, sh0).origin.x < 1) continue;
        if (!drag || ws[i].order < drag->order) drag = &ws[i];
    }
    CGPoint grab = { 0, 0 };
    if (drag) {
        CGRect r = tile_rect(drag->tile, sw0, sh0);
        grab = (CGPoint){ CGRectGetMaxX(r) - 3, CGRectGetMaxY(r) - 3 };
        for (NSDictionary *info in list) {
            if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
            CGRect f;
            CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)info[(id)kCGWindowBounds], &f);
            if (!CGRectContainsPoint(f, grab)) continue;
            if ([info[(id)kCGWindowNumber] unsignedIntValue] != drag->wid) drag = NULL;
            break;
        }
        if (drag) drag->dragged = YES;
    }

    // Steady ticks at the panel's rate on an absolute clock (mach_wait_until), so a
    // late tick doesn't push the rest; the curve is by elapsed time.
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t tick = (uint64_t)(1e9 / 165 * tb.denom / tb.numer), next = mach_absolute_time();
    double t0 = ms_since_start() / 1000, z = from;
    if (fabs(to - from) < 0.001) { secs = 0; drag = NULL; }   // already there: one tick, to fit
    int frames = 0, sets = 0;
    CGPoint pin = { 0, 0 };

    // The drag: hide the real pointer, draw a stand-in where it is, ignore the
    // trackpad, press on the corner. Everything is undone below (and by zoom_drag_abort).
    CGPoint home = { 0, 0 };
    NSWindow *standin = nil; NSSize standinSize = { 0, 0 }; NSPoint hot = { 0, 0 };
    double primaryH = NSScreen.screens.firstObject.frame.size.height;
    if (drag) {
        CGEventRef ev = CGEventCreate(NULL); home = CGEventGetLocation(ev); CFRelease(ev);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSCursor *cur = NSCursor.currentSystemCursor ?: NSCursor.arrowCursor;
        float cs = 1; extern CGError CGSGetCursorScale(CGSConnectionID, float *);
        CGSGetCursorScale(cid, &cs);
        standinSize = NSMakeSize(cur.image.size.width * cs, cur.image.size.height * cs);
        hot = NSMakePoint(cur.hotSpot.x * cs, cur.hotSpot.y * cs);
        standin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, standinSize.width, standinSize.height)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
        standin.level = CGWindowLevelForKey(kCGCursorWindowLevelKey);
        standin.opaque = NO; standin.backgroundColor = NSColor.clearColor;
        standin.hasShadow = NO; standin.ignoresMouseEvents = YES;
        standin.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary;
        NSImageView *iv = [NSImageView imageViewWithImage:cur.image];
        iv.imageScaling = NSImageScaleAxesIndependently;
        standin.contentView = iv;
        [standin setFrame:NSMakeRect(home.x - hot.x, primaryH - home.y - (standinSize.height - hot.y),
                                     standinSize.width, standinSize.height) display:YES];
        [standin orderFrontRegardless];
        [standin display];
        signal(SIGTERM, zoom_drag_abort); signal(SIGINT, zoom_drag_abort); signal(SIGHUP, zoom_drag_abort);
        CGSSetConnectionProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
        CGDisplayHideCursor(kCGNullDirectDisplay);
        CGAssociateMouseAndMouseCursorPosition(false);    // the trackpad can't move it now
        zoom_drag_post(kCGEventLeftMouseDown, grab);
        atomic_store(&gZoomDragDown, 1);
        usleep(15000);                                     // let the app enter its live resize
    }

    // SCENE_DEBUG: every tick's target vs actual frame of each visible window (+ the
    // drag's pointer), printed after the glide — the tool for "which part lags/drifts".
    BOOL trace = getenv("SCENE_DEBUG") != NULL;
    NSMutableString *log = trace ? [NSMutableString string] : nil;
    static double tickT[1024], tickSet[1024]; int nTick = 0;
    // Everything that reads the window server (lag learning, the trace) runs on its own
    // thread: those reads block for 10–70 ms while apps resize (measured 2026-10-20), and
    // on the tick thread they stalled the ZOOM itself — the whole screen stuttered.
    atomic_store(&gZoomShown, from);
    atomic_store(&gZoomSampling, 1);
    ZoomWin *wsp = ws;
    dispatch_group_t sampler = dispatch_group_create();
    dispatch_group_async(sampler, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CGWindowID vis[32]; ZoomWin *vw[32]; int nv = 0;
        for (int i = 0; i < n; i++) if (!wsp[i].hidden) { vw[nv] = &wsp[i]; vis[nv++] = wsp[i].wid; }
        CFArrayRef ids = CFArrayCreate(NULL, (const void **)vis, nv, NULL);
        while (atomic_load(&gZoomSampling)) {
            double now = ms_since_start() / 1000, zs = atomic_load(&gZoomShown);
            NSArray *d = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(ids));
            if (trace) [log appendFormat:@"%6.1fms z=%.4f", (now - t0) * 1000, zs];
            for (int j = 0; j < nv && j < (int)d.count; j++) {
                ZoomWin *w = vw[j];
                CGRect f = CGRectZero;
                CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)d[j][(id)kCGWindowBounds], &f);
                // Lag: when its width changes, how long ago was that width sent?
                int seen = (int)f.size.width, ni = atomic_load(&w->nIss);
                if (seen != w->lastSeen && w->nLag < 512) {
                    for (int k = ni - 1; k >= 0 && w->lastSeen >= 0; k--)
                        if (abs(w->issW[k] - seen) <= 1) { w->lag[w->nLag++] = now - w->issT[k]; break; }
                    w->lastSeen = seen;
                }
                if (trace) {
                    CGRect r = tile_rect(w->tile, (int)(SW / zs), (int)(SH / zs));
                    [log appendFormat:@" | %u%s want %.0f,%.0f %.0fx%.0f got %.0f,%.0f %.0fx%.0f", w->wid,
                         w->dragged ? "D" : "", r.origin.x, r.origin.y, r.size.width, r.size.height,
                         f.origin.x, f.origin.y, f.size.width, f.size.height];
                }
            }
            if (trace) [log appendString:@"\n"];
            usleep(trace ? 3000 : 8000);                    // lag learning alone needs less
        }
        CFRelease(ids);
    });
    zoom_realtime();
    notify_post("com.callis.screenzoom");                   // screen_frame follows the zoom
    for (;;) {
        double now = ms_since_start() / 1000;
        double t = secs > 0 ? (now - t0) / secs : 1;
        if (t > 1) t = 1;
        double e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;   // WindowShell's S-curve
        z = from + (to - from) * e;
        int sw = (int)(SW / z), sh = (int)(SH / z);

        // Targets first (cheap, async), then the zoom: a zoom set can block on a busy
        // window server, and nothing else on this thread may wait behind it.
        for (int i = 0; i < n; i++) {
            ZoomWin *w = &ws[i];
            if (w->hidden && t < 1) continue;               // covered: sized once, at the end
            // Its target, its lag ahead on the curve (exact at the end).
            double zi = secs > 0 ? zoom_curve(from, to, (now - t0 + w->lead) / secs) : to;
            if (t >= 1) zi = to;
            int swi = (int)(SW / zi), shi = (int)(SH / zi);
            int64_t want = ((int64_t)swi << 32) | (int64_t)shi;
            if (atomic_exchange(&w->want, want) != want) {
                zoom_push(w); sets++;
                int k = atomic_load(&w->nIss);
                if (k < 512) { w->issT[k] = now; w->issW[k] = (int)tile_rect(w->tile, swi, shi).size.width;
                               atomic_store(&w->nIss, k + 1); }
            }
        }
        double tz0 = ms_since_start();
        CGSSetZoomParameters(cid, &pin, z, 0, 1, 0);        // jump to it (0), smoothing on
        atomic_store(&gZoomShown, z);
        if (trace && nTick < 1024) { tickT[nTick] = (now - t0) * 1000; tickSet[nTick++] = ms_since_start() - tz0; }
        if (drag) {                                         // the corner, where the tile's is now
            CGRect r = tile_rect(drag->tile, sw, sh);
            zoom_drag_post(kCGEventLeftMouseDragged,
                           (CGPoint){ CGRectGetMaxX(r) - 3, CGRectGetMaxY(r) - 3 });
            // The stand-in keeps the pointer's spot over the content (as the real one
            // would) at the pointer's size on the glass (the zoom magnifies windows).
            [standin setFrame:NSMakeRect(home.x - hot.x / z,
                                         primaryH - home.y - (standinSize.height - hot.y) / z,
                                         standinSize.width / z, standinSize.height / z) display:YES];
        }
        frames++;
        if (t >= 1) break;
        next += tick;
        uint64_t tnow = mach_absolute_time();
        if (next < tnow) next = tnow;                       // fell behind: don't burst to catch up
        mach_wait_until(next);
    }
    atomic_store(&gZoomSampling, 0);
    dispatch_group_wait(sampler, DISPATCH_TIME_FOREVER);

    if (drag) {                                             // let go, then put everything back
        CGRect r = tile_rect(drag->tile, (int)(SW / z), (int)(SH / z));
        zoom_drag_post(kCGEventLeftMouseUp, (CGPoint){ CGRectGetMaxX(r) - 3, CGRectGetMaxY(r) - 3 });
        atomic_store(&gZoomDragDown, 0);
        usleep(30000);
        dispatch_sync(drag->q, ^{});                        // its last move is in
        drag->dragged = NO;                                 // one exact AX set, for any rounding
        zoom_set(drag, ((int64_t)(int)(SW / z) << 32) | (int)(SH / z));
        CGWarpMouseCursorPosition(home);
        CGAssociateMouseAndMouseCursorPosition(true);
        CGDisplayShowCursor(kCGNullDirectDisplay);
        [standin orderOut:nil];
    }
    // Learn: each app's median lag this glide, folded into what it had (enough samples only).
    for (int i = 0; i < n; i++) {
        ZoomWin *w = &ws[i];
        if (w->nLag < 8) continue;
        qsort_b(w->lag, w->nLag, sizeof(double), ^int(const void *a, const void *b) {
            double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; });
        double med = w->lag[w->nLag / 2];
        zoom_lag_put(w->bundle, 0.6 * w->lead + 0.4 * med);
        if (trace) fprintf(stderr, "  lag %s: median %.0f ms (%d samples), lead was %.0f ms\n",
                           w->bundle, med * 1000, w->nLag, w->lead * 1000);
    }
    // Let the hidden windows' sizes land too (each app's own pace; capped).
    for (int spins = 0; spins < 400; spins++) {
        BOOL idle = YES;
        for (int i = 0; i < n; i++) if (atomic_load(&ws[i].busy)) idle = NO;
        if (idle) break;
        usleep(1000);
    }
    if (getenv("SCENE_DEBUG")) {
        fputs(log.UTF8String, stderr);
        double worst = 0, wset = 0;
        for (int i = 1; i < nTick; i++) if (tickT[i] - tickT[i - 1] > worst) worst = tickT[i] - tickT[i - 1];
        for (int i = 0; i < nTick; i++) if (tickSet[i] > wset) wset = tickSet[i];
        fprintf(stderr, "ticks: %d, worst gap %.1f ms, worst zoom set %.1f ms\n", nTick, worst, wset);
        fprintf(stderr, "zoom %.3f→%.3f %d windows %d ticks %d targets %.0fms\n",
                from, to, n, frames, sets, ms_since_start() - t0 * 1000);
        for (int i = 0; i < n; i++) {
            pid_t pid = 0; AXUIElementGetPid(ws[i].win, &pid);
            NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            fprintf(stderr, "  %-16s %s %d resizes (%.0f/s)\n", a.localizedName.UTF8String,
                    ws[i].hidden ? "hidden " : "visible", atomic_load(&ws[i].done),
                    atomic_load(&ws[i].done) / (secs > 0 ? secs : 1));
        }
    }
    for (int i = 0; i < n; i++) CFRelease(ws[i].win);
    printf("%d %d\n", (int)(SW / z), (int)(SH / z));
    return 0;
}
