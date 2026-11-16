# app_resolve.sh — shared app-name resolver (source this, don't execute).
#
#   resolve_app "<name-or-alias>"
#
# Sets these globals from the argument:
#   OPEN_NAME : passed to `open -a` to launch the app
#   SLOT_NAME : the name the slot system knows it by (state key, as in MEM)
#   PGREP_PAT : extended-regex matched with `pgrep -x` to detect "already running"
#   SPECIAL   : optional hook ("finder" = ensure a window exists first)
#
# Known apps (declared in config/settings.json) get alias matching via the central
# settings table; unknown names are used verbatim so any app you install later
# works just by passing its real name.
source /Users/josh/Code/Scripts/config/load_settings.sh

resolve_app() {
  local arg="$1"
  # Normalise the key: lowercase, strip spaces and hyphens, so "Autodesk Fusion",
  # "autodesk-fusion" and "fusion" all collapse to comparable forms (the same
  # normalisation gen_settings.py applies to keys/aliases).
  local key
  key=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]' | tr -d ' -')

  SPECIAL=""
  if ! settings_resolve "$key"; then
    # Unknown app: use the argument verbatim for everything. Works for anything
    # you install later -- just pass its real name (no alias matching).
    OPEN_NAME="$arg"; SLOT_NAME="$arg"; PGREP_PAT="$arg"
  fi
}

# ── window helpers (used by ensure_app_window) ───────────────────────────────
# True if the app already has a real, on-screen, layer-0 window — read from
# CGWindowList (win_list), not from the Accessibility API.
#
# THIS IS THE FAST PATH AND IT EXISTS FOR A REASON. _count_windows below asks
# System Events for the AX window count, and Fusion answers "0 windows" whenever
# the Maximize Viewport add-in has made its canvas borderless: no title bar means
# macOS stops publishing it as an AX window, even though it is right there filling
# the screen. ensure_app_window read that as "running with no window", ran
# `open -a`, then polled _count_windows fifty times waiting for a window that was
# never going to be reported — 0.6s per poll, so ~26 SECONDS of dead wait before
# every single jump to Fusion, whenever Maximize Viewport happened to be on.
# CGWindowList sees the window regardless of chrome, and answers in ~25ms.
#
# An app's windows report under any of its owner spellings (Fusion's are owned by
# "Fusion", while `open -a` wants "Autodesk Fusion"), so every alias is matched.
_has_onscreen_window() {
  local wl name
  wl=$( { command -v win_list >/dev/null 2>&1 && win_list; } 2>/dev/null \
        || /Users/josh/bin/win_list 2>/dev/null ) || return 1
  [[ -z "$wl" ]] && return 1
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    printf '%s\n' "$wl" | cut -d'|' -f1 | grep -qxF "$name" && return 0
  done < <(settings_alt_names "$SLOT_NAME"; printf '%s\n' "$OPEN_NAME" "$PGREP_PAT")
  return 1
}

# Spaces mode only (config/slots_spaces): true if any of the app's spellings owns a
# non-minimized window on ANY desktop (yabai sees every desktop; CGWindowList's
# on-screen list and AX only see the active one).
_has_window_any_desktop() {
  [[ -f /Users/josh/Code/Scripts/config/slots_spaces ]] || return 1
  local n names=()
  while IFS= read -r n; do names+=("$n"); done < <(settings_alt_names "$SLOT_NAME"; printf '%s\n' "$OPEN_NAME" "$PGREP_PAT")
  # The window server, not yabai: a yabai window query stalls behind a busy Fusion.
  /Users/josh/bin/space_query has "${names[@]}" 2>/dev/null
}
# Spaces mode only: true if the app is SNAPPED in some slot — the slot engine then
# finds its window itself, on whichever desktop, so the checks below are skipped.
# Not a floater (literal "x,y,w,h" pos): its record outlives its window (Finder
# closed with ⌘W stays a member), and skipping the checks then raised nothing.
_is_slot_member() {
  [[ -f /Users/josh/Code/Scripts/config/slots_spaces ]] || return 1
  awk -F'|' -v a="$SLOT_NAME" '$2==a && $3 !~ /,/ {f=1; exit} END{exit !f}' /tmp/slot_members 2>/dev/null
}

