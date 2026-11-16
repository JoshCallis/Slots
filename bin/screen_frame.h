/*
 * screen_frame.h — the frame's hole, shared by screen_frame.m (always-on edge) and
 * scene_restore.m (the copy it draws in step with a stand-in zoom glide).
 *
 * Seams: where two windows meet at the top / bottom edge of the screen (left + right
 * tiles, or the quadrants), the black also rounds their facing corners — the same
 * contour as the screen's corners — so it rises (falls) between them like a little
 * mountain. screen_frame finds them and writes SEAM_FILE: "tl tr bl br", each a window
 * edge as a fraction of the visible width (top's left window's right edge, the right
 * window's left edge, then the bottom's); -1 = no seam on that edge.
 */
#include <CoreGraphics/CoreGraphics.h>

#define SEAM_FILE "/tmp/.screen_seams"

// One edge's notch, walked counter-clockwise (y-up). top: from x1 side to x0 side.
static void sf_notch(CGMutablePathRef p, double L, double R, double y, double r, int top) {
    if (top) {
        CGPathAddLineToPoint(p, NULL, R + r, y);
        CGPathAddArc(p, NULL, R + r, y - r, r, M_PI_2, M_PI, false);      // right window's top-left
        CGPathAddLineToPoint(p, NULL, L, y - r);
        CGPathAddArc(p, NULL, L - r, y - r, r, 0, M_PI_2, false);         // left window's top-right
    } else {
        CGPathAddLineToPoint(p, NULL, L - r, y);
        CGPathAddArc(p, NULL, L - r, y + r, r, -M_PI_2, 0, false);        // left window's bottom-right
        CGPathAddLineToPoint(p, NULL, R, y + r);
        CGPathAddArc(p, NULL, R + r, y + r, r, M_PI, 3 * M_PI_2, false);  // right window's bottom-left
    }
}

// Adds the hole (to be filled even-odd against the screen rect): v's rounded rect,
// radius r, notched at seams. seam = {tl, tr, bl, br} in points (x), or NULL / <0 = none.
//
// The notch is sized for what it covers, in unzoomed points — NOT ÷ zoom like r: the
// windows (and borders' line round them) grow with the screen zoom, so it grows too.
// SF_SEAM_R: Chrome's corner reaches its edge ~20 pt down (measured 2026-10-20), and
// JankyBorders' 2 pt line straddles the window edge (1 pt inside), turning its corner
// ~12 pt down — so the notch is rounder than both, covers that turn, and only meets the
// windows' edges further down: it tapers to a point `tip` wide (callers: one physical
// pixel at the current zoom, 1/scale/z pt), centred on the midline, which emerges from
// under it. The radius grows with the zoom; the point stays one pixel. (Never widen the
// point to cover more: a 2 pt pad each side left a flat 5 pt tip, a visible step onto
// the line — 2026-10-20.)
#define SF_SEAM_R   24.0
static void sf_hole(CGMutablePathRef p, CGRect v, double r, double tip, const double *seam) {
    double x0 = CGRectGetMinX(v), x1 = CGRectGetMaxX(v), y0 = CGRectGetMinY(v), y1 = CGRectGetMaxY(v);
    double sr = SF_SEAM_R;
    #define SF_OK(L, R) ((L) >= 0 && (R) >= (L) && (L) - sr >= x0 + r && (R) + sr <= x1 - r)
    #define SF_MID(L, R) ((L) + (R)) / 2 - tip / 2, ((L) + (R)) / 2 + tip / 2
    CGPathMoveToPoint(p, NULL, x0 + r, y0);
    if (seam && SF_OK(seam[2], seam[3])) sf_notch(p, SF_MID(seam[2], seam[3]), y0, sr, 0);
    CGPathAddArc(p, NULL, x1 - r, y0 + r, r, -M_PI_2, 0, false);
    CGPathAddArc(p, NULL, x1 - r, y1 - r, r, 0, M_PI_2, false);
    if (seam && SF_OK(seam[0], seam[1])) sf_notch(p, SF_MID(seam[0], seam[1]), y1, sr, 1);
    #undef SF_MID
    CGPathAddArc(p, NULL, x0 + r, y1 - r, r, M_PI_2, M_PI, false);
    CGPathAddArc(p, NULL, x0 + r, y0 + r, r, M_PI, 3 * M_PI_2, false);
    CGPathCloseSubpath(p);
    #undef SF_OK
}
