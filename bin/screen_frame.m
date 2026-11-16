/*
 * screen_frame — a permanent 2px black line around the edge of every display,
 * drawn above everything.
 *
 * One borderless, click-through window per NSScreen, at (max level − 1), joined
 * to every Space (incl. fullscreen ones) and stationary under Mission Control.
 * The stroke is TWO PHYSICAL PIXELS (2/backingScaleFactor pt), inset so it sits
 * wholly on-screen — i.e. 1pt at 2x, 2pt at 1x. Its inner edge has rounded
 * corners (cornerRadius) so the black fills the gaps windows' corners leave.
 *
 * Invisible to slots: win_list only reports layer-0 windows, and yabai is told
 * to leave it alone (config/yabai/yabairc, `app="^screen_frame$" manage=off`).
 * Rebuilds its windows on any display change (plug, resolution, arrangement).
 *
 * UI Zoom's screen zoom (ui_zoom.sh § Screen zoom) magnifies every window, this one
 * too, pinned top-left — so while it is on, the main display's frame is drawn round
 * the VISIBLE part (w/z × h/z) with its stroke and corners ÷ z, and lands on the glass
 * edges looking as it does unzoomed. `scene_restore --zoom` posts ZOOM_NOTE as a
 * glide starts; the frame then follows the zoom every refresh until it settles. The
 * stand-in glide instead draws an identical frame itself, in lockstep with the zoom,
 * and hides this one meanwhile (ZOOM_NOTE.hold / .done).
 *
 * Seams (screen_frame.h): where two windows meet at the main display's top / bottom
 * edge (left + right tiles, quadrants), their facing corners are rounded in black too.
 * Found from the on-screen window list — polled, plus on every Space change — and
 * kept as fractions of the visible width, so they follow the zoom like the rest.
 *
 * Launched (singleton) from config/yabai/yabairc.
 * Build: bin/build.sh screen_frame
 */
#import <Cocoa/Cocoa.h>
#include <notify.h>
#include "screen_frame.h"

#define ZOOM_NOTE "com.callis.screenzoom"
typedef uint32_t CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSGetZoomParameters(CGSConnectionID, CGPoint *center, double *scale, unsigned char *smooth);

static double gZoom = 1;                  // the screen zoom the main display's frame is drawn for
static double gSeam[4] = {-1, -1, -1, -1};  // main display's seams, fractions of visible width (screen_frame.h)
static BOOL gGliding;                     // a zoom glide is moving the windows: seams held as they were
static double screenZoom(void) {
    CGPoint c; double s = 1; unsigned char sm;
    if (CGSGetZoomParameters(CGSMainConnectionID(), &c, &s, &sm) || s < 1) s = 1;
    return s;
}

@interface FrameView : NSView
@property double zoom;                    // 1, or the screen zoom (main display)
@property BOOL main;                      // draws the seams
@end
@implementation FrameView
// Corner radius (pt) of the frame's inner edge, so windows' rounded corners filling
// the screen don't show wallpaper through: everything outside a rounded rect inset
// by the stroke is black. Override: SCREEN_FRAME_RADIUS=<pt>.
static CGFloat cornerRadius(void) {
    const char *e = getenv("SCREEN_FRAME_RADIUS");
    return e ? atof(e) : 16.0;
}

- (void)drawRect:(NSRect)dirty {
    double z = self.zoom > 1 ? self.zoom : 1;
    CGFloat px = 2.0 / (self.window.backingScaleFactor ?: 1.0) / z;
    CGFloat r = cornerRadius() / z;
    NSRect b = self.bounds;
    // The visible part: the top-left w/z × h/z (y-up here). The window itself never
    // moves — a window origin is whole points, and a moved one landed a fraction
    // off the glass edge (a white line along the top, 2026-10-20).
    NSRect v = NSMakeRect(0, b.size.height - b.size.height / z, b.size.width / z, b.size.height / z);
    double seam[4];
    for (int i = 0; i < 4; i++) seam[i] = self.main && gSeam[i] >= 0 ? gSeam[i] * v.size.width : -1;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddRect(p, NULL, b);
    sf_hole(p, NSInsetRect(v, px, px), r, px / 2, seam);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGContextAddPath(cg, p);
    CGContextSetFillColorWithColor(cg, CGColorGetConstantColor(kCGColorBlack));
    CGContextEOFillPath(cg);
    CGPathRelease(p);
}
@end

