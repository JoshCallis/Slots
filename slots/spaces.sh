#!/bin/bash
# spaces.sh — switch the slots between one shared macOS desktop (the original
# model) and NATIVE SPACES, where every slot owns a real desktop and a switch is a
# window-server flip. See slotlib.sh § native spaces mode.
#
#   spaces.sh on       flag on, bind the current slot to this desktop, add desktops
#                      (Mission Control flashes once per desktop) so every slot has
#                      one, then show the current slot. Other slots get their windows
#                      the first time they are visited.
#   spaces.sh off      flag off, every window on the other desktops comes back to the
#                      first one, the current slot is re-revealed the old way. The
#                      extra desktops are left (empty) — remove them in Mission Control.
#   spaces.sh status   prints on / off.
#
# THE FLAG is config/slots_spaces (gitignored, machine state, survives reboots).
# Apps assigned to "All Desktops" (Dock ▸ Options ▸ Assign To) would show on every
# slot; `on` refuses while a slot app still is, and names them.
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
FLAG=/Users/josh/Code/Scripts/config/slots_spaces
SLOTLIB=/Users/josh/Code/Scripts/slots/slotlib.sh

# Bundle ids of running apps that are assigned to All Desktops.
all_desktop_apps() {
  defaults read com.apple.spaces app-bindings 2>/dev/null \
    | awk -F'"' '/= AllSpaces;/{print $2}'
}

case "${1:-status}" in
  on)
    bound=$(all_desktop_apps)
    if [[ -n "$bound" && "$2" != "--force" ]]; then
      echo "These apps are assigned to All Desktops (Dock ▸ Options ▸ Assign To ▸ None first):" >&2
      printf '  %s\n' $bound >&2
      exit 1
    fi
    touch "$FLAG"
    bash "$SLOTLIB" spacebind
    bash "$SLOTLIB" spacepool 2 || echo "warning: could not add every desktop (see /tmp/slots.log)" >&2
    bash "$SLOTLIB" reveal
    echo on ;;
  off)
    rm -f "$FLAG"
    home=$(yabai -m query --spaces 2>/dev/null \
      | jq '[.[] | select((."is-native-fullscreen" | not) and .display == 1)] | min_by(.index) | .index')
    [[ "$home" =~ ^[0-9]+$ ]] || { echo "yabai space query failed" >&2; exit 1; }
    yabai -m query --windows 2>/dev/null \
      | jq -r --argjson h "$home" '.[] | select(.space != $h and (."is-sticky" | not) and .display == 1
                                            and (."is-native-fullscreen" | not)) | .id' \
      | while read -r id; do yabai -m window "$id" --space "$home" 2>/dev/null; done
    yabai -m space --focus "$home" 2>/dev/null
    bash "$SLOTLIB" reveal
    echo off ;;
  status)
    [[ -f "$FLAG" ]] && echo on || echo off ;;
  *) echo "usage: spaces.sh on [--force]|off|status" >&2; exit 2 ;;
esac
