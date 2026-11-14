// REAPER's embedded UI (the small panel in the TCP / MCP) for ASAF Object, drawn with WDL's LICE.
#pragma once
#include <cstdint>
#include "unit.h"

namespace asaf {

struct EmbedState {
  int az = -2, el = -1, dist = -1;       // parameter indices (-2 = not looked up yet)
  bool dragging = false;
  bool painted = false;
  float lastAz = 0, lastEl = 0, lastDist = 0;
  int lastW = 0, lastH = 0;
  uint32_t lastColor = 0;
};

// Handles one REAPER_FXEMBED_WM_* message. puckColor is 0xRRGGBB. Main thread.
intptr_t embedMessage(Unit &unit, EmbedState &state, uint32_t puckColor, int msg, void *parm2, void *parm3);

} // namespace asaf