@interface Controller : NSObject
@property (strong) NSMutableArray<NSWindow *> *windows;
@end
@implementation Controller
- (void)rebuild {
    for (NSWindow *w in self.windows) [w orderOut:nil];
    self.windows = [NSMutableArray array];
    for (NSScreen *s in NSScreen.screens) {
        NSWindow *w = [[NSWindow alloc] initWithContentRect:s.frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.releasedWhenClosed = NO;
        w.opaque = NO;
        w.backgroundColor = NSColor.clearColor;
        w.hasShadow = NO;
        w.ignoresMouseEvents = YES;
        w.level = CGWindowLevelForKey(kCGMaximumWindowLevelKey) - 1;
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                             | NSWindowCollectionBehaviorStationary
                             | NSWindowCollectionBehaviorFullScreenAuxiliary
                             | NSWindowCollectionBehaviorIgnoresCycle;
        FrameView *fv = [[FrameView alloc] initWithFrame:NSMakeRect(0, 0, s.frame.size.width, s.frame.size.height)];
        fv.main = !self.windows.count;                          // NSScreen.screens[0] = main
        w.contentView = fv;
        [w setFrame:s.frame display:YES];
        [w orderFrontRegardless];
        [self.windows addObject:w];
    }
    gZoom = 1;
    [self followZoom];
}

// The main display's frame at the current screen zoom: the visible top-left part.
- (void)followZoom {
    double z = screenZoom();
    if (fabs(z - gZoom) < 0.0001 || !self.windows.count) return;
    gZoom = z;
    NSWindow *w = self.windows.firstObject;                     // NSScreen.screens[0] = main
    FrameView *v = (FrameView *)w.contentView;
    v.zoom = z;
    [v display];
}

// A glide started: follow it every refresh until the zoom has held still for 0.5 s.
- (void)glide {
    static NSTimer *timer;
    static double still;
    [timer invalidate];
    still = 0;
    timer = [NSTimer timerWithTimeInterval:1.0 / 165 repeats:YES block:^(NSTimer *t) {
        double before = gZoom;
        [self followZoom];
        still = fabs(gZoom - before) < 0.0001 ? still + t.timeInterval : 0;
        gGliding = still <= 0.5;
        if (!gGliding) [t invalidate];
    }];
    gGliding = YES;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

// ── Seams ────────────────────────────────────────────────────────────────────
// The frontmost listed window containing (x, y), or -1.
static int frontAt(CGRect *rs, int n, double x, double y) {
    for (int i = 0; i < n; i++) if (CGRectContainsPoint(rs[i], CGPointMake(x, y))) return i;
    return -1;
}

// Where two windows meet at the main display's top / bottom edge: a window whose right
// edge is front just left of x, and front just right of it one starting within 3 pt
// (the 1 pt gutter slotlib's pos_rect leaves), both touching that edge. Global coords
// (y-down), in the visible part while zoomed — the same frame the windows are fit to.
- (void)findSeams {
    if (gGliding || !self.windows.count) return;
    double z = screenZoom();
    CGRect m = CGDisplayBounds(CGMainDisplayID());
    double W = m.size.width / z, H = m.size.height / z;
    CGRect rs[64]; int n = 0;
    pid_t me = getpid();
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    for (NSDictionary *d in (__bridge NSArray *)list) {
        if (n >= 64) break;
        if ([d[(id)kCGWindowLayer] intValue] != 0 || [d[(id)kCGWindowOwnerPID] intValue] == me) continue;
        if ([d[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        if ([d[(id)kCGWindowOwnerName] isEqualToString:@"borders"]) continue;   // JankyBorders' overlays
        CGRect r;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &r)) continue;
        if (r.size.width < 100 || r.size.height < 100) continue;
        rs[n++] = r;
    }
    if (list) CFRelease(list);
    double seam[4] = {-1, -1, -1, -1};
    for (int e = 0; e < 2; e++) {
        double y = e ? H - 4 : 4;
        for (int i = 0; i < n; i++) {
            CGRect a = rs[i];
            double x = CGRectGetMaxX(a);
            if (x < 40 || x > W - 40 || frontAt(rs, n, x - 4, y) != i) continue;
            int j = frontAt(rs, n, x + 4, y);
            if (j < 0) continue;
            CGRect b = rs[j];
            if (b.origin.x < x - 0.5 || b.origin.x > x + 3) continue;
            if (e ? (CGRectGetMaxY(a) < H - 1 || CGRectGetMaxY(b) < H - 1) : (a.origin.y > 1 || b.origin.y > 1)) continue;
            seam[e * 2] = x / W; seam[e * 2 + 1] = b.origin.x / W;
            break;
        }
    }
    if (!memcmp(seam, gSeam, sizeof seam)) return;
    memcpy(gSeam, seam, sizeof seam);
    FILE *f = fopen(SEAM_FILE, "w");
    if (f) { fprintf(f, "%.6f %.6f %.6f %.6f\n", seam[0], seam[1], seam[2], seam[3]); fclose(f); }
    [self.windows.firstObject.contentView display];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyProhibited;  // no Dock, no focus
        Controller *c = [Controller new];
        [c rebuild];
        [NSNotificationCenter.defaultCenter
            addObserverForName:NSApplicationDidChangeScreenParametersNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *n) { [c rebuild]; }];
        int tok;
        notify_register_dispatch(ZOOM_NOTE, &tok, dispatch_get_main_queue(), ^(int t) { [c glide]; });
        // The stand-in glide draws this frame itself, in step with the zoom: HOLD hides
        // ours (theirs is up, identical, first); DONE = draw at the final zoom and show.
        int hold, done;
        notify_register_dispatch(ZOOM_NOTE ".hold", &hold, dispatch_get_main_queue(), ^(int t) {
            c.windows.firstObject.alphaValue = 0;
            gGliding = YES;                                     // its overlay would hide the seams
        });
        notify_register_dispatch(ZOOM_NOTE ".done", &done, dispatch_get_main_queue(), ^(int t) {
            gGliding = NO;
            gZoom = 0; [c followZoom];
            c.windows.firstObject.alphaValue = 1;
        });
        // Seams: polled (snaps, resizes), and straight after a Space change.
        [c findSeams];
        [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) { [c findSeams]; }];
        [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *n) { [c findSeams]; }];
        [app run];
    }
    return 0;
}
