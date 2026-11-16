/*
 * slotc — the client for slots/slotd.py, the resident slot engine.
 *
 * WHY C: it sits on the hotkey path (goto_app.sh, simple_nav.sh, space_event.sh),
 * which slotd exists to make fast. A Python client would spend ~25 ms starting up,
 * `nc -U` can't report a fallback; this is a connect, a write and a read (~1 ms).
 *
 * Usage:
 *   slotc OP [ARG...]      e.g. `slotc goto fusion`, `slotc nav +1`, `slotc ping`
 *
 * Prints the op's stdout (a switch op's "PREV|NEW" line). Exit status:
 *   0  slotd did it
 *   3  slotd handed it back (FALLBACK) — the caller runs `bash slotlib.sh OP …`
 *   2  no daemon                       — likewise
 *   4  dropped: a jump past its 3 s deadline or superseded by a newer key press
 *      (slots/jump_stamp.sh), or no answer within 3.5 s — the caller does NOTHING
 *      (running slotlib then would be a jump seconds after the press)
 * Wire format: "\1<$SLOT_GEN>\1<now, ms>", then the args, each NUL-terminated,
 * then EOF; the reply is a status byte ('0' done, 'F' fallback, 'X' dropped)
 * followed by the output.
 *
 * Build: bin/build.sh slotc   (→ ~/bin/slotc)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCK_PATH "/tmp/slotd.sock"

static int write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: slotc OP [ARG...]\n");
        return 2;
    }
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return 2;
    // slotd drops a jump 3 s after the press (lock wait and yabai calls included);
    // no answer by 3.5 s means it is wedged — and too late to jump anyway.
    struct timeval rcv = {3, 500000}, snd = {2, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &rcv, sizeof rcv);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &snd, sizeof snd);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, SOCK_PATH, sizeof a.sun_path - 1);
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) return 2;
    struct timeval now;
    gettimeofday(&now, NULL);
    const char *gen = getenv("SLOT_GEN");
    char meta[256];
    snprintf(meta, sizeof meta, "\1%s\1%lld", gen ? gen : "",
             (long long)now.tv_sec * 1000 + now.tv_usec / 1000);
    if (write_all(s, meta, strlen(meta) + 1) < 0) return 2;
    for (int i = 1; i < argc; i++)
        if (write_all(s, argv[i], strlen(argv[i]) + 1) < 0) return 2;
    shutdown(s, SHUT_WR);

    char buf[65536];
    size_t n = 0;
    for (;;) {
        ssize_t r = read(s, buf + n, sizeof buf - 1 - n);
        if (r < 0) return 4;            // timed out: no answer — too late now
        if (r == 0) break;
        n += (size_t)r;
        if (n == sizeof buf - 1) break;
    }
    close(s);
    if (n < 1) return 2;
    if (buf[0] == 'F') return 3;
    if (buf[0] == 'X') return 4;
    if (buf[0] != '0') return 2;
    if (n > 1) {
        fwrite(buf + 1, 1, n - 1, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
