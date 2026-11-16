#!/bin/bash
# Register any new fullscreen spaces for desktop-overlay rendering ("working"
# mode), so swiping to them is instant and floaters (Finder etc.) can appear
# above them.
#
# The pattern: space_focus to a fullscreen space, then space_focus to the
# desktop. Empirically this converts a space from macOS-native fullscreen
# (animated switches, blocks floaters) to desktop-overlay mode (instant
# switches, accepts floaters).
#
# State tracked in /tmp/yabai_registered_spaces (list of CGS IDs already
# round-tripped). Stale IDs (spaces no longer in nav_cache) are pruned.
#
# Called from:
#   - yabai_cache_debounced.sh (after a debounced cache rebuild post-launch)
#   - yabai_reset.sh
# NOT from yabai_nav.sh's post-swipe rebuild (would flash right after swipes).
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"

LOG=/tmp/yabai_register.log
log() { echo "[$(date '+%H:%M:%S.%3N')] $*" >> "$LOG"; }
log "=== yabai_register fired ==="

REGISTERED=/tmp/yabai_registered_spaces
touch "$REGISTERED"

NAV_LIST=()
while IFS= read -r line; do
  [[ -n "$line" ]] && NAV_LIST+=("$line")
done < /tmp/yabai_nav_cache 2>/dev/null

if (( ${#NAV_LIST[@]} == 0 )); then
  log "ABORT: empty nav_cache"
  exit 0
fi

SI=$(spaces_info)
DESKTOP=$(echo "$SI" | awk '/^SPACE / && $3==0 {print $2; exit}')
CURRENT=$(echo "$SI" | awk '/^CURRENT/{print $2}')

if [[ -z "$DESKTOP" ]]; then
  log "ABORT: no desktop space (type 0) found"
  exit 0
fi

# Find spaces in nav_cache that haven't been registered yet
NEW=()
for cgid in "${NAV_LIST[@]}"; do
  grep -qxF "$cgid" "$REGISTERED" || NEW+=("$cgid")
done

log "nav_list=(${NAV_LIST[*]}) current=$CURRENT desktop=$DESKTOP new=(${NEW[*]})"

if (( ${#NEW[@]} > 0 )); then
  for cgid in "${NEW[@]}"; do
    log "  registering $cgid (round-trip via desktop $DESKTOP) ..."
    space_focus "$cgid"
    sleep 0.3
    space_focus "$DESKTOP"
    sleep 0.2
    echo "$cgid" >> "$REGISTERED"
  done
  # space_focus drops global-state window levels — restore them BEFORE switching
  # back to the user's original space. Running fix_floaters while on the desktop
  # gives the CGS calls a stable context to operate in.
  log "  fix_floaters pass to restore window levels (while on desktop)"
  /Users/josh/bin/fix_floaters >> "$LOG" 2>&1
  # Return user to where they were (unless they were already on desktop)
  if [[ -n "$CURRENT" && "$CURRENT" != "$DESKTOP" ]]; then
    log "  returning user to $CURRENT"
    space_focus "$CURRENT"
  fi
fi

# Prune stale entries (registered IDs that aren't in current nav_cache)
KEPT=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  for nav in "${NAV_LIST[@]}"; do
    [[ "$id" == "$nav" ]] && KEPT+=("$id") && break
  done
done < "$REGISTERED"
printf '%s\n' "${KEPT[@]}" > "$REGISTERED.tmp" && mv "$REGISTERED.tmp" "$REGISTERED"

log "done"
