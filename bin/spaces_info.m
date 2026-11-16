// spaces_info.m — CGS-based space/app info tool
// Compile: clang -o /usr/local/bin/spaces_info /Users/josh/bin/spaces_info.m \
//            -framework Cocoa -framework CoreGraphics
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

typedef uint32_t CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CGSConnectionID CGSMainConnectionID(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);
extern CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, int selector, CFArrayRef windowIDs);

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CGSConnectionID cid = CGSMainConnectionID();

        // --- CURRENT ---
        CGSSpaceID activeSpace = CGSGetActiveSpace(cid);
        printf("CURRENT %llu\n", (unsigned long long)activeSpace);

        // --- SPACE lines ---
        // Build a set of all space IDs and their types
        NSMutableDictionary<NSNumber *, NSNumber *> *spaceTypes = [NSMutableDictionary dictionary];
        CFArrayRef displaySpaces = CGSCopyManagedDisplaySpaces(cid);
        if (displaySpaces) {
            NSArray *displays = (__bridge NSArray *)displaySpaces;
            for (NSDictionary *display in displays) {
                NSArray *spaces = display[@"Spaces"];
                for (NSDictionary *spaceInfo in spaces) {
                    NSNumber *spaceID = spaceInfo[@"id64"];
                    NSNumber *type = spaceInfo[@"type"];
                    if (spaceID && type) {
                        spaceTypes[spaceID] = type;
                        printf("SPACE %llu %d\n",
                               (unsigned long long)[spaceID unsignedLongLongValue],
                               [type intValue]);
                    }
                }
            }
            CFRelease(displaySpaces);
        }

        // --- APP lines ---
        // Get all windows
        CFArrayRef windowList = CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);

        if (!windowList) return 0;

        NSArray *windows = (__bridge_transfer NSArray *)windowList;

        // Build pid -> app name map from running applications
        NSMutableDictionary<NSNumber *, NSString *> *pidToApp = [NSMutableDictionary dictionary];
        for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
            if (app.localizedName) {
                pidToApp[@(app.processIdentifier)] = app.localizedName;
            }
        }

        // Track which app names we've already emitted
        NSMutableSet<NSString *> *emittedApps = [NSMutableSet set];

        for (NSDictionary *window in windows) {
            // Only layer-0 windows
            NSNumber *layer = window[(NSString *)kCGWindowLayer];
            if (!layer || [layer intValue] != 0) continue;

            NSNumber *windowID = window[(NSString *)kCGWindowNumber];
            if (!windowID) continue;

            NSNumber *pid = window[(NSString *)kCGWindowOwnerPID];
            if (!pid) continue;

            NSString *appName = pidToApp[pid];
            if (!appName) continue;

            // Skip if we already emitted this app
            if ([emittedApps containsObject:appName]) continue;

            // Find which space this window is on
            NSArray *winIDArray = @[windowID];
            CFArrayRef spacesRef = CGSCopySpacesForWindows(cid, 7,
                (__bridge CFArrayRef)winIDArray);
            if (!spacesRef) continue;

            NSArray *spaces = (__bridge_transfer NSArray *)spacesRef;
            if (spaces.count == 0) continue;

            NSNumber *spaceID = spaces[0];
            // Verify this space is a known user space
            if (!spaceTypes[spaceID]) continue;

            [emittedApps addObject:appName];
            printf("APP %llu %s\n",
                   (unsigned long long)[spaceID unsignedLongLongValue],
                   [appName UTF8String]);
        }
    }
    return 0;
}
