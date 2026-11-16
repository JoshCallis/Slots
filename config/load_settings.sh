# load_settings.sh — source this (don't execute) to get the central settings.
#
# Compiles config/settings.json → config/settings.cache.sh (via gen_settings.py)
# whenever the JSON or the generator is newer, then sources the cache. Costs two
# stats on the hot path; edits to settings.json are live on the next slot op.
#
# Failure ladder (a broken settings.json can never brick window management):
#   1. generation fails → keep and source the PREVIOUS cache (last-good), log it
#   2. no cache at all  → emergency built-in defaults below (match shipped JSON)
# Consumers get, unconditionally: APPS, PLACE_LAYOUTS, CAD_APPS, CAD_MATCH_NAMES,
# settings_normalize/open_name/alt_names/resolve. See gen_settings.py header.

_SETTINGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SETTINGS_JSON="$_SETTINGS_DIR/settings.json"
_SETTINGS_CACHE="$_SETTINGS_DIR/settings.cache.sh"

if [[ -f "$_SETTINGS_JSON" ]] && \
   { [[ ! -f "$_SETTINGS_CACHE" ]] \
     || [[ "$_SETTINGS_JSON" -nt "$_SETTINGS_CACHE" ]] \
     || [[ "$_SETTINGS_DIR/gen_settings.py" -nt "$_SETTINGS_CACHE" ]]; }; then
  if /usr/bin/python3 "$_SETTINGS_DIR/gen_settings.py" "$_SETTINGS_JSON" \
       > "$_SETTINGS_CACHE.tmp.$$" 2>/dev/null; then
    mv "$_SETTINGS_CACHE.tmp.$$" "$_SETTINGS_CACHE"
  else
    rm -f "$_SETTINGS_CACHE.tmp.$$"
    echo "[$(date '+%H:%M:%S')] [settings] settings.json failed to compile — keeping last-good cache" \
      >> /tmp/slots.log 2>/dev/null
  fi
fi

SLOTS_SETTINGS_OK=""
[[ -f "$_SETTINGS_CACHE" ]] && source "$_SETTINGS_CACHE"

if [[ -z "$SLOTS_SETTINGS_OK" ]]; then
  # Emergency defaults — only reachable with no cache AND an uncompilable JSON.
  # Keep in sync with the shipped settings.json (values, not exhaustiveness).
  APPS=(Podcasts Notes SketchUp Fusion Claude OrcaSlicer Safari "Google Chrome")
  PLACE_LAYOUTS=(
    "Safari|Safari:right;Claude:left"
    "Google Chrome|Google Chrome:right;Claude:left"
  )
  CAD_APPS="SketchUp Fusion"
  CAD_MATCH_NAMES="SketchUp
Fusion
Autodesk Fusion"
  settings_normalize() {
    case "$1" in
      "Autodesk Fusion") echo "Fusion" ;;
      "Amazon Kindle")   echo "Kindle" ;;
      *)                 echo "$1" ;;
    esac
  }
  settings_open_name() {
    case "$1" in
      "Fusion") echo "Autodesk Fusion" ;;
      *)        echo "$1" ;;
    esac
  }
  settings_alt_names() {
    case "$1" in
      "Fusion") printf '%s\n' "Fusion" "Autodesk Fusion" ;;
      "Kindle") printf '%s\n' "Kindle" "Amazon Kindle" ;;
      *)        printf '%s\n' "$1" ;;
    esac
  }
  settings_titlebar() { echo 0; }
  settings_resolve() { return 1; }
  SLOTS_SETTINGS_OK=emergency
  echo "[$(date '+%H:%M:%S')] [settings] using EMERGENCY built-in defaults" \
    >> /tmp/slots.log 2>/dev/null
fi
