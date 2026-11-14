#include "embed.h"
#include <cmath>
#include <cstdio>
#include <algorithm>

#define _LICE_NO_SYSBITMAPS_
#include "lice/lice.h"
#include "reaper_plugin_fx_embed.h"
#undef min // SWELL defines these as macros
#undef max

namespace asaf {

static const double kPi = 3.14159265358979323846;

static bool resolve(Unit &u, EmbedState &s)
{
  if (s.az == -2) { s.az = u.paramIndex("azimuth"); s.el = u.paramIndex("elevation"); s.dist = u.paramIndex("r"); }
  return s.az >= 0 && s.el >= 0 && s.dist >= 0;
}

// Geometry shared by drawing and mouse handling: a square stage, centred (or left-aligned when the
// panel is wide enough to show read-outs beside it).
struct Layout {
  float scale, cx, cy, reach;   // reach = stage radius in pixels
  double metres;                // metres from centre to the stage edge
  bool readouts; int textX;
};

static Layout layout(const REAPER_FXEMBED_DrawInfo *info, double horizDist)
{
  Layout l;
  // dpi is 24.8 fixed point and already includes Retina doubling when REAPER reports it.
  l.scale = info->dpi > 0 ? info->dpi / 256.0f : ((info->flags & REAPER_FXEMBED_DRAWINFO_FLAG_IS_RETINA) ? 2.0f : 1.0f);
  const int w = info->width, h = info->height, side = std::min(w, h);
  const float pad = 4 * l.scale;
  l.readouts = w >= h + (int)(52 * l.scale);
  l.cx = l.readouts ? side / 2.0f : w / 2.0f;
  l.cy = h / 2.0f;
  l.reach = std::max(4.0f, side / 2.0f - pad);
  l.textX = side + (int)(2 * l.scale);
  l.metres = std::max(2.0, std::ceil(horizDist - 1e-6)); // zoom out to keep the object on stage
  return l;
}

static void paint(Unit &u, EmbedState &s, uint32_t color, LICE_IBitmap *bm, const REAPER_FXEMBED_DrawInfo *info)
{
  const double az = u.value(s.az), el = u.value(s.el), dist = u.value(s.dist);
  const double horiz = dist * std::cos(el * kPi / 180);
  const Layout l = layout(info, horiz);
  const int w = info->width, h = info->height;

  LICE_FillRect(bm, 0, 0, w, h, LICE_RGBA(28, 28, 30, 255), 1.0f, LICE_BLIT_MODE_COPY);

  const LICE_pixel grid = LICE_RGBA(200, 200, 205, 255);
  const double step = l.metres <= 4 ? 1.0 : 2.0;
  for (double r = step; r <= l.metres + 1e-9; r += step)
    LICE_Circle(bm, l.cx, l.cy, (float)(r / l.metres * l.reach), grid, r >= l.metres - 1e-9 ? 0.45f : 0.22f, LICE_BLIT_MODE_COPY, true);
  LICE_Line(bm, (int)(l.cx - l.reach), (int)l.cy, (int)(l.cx + l.reach), (int)l.cy, grid, 0.15f, LICE_BLIT_MODE_COPY, true);
  LICE_Line(bm, (int)l.cx, (int)(l.cy - l.reach), (int)l.cx, (int)(l.cy + l.reach), grid, 0.15f, LICE_BLIT_MODE_COPY, true);

  // listener, with a nose pointing to the front (up)
  const float head = 2.6f * l.scale;
  LICE_FillTriangle(bm, (int)(l.cx - head), (int)(l.cy - head * 0.4f), (int)(l.cx + head), (int)(l.cy - head * 0.4f), (int)l.cx, (int)(l.cy - head * 2.1f),
                    LICE_RGBA(170, 170, 175, 255), 0.9f, LICE_BLIT_MODE_COPY);
  LICE_FillCircle(bm, l.cx, l.cy, head, LICE_RGBA(170, 170, 175, 255), 0.9f, LICE_BLIT_MODE_COPY, true);

  // the object: positive azimuth is to the listener's left; higher objects are drawn larger
  const float px = l.cx + (float)(-std::sin(az * kPi / 180) * horiz / l.metres * l.reach);
  const float py = l.cy - (float)(std::cos(az * kPi / 180) * horiz / l.metres * l.reach);
  const float pr = (float)(4.2 + 1.6 * el / 90.0) * l.scale;
  LICE_FillCircle(bm, px, py, pr, LICE_RGBA((color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff, 255), 1.0f, LICE_BLIT_MODE_COPY, true);
  LICE_Circle(bm, px, py, pr, s.dragging ? LICE_RGBA(255, 255, 255, 255) : LICE_RGBA(20, 20, 20, 255), s.dragging ? 1.0f : 0.7f, LICE_BLIT_MODE_COPY, true);

  if (l.readouts && h >= 30) {
    char line[3][32];
    snprintf(line[0], sizeof line[0], "Az %d", (int)std::lround(az));
    snprintf(line[1], sizeof line[1], "El %d", (int)std::lround(el));
    snprintf(line[2], sizeof line[2], "%.2fm", dist);
    const int lh = 10, top = std::max(1, (h - 3 * lh) / 2);
    for (int i = 0; i < 3; i++) LICE_DrawText(bm, l.textX, top + i * lh, line[i], LICE_RGBA(215, 215, 220, 255), 1.0f, LICE_BLIT_MODE_COPY);
  }

  s.lastAz = (float)az; s.lastEl = (float)el; s.lastDist = (float)dist; s.lastW = w; s.lastH = h; s.lastColor = color; s.painted = true;
}

static void moveTo(Unit &u, EmbedState &s, const REAPER_FXEMBED_DrawInfo *info)
{
  const double el = u.value(s.el);
  // Keep the zoom the stage had when the drag started from jumping about: use the current distance.
  const Layout l = layout(info, u.value(s.dist) * std::cos(el * kPi / 180));
  const double x = (info->mouse_x - l.cx) / l.reach * l.metres, y = (l.cy - info->mouse_y) / l.reach * l.metres;
  const double h = std::hypot(x, y);
  if (h > 1e-6) u.setFromUI(s.az, std::atan2(-x, y) * 180 / kPi);
  u.setFromUI(s.dist, std::min(10.0, h / std::max(0.05, std::cos(el * kPi / 180))));
}

intptr_t embedMessage(Unit &u, EmbedState &s, uint32_t color, int msg, void *parm2, void *parm3)
{
  if (!resolve(u, s)) return 0;
  const REAPER_FXEMBED_DrawInfo *info = (const REAPER_FXEMBED_DrawInfo *)parm3;
  switch (msg) {
    case REAPER_FXEMBED_WM_IS_SUPPORTED:
      return 1;

    case REAPER_FXEMBED_WM_GETMINMAXINFO: {
      REAPER_FXEMBED_SizeHints *hints = (REAPER_FXEMBED_SizeHints *)parm3;
      if (!hints) return 0;
      hints->preferred_aspect = 65536; // square
      hints->minimum_aspect = 65536 / 3;
      hints->min_width = 36; hints->min_height = 36;
      return 1;
    }

    case REAPER_FXEMBED_WM_PAINT: {
      LICE_IBitmap *bm = (LICE_IBitmap *)parm2; // REAPER_FXEMBED_IBitmap is an alias of LICE_IBitmap
      if (!bm || !info || info->width < 8 || info->height < 8) return 0;
      if ((info->flags & REAPER_FXEMBED_DRAWINFO_FLAG_PAINT_OPTIONAL) && s.painted && s.lastW == info->width && s.lastH == info->height && s.lastColor == color &&
          s.lastAz == (float)u.value(s.az) && s.lastEl == (float)u.value(s.el) && s.lastDist == (float)u.value(s.dist))
        return 0;
      paint(u, s, color, bm, info);
      return 1;
    }

    case REAPER_FXEMBED_WM_LBUTTONDOWN:
      if (!info) return 0;
      s.dragging = true;
      u.gesture(s.az, true); u.gesture(s.dist, true);
      moveTo(u, s, info);
      s.painted = false;
      return REAPER_FXEMBED_RETNOTIFY_INVALIDATE;

    case REAPER_FXEMBED_WM_MOUSEMOVE:
      if (!info || !s.dragging || !(info->flags & REAPER_FXEMBED_DRAWINFO_FLAG_LBUTTON_CAPTURED)) return 0;
      moveTo(u, s, info);
      return REAPER_FXEMBED_RETNOTIFY_INVALIDATE;

    case REAPER_FXEMBED_WM_LBUTTONUP:
      if (!s.dragging) return 0;
      s.dragging = false;
      u.gesture(s.az, false); u.gesture(s.dist, false);
      s.painted = false;
      return REAPER_FXEMBED_RETNOTIFY_INVALIDATE;

    case REAPER_FXEMBED_WM_LBUTTONDBLCLK: // back to straight ahead, 1 m, ear height
      u.gesture(s.az, true); u.gesture(s.el, true); u.gesture(s.dist, true);
      u.setFromUI(s.az, 0); u.setFromUI(s.el, 0); u.setFromUI(s.dist, 1);
      u.gesture(s.az, false); u.gesture(s.el, false); u.gesture(s.dist, false);
      s.dragging = false; s.painted = false;
      return REAPER_FXEMBED_RETNOTIFY_INVALIDATE;

    case REAPER_FXEMBED_WM_MOUSEWHEEL: { // elevation, 5 degrees a notch
      if (!info || !info->mousewheel_amt) return 0;
      u.gesture(s.el, true);
      u.setFromUI(s.el, u.value(s.el) + 5.0 * info->mousewheel_amt / 120.0);
      u.gesture(s.el, false);
      return REAPER_FXEMBED_RETNOTIFY_INVALIDATE;
    }
  }
  return 0;
}

} // namespace asaf
