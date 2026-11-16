# jump_stamp.sh — sourced by the jump entry points (goto_app, focus, toggle_app,
# simple_nav, slot_activate). Stamps this key press as THE latest jump:
#   SLOT_GEN       a token, also written to /tmp/slot_jump_gen — a newer press
#                  overwrites the file, so an older jump still waiting sees it lost;
#   SLOT_DEADLINE  epoch second (now + 3, i.e. 2–3 s away) after which it is dropped.
# slotc forwards SLOT_GEN to slotd, slotlib's slot_lock checks both (jump_dropped).
# A nested entry point (toggle_app → goto_app, focus → slot_activate) keeps its
# caller's stamp: it is the same press.
if [[ -z "$SLOT_GEN" ]]; then
  export SLOT_GEN="$$.$RANDOM" SLOT_DEADLINE=$(( $(/bin/date +%s) + 3 ))
  echo "$SLOT_GEN" > /tmp/slot_jump_gen
fi
