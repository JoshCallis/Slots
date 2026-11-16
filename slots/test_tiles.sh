#!/bin/bash
# test_tiles.sh — the 7 slot tiles and UI Zoom's levels agree in every language.
#
#   slots/test_tiles.sh
#
# The tile rule lives three times, once per language that needs it on a hot path:
#   slotlib.sh pos_rect / tile_for_geom_now   (bash — canonical)
#   slots/zoomtiles.py                        (slotd, realize_plan, slotlib's inline Python)
#   bin/tiles.h                               (scene_restore, shadow_guard)
# and UI Zoom's 100–300 % / 5 % range in ui_zoom.sh, zoomtiles, tiles.h, the distance
# zoom helper and its Control Room page. Change one, run this.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$HERE/slotlib.sh"
PASS=0; FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/tiletest.XXXXXX"); trap 'rm -rf "$T"' EXIT

assert() { # desc, actual, expected
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "   expected: [$3]"; echo "   actual:   [$2]"; fi
}

# slotlib's own functions, lifted out (slotlib.sh runs an op when executed), with
# screen_dims answering from $SW $SH.
eval "$(sed -n '/^pos_rect() {/,/^}/p; /^tile_for_geom_now() {/,/^}/p' "$LIB")"
screen_dims() { echo "$SW $SH"; }
type pos_rect tile_for_geom_now >/dev/null 2>&1 || { echo "FAIL: couldn't lift pos_rect / tile_for_geom_now from slotlib.sh"; exit 1; }

# The C copy, as a tiny CLI: tiles SW SH → "name x y w h index-of-that-rect" per tile.
cat > "$T/tiles.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include "tiles.h"
int main(int c, char **v) {
    if (c > 1 && v[1][0] == 'z') { printf("%d %d %d\n", UIZOOM_MIN_PCT, UIZOOM_MAX_PCT, UIZOOM_STEP_PCT); return 0; }
    int sw = atoi(v[1]), sh = atoi(v[2]);
    for (int k = 0; k < TILE_N; k++) {
        CGRect r = tile_rect(k, sw, sh);
        printf("%s %.0f %.0f %.0f %.0f %d %d\n", tile_name(k), r.origin.x, r.origin.y,
               r.size.width, r.size.height, tile_index(r, sw, sh), tile_named(tile_name(k)));
    }
    return 0;
}
EOF
clang -O0 -w -I"$ROOT/bin" -framework CoreGraphics -o "$T/tiles" "$T/tiles.c" \
  || { echo "FAIL: bin/tiles.h doesn't compile"; exit 1; }

py() { /usr/bin/python3 -c "import sys; sys.path.insert(0, '$HERE'); import zoomtiles as z; $1"; }

NAMES="full left right top-left top-right bottom-left bottom-right"
echo "TEST 1: every tile, every language, several screens (odd sizes too)"
for dims in "3440 1415" "1720 707" "1728 1084" "1511 982" "1001 701"; do
  read -r SW SH <<< "$dims"
  c_out=$("$T/tiles" "$SW" "$SH")
  py_out=$(py "r = z.rects($SW, $SH)
for t in z.TILES: print(t, *r[t])")
  k=0
  for name in $NAMES; do
    b=$(pos_rect "$name")
    assert "$SW×$SH $name: python = pos_rect" "$(awk -v n="$name" '$1==n{print $2,$3,$4,$5}' <<< "$py_out")" "$b"
    assert "$SW×$SH $name: tiles.h = pos_rect" "$(awk -v n="$name" '$1==n{print $2,$3,$4,$5}' <<< "$c_out")" "$b"
    assert "$SW×$SH $name: tiles.h reads its own rect back" "$(awk -v n="$name" '$1==n{print $6,$7}' <<< "$c_out")" "$k $k"
    # shellcheck disable=SC2086
    assert "$SW×$SH $name: tile_for_geom_now reads it back" "$(tile_for_geom_now $b)" "$name"
    # shellcheck disable=SC2086
    assert "$SW×$SH $name: zoomtiles.tile_of reads it back" \
      "$(py "print(z.tile_of(tuple(int(x) for x in '$b'.split()), $SW, $SH, None, '$T'))")" "$name"
    k=$((k+1))
  done
done

echo "TEST 2: tolerance — 8px off is the tile, 9px is not"
SW=3440 SH=1415
assert "bash +8" "$(tile_for_geom_now 1728 8 1712 699)" "top-right"
assert "bash +9" "$(tile_for_geom_now 1729 9 1712 699)" ""
assert "python +8" "$(py "print(z.tile_of((1728, 8, 1712, 699), 3440, 1415, None, '$T'))")" "top-right"
assert "python +9" "$(py "print(z.tile_of((1729, 9, 1712, 699), 3440, 1415, None, '$T'))")" ""

echo "TEST 3: one UI Zoom range everywhere"
want=$("$T/tiles" z)
assert "zoomtiles" "$(py 'print(z.ZOOM_MIN_PCT, z.ZOOM_MAX_PCT, z.ZOOM_STEP_PCT)')" "$want"
uz="$(grep -oE '^\(\( pct < [0-9]+ \)\)' "$ROOT/ui_zoom.sh" | grep -oE '[0-9]+') \
$(grep -oE '^\(\( pct > [0-9]+ \)\)' "$ROOT/ui_zoom.sh" | grep -oE '[0-9]+') \
$(sed -nE 's/^STEP=([0-9]+).*/\1/p' "$ROOT/ui_zoom.sh")"
assert "ui_zoom.sh clamp + STEP" "$uz" "$want"
assert "remap/distancezoom.py" \
  "$(sed -nE 's/^MIN_PCT, MAX_PCT, STEP = ([0-9]+), ([0-9]+), ([0-9]+).*/\1 \2 \3/p' "$ROOT/remap/distancezoom.py")" "$want"
assert "remap/distance_zoom.js" \
  "$(sed -nE 's/.*const MIN_PCT = ([0-9]+), MAX_PCT = ([0-9]+), STEP = ([0-9]+).*/\1 \2 \3/p' "$ROOT/remap/distance_zoom.js")" "$want"
assert "bin/distance_zoom.m MAX_PCT" \
  "$(sed -nE 's/^static const int MAX_PCT = ([0-9]+);.*/\1/p' "$ROOT/bin/distance_zoom.m")" "$(cut -d' ' -f2 <<< "$want")"

echo "──────────────────────────────────────────"
echo "PASS $PASS  FAIL $FAIL"
(( FAIL == 0 ))
