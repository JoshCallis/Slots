/*
 * activate_app — bring a running application to the front, and make it STICK.
 *
 * Build: ~/bin/build_helpers.sh activate_app
 *
 * Usage:
 *   activate_app "Google Chrome"      exact localizedName match
 *   activate_app "Fusion" --partial   substring match (first hit wins)
 *   activate_app NAME --no-ensure     activate once, no follow-up watcher
 *
 * Why the watcher (2026-10-16, "switch to Photoshop lands on Finder"): the slot
 * engine flips the desktop and activates at once. While the Space animation runs
 * (longest off 3ds Max's full-screen Space), macOS's cooperative activation can
 * drop the request; when the animation ends, the old front app has no window on
 * the new desktop and the Dock hands focus to Finder. Each earlier fix tuned the
 * timing of one path; this fixes the class at the one call every path shares.
 *
 * So after activating, a detached child (`--watch`) watches for ~2 s and re-asserts
 * the target whenever focus has landed "nowhere": the front app has no normal
 * window on screen (Finder's desktop, or a stranded previous app) while the target
 * DOES have one. Retries 3+ use SkyLight's set-front-process + make-key event (what
 * yabai's window --focus does, minus its Accessibility reads). It gives up at
 * once when the user moves on: a newer jump (/tmp/slot_jump_gen changed), the
 * target's window leaves the screen (another desktop), or a real app with a
 * visible window took focus. The caller never waits for it.
 */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <spawn.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

extern char **environ;

typedef CGError (*SetFrontFn)(ProcessSerialNumber *, uint32_t, uint32_t);
typedef CGError (*PostEventFn)(ProcessSerialNumber *, uint8_t *);

static NSString *readGen(void) {
    return [NSString stringWithContentsOfFile:@"/tmp/slot_jump_gen"
                                     encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

// The frontmost normal (layer 0) on-screen window of pid, 0 if none. Tiny/clear
// windows (cursor helpers, 1px trackers) don't count.
static uint32_t onscreenWindow(pid_t pid) {
    uint32_t wid = 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return 0;
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([w[(id)kCGWindowAlpha] doubleValue] <= 0.01) continue;
        CGRect r;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
        if (r.size.width < 100 || r.size.height < 100) continue;
        wid = [w[(id)kCGWindowNumber] unsignedIntValue];
        break;                                   // list is front-to-back
    }
    CFRelease(list);
    return wid;
}

// yabai's focus: SkyLight set-front-process on the window, then the two
// make-key-window event records. No Accessibility involved.
static void skylightFront(pid_t pid, uint32_t wid) {
    static SetFrontFn setFront; static PostEventFn post; static BOOL looked;
    if (!looked) {
        looked = YES;
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sl) {
            setFront = (SetFrontFn)dlsym(sl, "_SLPSSetFrontProcessWithOptions");
            post     = (PostEventFn)dlsym(sl, "SLPSPostEventRecordTo");
        }
    }
    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) != noErr) return;
#pragma clang diagnostic pop
    if (setFront) setFront(&psn, wid, 0x200);    // kCPSUserGenerated
    if (post && wid) {
        uint8_t b[0xf8];
        for (uint8_t kind = 1; kind <= 2; kind++) {
            memset(b, 0, sizeof b);
            b[0x04] = 0xf8; b[0x08] = kind; b[0x3a] = 0x10;
            memset(b + 0x20, 0xff, 0x10);
            memcpy(b + 0x3c, &wid, sizeof wid);
            post(&psn, b);
        }
    }
}

static void logLine(NSString *msg) {
    FILE *f = fopen("/tmp/slots.log", "a");
    if (!f) return;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    fprintf(f, "[%s] [activate_app] %s\n", [df stringFromDate:NSDate.date].UTF8String, msg.UTF8String);
    fclose(f);
}

// The target has no window to show: log it only. The HUD warning was removed at the
// user's request (2026-10-18) — never put this on screen.
static void notReady(NSString *name) {
    logLine([NSString stringWithFormat:@"[not_ready] %@: no window on this desktop (alert open / still starting?)", name]);
}

