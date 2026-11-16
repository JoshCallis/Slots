/*
 * space_query — desktops and windows straight from the window server, for the
 * slots' native-spaces mode. Read-only; no Accessibility, no yabai.
 *
 * Why not `yabai -m query`: yabai answers one request at a time, and a window
 * query (or a window focus) reads apps' Accessibility attributes — a busy Fusion
 * holds that for 15s+, and every slot switch queued behind it (2026-10-10). The
 * window server answers these whatever the apps are doing.
 *
 * Usage:
 *   space_query active          "<index> <uuid>" of the active desktop
 *   space_query json            {"spaces":[…],"windows":[…]} — see below
 *   space_query winlist UUID    the windows ON that desktop, front to back, as
 *                               "owner|x|y|w|h" — win_list's format, but for any
 *                               desktop, shown or not (the slot reconcile's input)
 *   space_query has NAME...     exit 0 if any NAME owns a window on some desktop
 *
 * json — spaces: index (1-based, yabai's numbering: displays in order, then their
 * spaces), id, uuid, display (1-based), fullscreen (bool), active (bool).
 * windows (layer 0, at least 50x50, front to back): id, pid, app (owner name),
 * x y w h, spaces (ids it is on: several = sticky; [] = on none — minimized,
 * hidden, or ordered out), onscreen, front (the topmost on-screen window).
 * `json --all` drops the 50x50 floor — coherence_home needs Parallels' thin strips
 * (a 1024x48 VM-helper window sat over every Space, 2026-10-11).
 *
 * Start-up is ~40ms under load, almost all of it opening the window-server
 * connection — AppKit is deliberately not linked (another ~40ms).
 *
 * Build:
 *   clang -O2 -o ~/bin/space_query ~/Code/Scripts/bin/space_query.m -framework Foundation -framework CoreGraphics
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef uint32_t CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern uint64_t CGSGetActiveSpace(CGSConnectionID cid);
extern CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef wids);
// A desktop's windows in stacking order, front to back — the list yabai builds its
// per-space queries from. (The general CGWindowList is front-to-back only for the
// desktop being shown.) Resolved at run time: it is SkyLight-only, and linking
// SkyLight would not resolve the CGS names above.
typedef CFArrayRef (*CopyWindowsFn)(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options,
                                    uint64_t *set_tags, uint64_t *clear_tags);
#include <dlfcn.h>

static NSArray *spaceList(CGSConnectionID cid) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *displays = CFBridgingRelease(CGSCopyManagedDisplaySpaces(cid));
    uint64_t active = CGSGetActiveSpace(cid);
    int idx = 0, d = 0;
    for (NSDictionary *disp in displays) {
        d++;
        for (NSDictionary *s in disp[@"Spaces"]) {
            NSNumber *sid = s[@"id64"] ?: s[@"ManagedSpaceID"];
            if (!sid) continue;
            idx++;
            [out addObject:@{@"index": @(idx), @"id": sid, @"uuid": s[@"uuid"] ?: @"",
                             @"display": @(d), @"fullscreen": @([s[@"type"] intValue] == 4),
                             @"active": @(sid.unsignedLongLongValue == active)}];
        }
    }
    return out;
}

static NSArray *spacesOf(CGSConnectionID cid, NSNumber *wid) {
    return CFBridgingRelease(CGSCopySpacesForWindows(cid, 0x7, (__bridge CFArrayRef)@[wid])) ?: @[];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: space_query active|json|winlist UUID|has NAME...\n"); return 2; }
        CGSConnectionID cid = CGSMainConnectionID();
        NSString *mode = @(argv[1]);
        NSArray *spaces = spaceList(cid);

        if ([mode isEqualToString:@"active"]) {
            for (NSDictionary *s in spaces)
                if ([s[@"active"] boolValue]) { printf("%d %s\n", [s[@"index"] intValue], [s[@"uuid"] UTF8String]); return 0; }
            return 1;
        }
        if ([mode isEqualToString:@"winlist"]) {
            if (argc < 3) return 2;
            NSNumber *sid = nil;
            for (NSDictionary *s in spaces) if ([s[@"uuid"] isEqualToString:@(argv[2])]) sid = s[@"id"];
            if (!sid) return 1;
            void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
            CopyWindowsFn copyWindows = sl ? (CopyWindowsFn)dlsym(sl, "SLSCopyWindowsWithOptionsAndTags") : NULL;
            if (!copyWindows) return 1;
            uint64_t set = 0, clear = 0;
            NSArray *ids = CFBridgingRelease(copyWindows((int)cid, 0, (__bridge CFArrayRef)@[sid], 0x2, &set, &clear));
            if (!ids.count) return 0;
            // CGWindowListCreateDescriptionFromArray wants raw CGWindowIDs, not CFNumbers.
            const void *raw[ids.count];
            for (NSUInteger i = 0; i < ids.count; i++) raw[i] = (const void *)(uintptr_t)[ids[i] unsignedIntValue];
            CFArrayRef rawIds = CFArrayCreate(NULL, raw, ids.count, NULL);
            NSArray *info = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(rawIds));
            CFRelease(rawIds);
            for (NSDictionary *w in info) {                  // same filter as win_list
                if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
                NSString *app = w[(id)kCGWindowOwnerName];
                CGRect r;
                if (app.length == 0 || !CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
                printf("%s|%.0f|%.0f|%.0f|%.0f\n", app.UTF8String, r.origin.x, r.origin.y, r.size.width, r.size.height);
            }
            return 0;
        }
        NSMutableSet *names = nil;
        if ([mode isEqualToString:@"has"]) {
            names = [NSMutableSet set];
            for (int i = 2; i < argc; i++) [names addObject:@(argv[i])];
        }

        NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
        NSMutableArray *wins = [NSMutableArray array];
        BOOL frontSeen = NO;
        BOOL all = argc > 2 && !strcmp(argv[2], "--all");
        for (NSDictionary *w in list) {
            if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
            NSString *app = w[(id)kCGWindowOwnerName];
            if (app.length == 0) continue;
            CGRect r;
            if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
            NSNumber *wid = w[(id)kCGWindowNumber];
            if ((r.size.width < 50 || r.size.height < 50) && !all) continue;
            if (names) {
                if ([names containsObject:app] && spacesOf(cid, wid).count) return 0;
                continue;
            }
            BOOL onscreen = [w[(id)kCGWindowIsOnscreen] boolValue];
            BOOL front = NO;                        // list is front-to-back
            if (!frontSeen && onscreen) { front = YES; frontSeen = YES; }
            [wins addObject:@{@"id": wid, @"pid": w[(id)kCGWindowOwnerPID], @"app": app,
                              @"x": @(r.origin.x), @"y": @(r.origin.y), @"w": @(r.size.width), @"h": @(r.size.height),
                              @"spaces": spacesOf(cid, wid), @"onscreen": @(onscreen), @"front": @(front)}];
        }
        if (names) return 1;
        NSData *j = [NSJSONSerialization dataWithJSONObject:@{@"spaces": spaces, @"windows": wins} options:0 error:nil];
        fwrite(j.bytes, 1, j.length, stdout); fputc('\n', stdout);
    }
    return 0;
}