# Echo "TOTAL VISIBLE" window counts for the app's process, or nothing if the
# count can't be read. We address the process by OPEN_NAME because that is the
# on-screen name System Events knows it by (e.g. "Autodesk Fusion").
_count_windows() {
  osascript 2>/dev/null <<OSA
tell application "System Events" to tell (first process whose name is "$OPEN_NAME")
  set t to count of windows
  set v to count of (windows whose value of attribute "AXMinimized" is false)
end tell
return (t as text) & " " & (v as text)
OSA
}

# Open BTT's real "BetterTouchTool Configuration" window and bring it to front.
#
# BTT is an LSUIElement agent app: it has no Dock icon and no menu bar when it has
# no window, so `open -a`/reopen and menu-clicking can't surface its window. Its
# `reveal_element_in_ui` AppleScript command does open the window (launching BTT
# first if needed) and activates it -- BUT only with a real trigger UUID. Called
# with an empty string it renders a broken, trigger-less shell whose body drags
# like a titlebar; that was the glitchy window. So we fetch a real UUID first.
#
# `tell application "BetterTouchTool"` auto-launches it, but get_triggers can come
# back empty during the first moments of a cold launch, so we poll briefly.
_btt_make_window() {
  local uuid _
  for _ in $(seq 1 50); do
    uuid=$(osascript -e 'tell application "BetterTouchTool" to get_triggers "{}"' 2>/dev/null \
      | grep -m1 -oE '"BTTUUID" : "[0-9A-Fa-f-]{36}"' | grep -oE '[0-9A-Fa-f-]{36}')
    [[ -n "$uuid" ]] && break
    sleep 0.1
  done
  if [[ -n "$uuid" ]]; then
    osascript -e "tell application \"BetterTouchTool\" to reveal_element_in_ui \"$uuid\"" 2>/dev/null
    # Navigate the sidebar to Keyboard Shortcuts. BTT's reveal_element_in_ui
    # lands on whatever section the chosen UUID lives in; override that by
    # clicking the "Keyboard Shortcuts" row directly.
    osascript 2>/dev/null <<'OSA'
      delay 0.4
      tell application "System Events" to tell process "BetterTouchTool"
        try
          set sp to splitter group 1 of window 1
          set theOutline to missing value
          try
            set theOutline to outline 1 of scroll area 1 of sp
          end try
          if theOutline is missing value then
            set theOutline to outline 1 of sp
          end if
          repeat with r in rows of theOutline
            try
              if value of static text 1 of r contains "Keyboard" then
                click r
                exit repeat
              end if
            end try
          end repeat
        end try
      end tell
OSA
  else
    # No triggers to anchor on -- fall back to opening the app; better than the
    # known-glitchy empty-UUID reveal.
    open_app
  fi
}

