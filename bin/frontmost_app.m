/*
 * frontmost_app — print the name of the frontmost application to stdout.
 *
 * Uses CGWindowList (CoreGraphics only, no AppKit) so startup is fast.
 * Windows are returned front-to-back; the first layer-0 entry is the
 * frontmost regular app window.
 *
 * Build:
 *   clang -O2 -o ~/bin/frontmost_app ~/bin/frontmost_app.m -framework Foundation -framework CoreGraphics
 *
 * Usage:
 *   frontmost_app          → prints e.g. "Google Chrome"
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(void) {
    @autoreleasepool {
        NSArray *list = CFBridgingRelease(
            CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly |
                kCGWindowListExcludeDesktopElements,
                kCGNullWindowID));

        for (NSDictionary *info in list) {
            if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
            NSString *name = info[(id)kCGWindowOwnerName];
            if (name.length) {
                printf("%s\n", name.UTF8String);
                return 0;
            }
        }
        return 1;
    }
}
