// Positions of the project's ASAF Objects, published by each ASAF Object plug-in (main thread) for
// readers on other threads (the video overlay draws from REAPER's video thread).
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace asaf {

struct ObjectMark {
  int index = 0;                   // ASAF object index (0-based)
  double azimuth = 0, elevation = 0, distance = 1;
  bool enabled = true;
  uint32_t color = 0xF09632;       // 0xRRGGBB
  std::string name;                // track name, may be empty
};

void publishMark(const void *owner, const ObjectMark &mark);
void removeMark(const void *owner);
std::vector<ObjectMark> currentMarks(); // sorted by object index

} // namespace asaf

struct clap_plugin_descriptor;
struct clap_plugin;
struct clap_host;
const clap_plugin_descriptor *videoOverlayDescriptor();
const clap_plugin *videoOverlayCreate(const clap_host *host);