// --watch PID GEN: keep focus on PID for the next ~2 s (see header).
static int watch(pid_t pid, NSString *gen) {
    NSRunningApplication *target = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!target) return 0;
    NSWorkspace *ws = NSWorkspace.sharedWorkspace;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent(), heldSince = 0;
    int retries = 0;
    while (CFAbsoluteTimeGetCurrent() - t0 < 2.0) {
        // frontmostApplication is updated by notifications: let the run loop deliver them.
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.04]];
        if (![readGen() isEqualToString:gen]) return 0;          // a newer jump owns focus now
        if (target.terminated) return 0;
        double el = CFAbsoluteTimeGetCurrent() - t0;
        uint32_t tw = onscreenWindow(pid);
        if (!tw) {
            if (el > 0.8) {                      // not on this desktop (animation long over)
                // ...and nothing else with a window has focus either: the switch shows
                // nothing (Photoshop behind an alert, Max on a stuck splash — 2026-10-16).
                // Say so rather than look like a dead key.
                // Background helpers (Adobe's Finder extension, Autodesk Identity
                // Manager) never have windows: not worth a HUD (2026-10-18).
                if (target.activationPolicy == NSApplicationActivationPolicyRegular &&
                    !onscreenWindow(ws.frontmostApplication.processIdentifier)) notReady(target.localizedName);
                return 0;
            }
            heldSince = 0;
            continue;                            // Space animation still running
        }
        pid_t fp = ws.frontmostApplication.processIdentifier;
        if (fp == pid) {
            if (!heldSince) heldSince = CFAbsoluteTimeGetCurrent();
            else if (CFAbsoluteTimeGetCurrent() - heldSince > 0.6) return 0;   // it stuck
            continue;
        }
        heldSince = 0;
        if (onscreenWindow(fp)) return 0;        // a real app took focus (a click): leave it
        NSString *fname = ws.frontmostApplication.localizedName ?: @"?";
        retries++;
        logLine([NSString stringWithFormat:@"%@: focus landed on %@ (no window here) after %.2fs — re-assert #%d",
                 target.localizedName, fname, el, retries]);
        if (retries <= 2) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [target activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
        } else {
            skylightFront(pid, tw);
        }
        if (retries >= 6) return 1;
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 4 && strcmp(argv[1], "--watch") == 0)
            return watch((pid_t)atoi(argv[2]), [NSString stringWithUTF8String:argv[3]]);
        if (argc < 2) {
            fprintf(stderr, "Usage: activate_app <name> [--partial] [--no-ensure]\n");
            return 1;
        }
        NSString *name = [NSString stringWithUTF8String:argv[1]];
        BOOL partial = NO, ensure = YES;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--partial") == 0) partial = YES;
            if (strcmp(argv[i], "--no-ensure") == 0) ensure = NO;
        }
        (void)partial;   // both passes always run; the flag is kept for old callers
        // Regular (Dock) apps only: a background helper sharing the name ("Autodesk
        // Identity Manager" for "Autodesk", Adobe's Finder extension) is never the target.
        NSArray<NSRunningApplication *> *apps = [NSWorkspace.sharedWorkspace.runningApplications
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSRunningApplication *a, id _) {
                return a.activationPolicy == NSApplicationActivationPolicyRegular; }]];
        // 1. Exact match
        NSRunningApplication *target = nil;
        for (NSRunningApplication *app in apps) {
            NSString *n = app.localizedName ?: @"";
            if ([n isEqualToString:name]) { target = app; break; }
        }
        // 2. Partial match fallback — bidirectional, same as scene_restore
        if (!target) {
            for (NSRunningApplication *app in apps) {
                NSString *n = app.localizedName ?: @"";
                if (n.length && ([n containsString:name] || [name containsString:n])) { target = app; break; }
            }
        }
        if (!target) {
            fprintf(stderr, "activate_app: '%s' not running\n", name.UTF8String);
            return 1;
        }
        NSString *gen = readGen();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [target activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
        printf("activate_app: activated '%s' (pid %d)\n",
               target.localizedName.UTF8String, (int)target.processIdentifier);
        fflush(stdout);
        if (ensure) {                            // detached watcher; the caller never waits
            char self[PATH_MAX]; uint32_t sz = sizeof self;
            if (_NSGetExecutablePath(self, &sz) == 0) {
                char pidbuf[16]; snprintf(pidbuf, sizeof pidbuf, "%d", (int)target.processIdentifier);
                char *av[] = { self, "--watch", pidbuf, (char *)(gen.length ? gen.UTF8String : "-"), NULL };
                posix_spawnattr_t at; posix_spawnattr_init(&at);
                posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSID);
                posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
                for (int fd = 0; fd <= 2; fd++)          // don't hold the caller's pipes open
                    posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
                pid_t child;
                posix_spawn(&child, self, &fa, &at, av, environ);
                posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at);
            }
        }
        return 0;
    }
}
