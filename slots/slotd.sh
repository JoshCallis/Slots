#!/bin/bash
# slotd.sh — switch the resident slot engine (slots/slotd.py) on or off.
#
#   slotd.sh on        build the client if stale, start the launchd agent, wait for
#                      it to answer, then set the flag the entry scripts check.
#   slotd.sh off       clear the flag first (every op goes straight back to
#                      slotlib.sh), then stop the agent.
#   slotd.sh restart   pick up an edit to slotd.py / realize_plan.py.
#   slotd.sh status    flag, daemon, and the last few requests with their timings.
#
# THE FLAG is config/slots_daemon (gitignored, machine state, survives reboots).
# Off, or the daemon down, = exactly the engine as it was before slotd: the entry
# scripts (goto_app.sh, simple_nav.sh, slots/space_event.sh) only try ~/bin/slotc
# when the flag is set, and run slotlib.sh whenever it doesn't answer "done".
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
REPO=/Users/josh/Code/Scripts
FLAG=$REPO/config/slots_daemon
LABEL=com.josh.slotd
SRC=$REPO/config/launchd/$LABEL.plist
DST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

up() { for _ in $(seq 1 30); do [[ "$(slotc ping 2>/dev/null)" == pong ]] && return 0; sleep 0.1; done; return 1; }

case "${1:-status}" in
  on)
    "$REPO/bin/build.sh" --if-stale slotc || { echo "slotc failed to build"; exit 1; }
    ln -sf "$SRC" "$DST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    launchctl bootstrap "$DOMAIN" "$DST" || { echo "launchctl bootstrap failed"; exit 1; }
    up || { echo "slotd didn't answer — see /tmp/slotd.log; flag left off"; exit 1; }
    touch "$FLAG"
    echo "slotd on"
    ;;
  off)
    rm -f "$FLAG"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    rm -f "$DST"
    echo "slotd off — slotlib.sh handles every op"
    ;;
  restart)
    launchctl kickstart -k "$DOMAIN/$LABEL" && up && echo "slotd restarted" || { echo "slotd didn't come back"; exit 1; }
    ;;
  status)
    [[ -f "$FLAG" ]] && echo "flag: on" || echo "flag: off"
    [[ "$(slotc ping 2>/dev/null)" == pong ]] && echo "daemon: answering" || echo "daemon: not answering"
    tail -8 /tmp/slotd.log 2>/dev/null
    ;;
  *) echo "usage: slotd.sh on|off|restart|status" >&2; exit 2 ;;
esac
