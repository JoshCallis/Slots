/*
 * tiles.h — the 7 slot tiles and UI Zoom's levels, the one C copy (scene_restore.m,
 * shadow_guard.m). The canonical rule is slotlib.sh pos_rect; slots/zoomtiles.py is
 * the Python copy. slots/test_tiles.sh checks the three agree — run it after an edit.
 *
 * Tile k is TILE_NAMES order: full, left, right, top-left, top-right, bottom-left,
 * bottom-right. Left-edge tiles are 1px narrower (hw - 1): a clean seam between a
 * left- and a right-snapped window.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <string.h>
#include <math.h>

#define TILE_N    7
#define TILE_TOL  8      // px: a window within this of a tile IS that tile

// UI Zoom (ui_zoom.sh): 100–300 % in 5 % steps.
#define UIZOOM_MIN_PCT   100
#define UIZOOM_MAX_PCT   300
#define UIZOOM_STEP_PCT  5

static inline const char *tile_name(int k) {
    static const char *names[TILE_N] = {
        "full", "left", "right", "top-left", "top-right", "bottom-left", "bottom-right"
    };
    return k >= 0 && k < TILE_N ? names[k] : "";
}

static inline int tile_named(const char *name) {    // → k, or -1
    for (int k = 0; k < TILE_N; k++) if (!strcmp(name, tile_name(k))) return k;
    return -1;
}

// Tile k of an SW×SH screen without rounding (a glide's in-between frames).
static inline CGRect tile_rect_d(int k, double sw, double sh) {
    double hw = sw / 2, hh = sh / 2, lw = hw - 1;
    double t[TILE_N][4] = {
        {0, 0, sw, sh}, {0, 0, lw, sh}, {hw, 0, hw, sh},
        {0, 0, lw, hh}, {hw, 0, hw, hh}, {0, hh, lw, hh}, {hw, hh, hw, hh}
    };
    if (k < 0 || k >= TILE_N) k = 0;
    return CGRectMake(t[k][0], t[k][1], t[k][2], t[k][3]);
}

// Tile k of an SW×SH screen, in whole pixels (integer halves, as pos_rect).
static inline CGRect tile_rect(int k, int sw, int sh) {
    int hw = sw / 2, hh = sh / 2, lw = hw - 1;
    int t[TILE_N][4] = {
        {0, 0, sw, sh}, {0, 0, lw, sh}, {hw, 0, hw, sh},
        {0, 0, lw, hh}, {hw, 0, hw, hh}, {0, hh, lw, hh}, {hw, hh, hw, hh}
    };
    if (k < 0 || k >= TILE_N) k = 0;
    return CGRectMake(t[k][0], t[k][1], t[k][2], t[k][3]);
}

static inline int tile_near(CGRect f, CGRect r) {
    return fabs(f.origin.x - r.origin.x) <= TILE_TOL && fabs(f.origin.y - r.origin.y) <= TILE_TOL &&
           fabs(f.size.width - r.size.width) <= TILE_TOL && fabs(f.size.height - r.size.height) <= TILE_TOL;
}

// Which tile of an SW×SH screen frame F sits on → k, or -1.
static inline int tile_index(CGRect f, int sw, int sh) {
    for (int k = 0; k < TILE_N; k++) if (tile_near(f, tile_rect(k, sw, sh))) return k;
    return -1;
}
