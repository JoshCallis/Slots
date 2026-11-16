#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Entries here must match the bundle name that `open -a` expects (the .app
# name on disk). For apps whose process/window owner name differs (reported
# by spaces_info), add a mapping in normalize_app below.
ORDERED=(
  "Podcasts"
  "Notes"
  "SketchUp"
  "Autodesk Fusion"
  "Claude"
  "OrcaSlicer"
  "Google Chrome"
  "Amazon Kindle"
)

# CGS-based, no yabai needed
SI=$(spaces_info)

# Map ORDERED entry (the open-a-able bundle name) to the process/window owner
# name that spaces_info reports. Add new entries here whenever an app's bundle
# name differs from its executable/process name (open -a uses bundle name;
# spaces_info uses owner name).
normalize_app() {
  case "$1" in
    "Autodesk Fusion") echo "Fusion" ;;
    "Amazon Kindle")   echo "Kindle" ;;
    *) echo "$1" ;;
  esac
}

get_cgid_for_app() {
  local target
  target=$(normalize_app "$1")
  echo "$SI" | awk -v app="$target" '
    /^APP / {
      cgid = $2
      sub(/^APP [^ ]+ /, "")
      if ($0 == app) { print cgid; exit }
    }
  '
}

# Returns "true" if the space with this CGS ID is native fullscreen (type 4)
is_fullscreen() {
  local cgid="$1"
  echo "$SI" | awk -v id="$cgid" '
    /^SPACE / && $2 == id { print ($3 == 4 ? "true" : "false"); exit }
  '
}

NAV_LIST=()
SPACE_APP_MAP=()

for entry in "${ORDERED[@]}"; do
  cgid=$(get_cgid_for_app "$entry")
  [[ -z "$cgid" || "$cgid" == "null" ]] && continue
  SPACE_APP_MAP+=("${cgid}=${entry}")
  [[ "$(is_fullscreen "$cgid")" == "true" ]] && NAV_LIST+=("$cgid")
done

# ── Orphan recovery ───────────────────────────────────────────────────────────
# Some apps (e.g. Fusion opening a new file) report their window on the desktop
# while their actual fullscreen space is "orphaned" (type 4, no app entry).
# Pair unplaced running ORDERED apps with orphaned spaces.
ORPHANS=()
while IFS= read -r s; do [[ -n "$s" ]] && ORPHANS+=("$s"); done < <(
  echo "$SI" | awk '
    /^SPACE / && $3 == 4 { spaces[$2] = 1 }
    /^APP /               { delete spaces[$2] }
    END                   { for (s in spaces) print s }
  '
)

oi=0
for entry in "${ORDERED[@]}"; do
  [[ $oi -ge ${#ORPHANS[@]} ]] && break
  already=false
  for mapping in "${SPACE_APP_MAP[@]}"; do
    [[ "${mapping#*=}" != "$entry" ]] && continue
    placed="${mapping%%=*}"
    for nav in "${NAV_LIST[@]}"; do
      [[ "$nav" == "$placed" ]] && already=true && break 2
    done
  done
  $already && continue
  [[ -z "$(get_cgid_for_app "$entry")" ]] && continue  # not running
  orphan="${ORPHANS[$oi]}"
  NAV_LIST+=("$orphan")
  SPACE_APP_MAP+=("${orphan}=${entry}")
  oi=$(( oi + 1 ))
done

# ── Re-sort NAV_LIST to match ORDERED sequence ────────────────────────────────
SORTED=()
for entry in "${ORDERED[@]}"; do
  for mapping in "${SPACE_APP_MAP[@]}"; do
    [[ "${mapping#*=}" != "$entry" ]] && continue
    cgid="${mapping%%=*}"
    for nav in "${NAV_LIST[@]}"; do
      [[ "$nav" == "$cgid" ]] && SORTED+=("$cgid") && break 2
    done
  done
done
NAV_LIST=("${SORTED[@]}")

printf '%s\n' "${NAV_LIST[@]}"  > /tmp/yabai_nav_cache.tmp   && mv /tmp/yabai_nav_cache.tmp   /tmp/yabai_nav_cache
printf '%s\n' "${SPACE_APP_MAP[@]}" > /tmp/yabai_space_app_map.tmp && mv /tmp/yabai_space_app_map.tmp /tmp/yabai_space_app_map


# ── Stale-ID cleanup ─────────────────────────────────────────────────────────
# Keep only IDs in /tmp/yabai_initialized_spaces that still exist as
# fullscreen spaces in the rebuilt NAV_LIST. macOS reuses CGS IDs as apps
# open/close, so stale IDs cause future swipes to wrongly treat new spaces
# as already-initialized (skipping the one-time space_focus registration).
#
# Initialization itself is now lazy: yabai_nav.sh's fallback path calls
# space_focus + fix_floaters the first time you swipe to an unknown space.
INITIALIZED=/tmp/yabai_initialized_spaces
if [[ -f "$INITIALIZED" ]]; then
  KEPT=()
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    for nav in "${NAV_LIST[@]}"; do
      [[ "$id" == "$nav" ]] && KEPT+=("$id") && break
    done
  done < "$INITIALIZED"
  printf '%s\n' "${KEPT[@]}" > "$INITIALIZED.tmp" && mv "$INITIALIZED.tmp" "$INITIALIZED"
fi
