/*
 * win_list — print on-screen, layer-0 windows in front-to-back (z) order, one
 *            per line as:  owner|x|y|w|h   (integers, global top-left origin).
 *
 * Build:
 *   clang -O2 -o ~/bin/win_list ~/bin/win_list.m -framework Foundation -framework CoreGraphics
 *
 * Usage:
 *   win_list
 *
 * Unlike win_at (which matches one rectangle and is blind to whether a window is
 * covered by a larger one on top), this dumps the full stacking order so the
 * caller can compute true visibility — which snapped tile is actually on top and
 * not covered by anything above it.
 *
 * ⚠️  CAVEAT — this lists what is ON SCREEN, which is NOT the same as "windows that
 * belong to the current Space". kCGWindowListOptionOnScreenOnly also returns sticky
 * windows that join all Spaces (canJoinAllSpaces) — notably Fusion's palettes/
 * dialogs, which float on every Space under the same owner name ("Fusion") as the
 * real canvas. The window owner here CANNOT distinguish a palette from the document
 * window. Callers that adopt windows into a per-Space model (slots' failsafe) MUST
 * filter those out by AX subrole (the canvas is AXStandardWindow; palettes are not)
 * before trusting an "owner is on this Space" inference — otherwise a palette teaches
 * the model that Fusion lives on a Space it doesn't, and its real Space loses it.
 * See slots/slotlib.sh: cad_aux_geoms / filter_cad_aux / win_list_raw.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray *l = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID));
        for (NSDictionary *w in l) {
            if ([w[(id)kCGWindowLayer] intValue] != 0) continue;   // normal windows only
            NSString *name = w[(id)kCGWindowOwnerName] ?: @"";
            if (name.length == 0) continue;
            NSDictionary *b = w[(id)kCGWindowBounds];
            if (!b) continue;
            long x = lround([b[@"X"] doubleValue]);
            long y = lround([b[@"Y"] doubleValue]);
            long bw = lround([b[@"Width"] doubleValue]);
            long bh = lround([b[@"Height"] doubleValue]);
            printf("%s|%ld|%ld|%ld|%ld\n", name.UTF8String, x, y, bw, bh);
        }
    }
    return 0;
}
