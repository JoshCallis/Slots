/*
 * win_at — print the owner name of the topmost on-screen layer-0 window whose
 *          bounds match a rectangle, within a pixel tolerance. Empty if none.
 *
 * Build:
 *   clang -O2 -o ~/bin/win_at ~/bin/win_at.m -framework Foundation -framework CoreGraphics
 *
 * Usage:
 *   win_at X Y W H [excludeOwnerName] [tol]
 *
 * Used by the slot system's window-close to decide whether the window revealed
 * under a closed app "perfectly tiles" the vacated rectangle.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static double dabs(double v){ return v<0?-v:v; }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 5) { fprintf(stderr, "Usage: win_at X Y W H [exclude] [tol]\n"); return 1; }
        double X = atof(argv[1]), Y = atof(argv[2]), W = atof(argv[3]), H = atof(argv[4]);
        NSString *excl = (argc >= 6) ? [NSString stringWithUTF8String:argv[5]] : nil;
        double tol = (argc >= 7) ? atof(argv[6]) : 6.0;

        NSArray *l = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID));
        for (NSDictionary *w in l) {
            if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
            NSString *name = w[(id)kCGWindowOwnerName] ?: @"";
            if (excl && [name isEqualToString:excl]) continue;
            NSDictionary *b = w[(id)kCGWindowBounds];
            double x=[b[@"X"] doubleValue], y=[b[@"Y"] doubleValue];
            double bw=[b[@"Width"] doubleValue], bh=[b[@"Height"] doubleValue];
            if (dabs(x-X)<=tol && dabs(y-Y)<=tol && dabs(bw-W)<=tol && dabs(bh-H)<=tol) {
                printf("%s\n", name.UTF8String);   // first match = topmost
                return 0;
            }
        }
        return 0;  // no match → empty output
    }
}