# Create one window for the app, reproducing what a Dock click does. Most apps
# honour the reopen AppleEvent that `open -a` sends when they have no window;
# Finder and BTT need their own command. The Finder/BTT helpers also launch the
# app if it isn't running yet.
_make_window() {
  case "$SPECIAL" in
    finder) osascript -e 'tell application "Finder" to make new Finder window' 2>/dev/null ;;
    btt)    _btt_make_window ;;
    # The VM, not Parallels' Control Center: opening the .pvm starts it in its
    # window (the 3ds Max slot). The process is prl_client_app (an alt_name).
    parallels) local vm; vm=$(ls -d "$HOME"/Parallels/*.pvm 2>/dev/null | head -1)
               if [[ -n "$vm" ]]; then open "$vm"; else open -a "$OPEN_NAME"; fi ;;
    *)      open_app ;;
  esac
}

# `open -a "$OPEN_NAME"`, except an app with a launcher of its own: Photoshop goes
# through remap/photoshop/cursor/open.sh so a cold launch loads the marquee-arrow
# hook (slotd's reopen_cmd mirrors this).
open_app() {
  case "$OPEN_NAME" in
    "Adobe Photoshop"*) /Users/josh/Code/Scripts/remap/photoshop/cursor/open.sh ;;
    *) open -a "$OPEN_NAME" ;;
  esac
}

# Un-minimize the app's first window (used when every window is minimized, so we
# surface an existing one instead of spawning a duplicate).
_unminimize_one() {
  osascript -e "tell application \"System Events\" to tell (first process whose name is \"$OPEN_NAME\") to set value of attribute \"AXMinimized\" of window 1 to false" 2>/dev/null
}

# A Parallels Coherence app (special "coherence": 3ds Max in the VM) runs full
# screen on its own macOS Space, outside the slots. Opening its Mac stub app
# (~/Applications (Parallels)/…/<hash>.app, found by display name) is the whole
# jump. Activation alone doesn't switch Spaces when the app is already frontmost,
# so a running app's Space is focused directly (yabai; `window --focus` can't find
# Coherence windows). Not running → opening the stub starts the VM + app.
#
# Fast path (~70 ms, was ~300): the stub path is cached (mdfind is ~80 ms), the
# Space comes from space_query (window server — not `yabai -m query --windows`,
# which a busy Fusion stalls; the biggest window on a single Space is the main
# one — a sticky popup is on all of them, dialogs open on whichever is shown), the Space is focused FIRST and the stub is opened
# in the background afterwards, only to make Max key.
open_coherence() {
  local stub sp cache="/tmp/.coherence_stub_${OPEN_NAME//[^A-Za-z0-9]/_}"
  stub=$(cat "$cache" 2>/dev/null)
  if [[ -z "$stub" || ! -e "$stub" ]]; then
    stub=$(mdfind -onlyin "$HOME/Applications (Parallels)" \
           "kMDItemDisplayName == '$OPEN_NAME'" 2>/dev/null | head -1)
    [[ -n "$stub" ]] || { open -a "$OPEN_NAME"; return; }
    printf '%s\n' "$stub" > "$cache"
  fi
  local fs
  read -r sp fs < <(/Users/josh/bin/space_query json 2>/dev/null | jq -r --arg a "$OPEN_NAME" \
       '. as $r | ([.windows[] | select(.app == $a and (.spaces | length) == 1)] | max_by(.w * .h) | .spaces[0]) as $id
        | [$r.spaces[] | select(.id == $id) | "\(.index) \(.fullscreen)"][0] // empty')
  # A relaunched Max opens un-fullscreened on whatever desktop was shown (on top of
  # a slot): max/coherence_fullscreen.sh puts it back on its own Space. Launching
  # (no window yet) → it waits for the window.
  if [[ -n "$sp" && "$fs" == 1 ]]; then
    yabai -m space --focus "$sp" 2>/dev/null
    pgrep -f "$stub/Contents/MacOS/WinAppHelper" | head -1 > /tmp/.coherence_last
    open "$stub" &
    /Users/josh/Code/Scripts/max/coherence_home.py </dev/null >/dev/null 2>&1 &
  elif [[ -n "$sp" ]]; then
    /Users/josh/Code/Scripts/max/coherence_fullscreen.sh "$OPEN_NAME" </dev/null >/dev/null 2>&1 &
  else
    open "$stub"
    /Users/josh/Code/Scripts/max/coherence_fullscreen.sh "$OPEN_NAME" 300 </dev/null >/dev/null 2>&1 &
  fi
  # Max's Browser (max_browser/) is an overlay that shows itself whenever Max is in front.
  if [[ "$OPEN_NAME" == "3ds Max"* ]] && ! pgrep -xq MaxBrowser; then
    open -g /Applications/MaxBrowser.app
  fi
}

# File Explorer (special "explorer") is Windows' Finder: a floater on the Windows
# Spaces. max/explorer/float.dylib (in Explorer's stub) puts its windows on every
# Space, over the full-screen app, and hides them except on a Windows Space — so the
# jump is: flip to a Windows Space (the one shown, else the last one flipped to, else
# any), then max/winlink's agent brings the frontmost Explorer window forward or opens
# one (~30 ms / ~1 s; prlctl exec would be ~5 s) — Parallels then makes Explorer's stub
# the key Mac app by itself. Never `open` the stub here: that activation switched
# macOS to desktop 1 (a stub window lives there). No Windows Space (Max not running): nothing to float on, so it is
# not hidden either — it shows where it is. See max/winlink/README.md.
open_explorer() {
  local stub cache="/tmp/.coherence_stub_File_Explorer" r sp last
  stub=$(cat "$cache" 2>/dev/null)
  if [[ -z "$stub" || ! -e "$stub" ]]; then
    stub=$(mdfind -onlyin "$HOME/Applications (Parallels)" "kMDItemDisplayName == 'File Explorer'" 2>/dev/null | head -1)
    [[ -n "$stub" ]] && printf '%s\n' "$stub" > "$cache"
  fi
  /Users/josh/Code/Scripts/max/explorer/install.sh >> /tmp/slots.log 2>&1   # Parallels regenerates stubs
  last=$(cat /tmp/.coherence_last 2>/dev/null)
  sp=$(/Users/josh/bin/space_query json 2>/dev/null | jq -r --argjson stubs "[$(pgrep -d, WinAppHelper)]" \
       --arg last "$last" '
    . as $r
    | [.spaces[] | select(.fullscreen == 1) | . as $s
       | ($r.windows | map(select((.spaces == [$s.id]) and (.pid as $p | $stubs | index($p))
                                  and .w * .h >= 3440 * 1440 / 4 and .app != "File Explorer"))) as $m
       | select($m | length > 0)
       | {index: $s.index, active: $s.active, last: ($m | map(.pid | tostring) | index($last) != null)}]
    | if any(.active == 1) then empty
      else ((map(select(.last)) + .)[0].index // empty) end')
  [[ -n "$sp" ]] && yabai -m space --focus "$sp" 2>/dev/null
  r=$(printf 'explorer\n' | nc -U -w 7 /tmp/winlink.sock 2>/dev/null)
  if [[ "$r" != raised* && "$r" != opened* ]]; then
    echo "[$(date '+%H:%M:%S')] [explorer] winlink: ${r:-no answer} → prlctl" >> /tmp/slots.log
    ( prlctl exec "Windows 11" --current-user explorer.exe </dev/null >/dev/null 2>&1 & )
  fi
}

# Block up to ~5s for the app to have at least one window. The CGWindowList test
# is asked first and costs ~25ms; the AX count is only consulted when it says no,
# which keeps a launching app's poll honest without paying 0.6s a turn for an app
# (Fusion) whose window AX will never admit to.
_wait_for_window() {
  local _ total visible
  for _ in $(seq 1 50); do
    _has_onscreen_window && return 0
    read -r total visible < <(_count_windows)
    [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] && return 0
    sleep 0.1
  done
  return 1
}

# ensure_app_window — guarantee the resolved app is running with at least one
# real window, exactly as if its Dock icon had been clicked. Call after
# resolve_app and before any raise/space-navigation logic. No-op when the app is
# already running with a visible window.
#
# Behaviour mirrors the old Finder-only handling, now for every app:
#   - not running                 -> launch it and surface a window
#   - running, zero windows       -> make a new window (Dock-click reopen)
#   - running, all minimized      -> un-minimize one (never a duplicate)
#   - running, a window is visible -> nothing to do
# If the window count can't be read at all we do nothing, to avoid ever spawning
# a duplicate window on a transient AppleScript error.
ensure_app_window() {
  if ! pgrep -x "$PGREP_PAT" >/dev/null 2>&1; then
    _make_window
    _wait_for_window
    return
  fi
  _is_slot_member && return             # native spaces: the slot engine fetches the window

  # Running with something on screen: nothing to do, and — crucially — no
  # AppleScript round trip. This is the case on every ordinary navigation.
  _has_onscreen_window && return
  # Native-spaces slots: a window on another desktop is off screen but fine — the
  # slot engine fetches it. `open -a` here would yank macOS over to that desktop.
  _has_window_any_desktop && return

  local total visible
  read -r total visible < <(_count_windows)
  [[ "$total" =~ ^[0-9]+$ ]] || return   # couldn't read -> leave it alone

  if [[ "$total" -eq 0 ]]; then
    _make_window
    _wait_for_window
  elif [[ "$visible" -eq 0 ]]; then
    _unminimize_one
  fi
}
