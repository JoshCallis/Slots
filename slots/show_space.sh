#!/bin/bash
# show_space.sh — display current slot contents in a dialog (for BTT)
export PATH="/opt/homebrew/bin:/usr/local/bin:/Users/josh/bin:$PATH"
[[ -f /Users/josh/Code/Scripts/config/slots_off ]] && exit 0   # slots switched off (slots/power.sh)

SDIR="${SLOT_STATE_DIR:-/tmp}"
MEM="$SDIR/slot_members"
CUR="$SDIR/current_slot"
SEQ="$SDIR/slot_seq"
TMP="/tmp/show_space_msg.txt"

cur=$(cat "$CUR" 2>/dev/null)

if [[ -z "$cur" || ! -f "$MEM" ]]; then
  echo "Slot system not initialized." > "$TMP"
else
  # Find position in sequence
  seq_count=0; found_idx=0
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    seq_count=$((seq_count + 1))
    [[ "$s" == "$cur" ]] && found_idx=$seq_count
  done < "$SEQ" 2>/dev/null

  # All members of current slot, z ascending (last line = frontmost)
  members=$(awk -F'|' -v s="$cur" '$1==s{print $2"|"$3"|"$4}' "$MEM" 2>/dev/null \
            | sort -t'|' -k3,3n)

  {
    echo "Space $found_idx of $seq_count"
    echo ""

    # Spatial order: full first, then halves, then quarters
    for pos in full left right top-left top-right bottom-left bottom-right; do
      # apps at this position, z ascending (last = on top)
      apps=$(printf '%s\n' "$members" | awk -F'|' -v p="$pos" '$2==p{print $1}')
      [[ -z "$apps" ]] && continue

      count=$(printf '%s\n' "$apps" | grep -c .)
      top=$(printf '%s\n' "$apps" | tail -1)

      case "$pos" in
        full)         label="⬛  full       " ;;
        left)         label="◀  left       " ;;
        right)        label="▶  right      " ;;
        top-left)     label="↖  top-left   " ;;
        top-right)    label="↗  top-right  " ;;
        bottom-left)  label="↙  bot-left   " ;;
        bottom-right) label="↘  bot-right  " ;;
      esac

      if [[ $count -eq 1 ]]; then
        echo "  $label  $top"
      else
        # show frontmost; list others indented below as (behind)
        echo "  $label  $top"
        behind=$(printf '%s\n' "$apps" | head -$((count - 1)) | tr '\n' ',' | sed 's/,$//')
        echo "                        ↳ behind: $behind"
      fi
    done

    if [[ -z "$members" ]]; then
      echo "  (empty slot)"
    fi
  } > "$TMP"
fi

osascript << 'APPLESCRIPT'
set msg to (do shell script "cat /tmp/show_space_msg.txt")
display dialog msg buttons {"OK"} default button "OK" with title "Current Space" with icon note
APPLESCRIPT
