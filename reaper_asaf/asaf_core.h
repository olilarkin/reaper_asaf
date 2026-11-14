// Core of the ASAF exporter, independent of REAPER so it can be tested from a harness.
#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include <cstdint>

namespace asaf {

// The shim's in-process control API (see shim/shim.m). All calls must be made on the main thread.
struct Shim {
  int (*Count)(uint32_t subType) = nullptr;
  int (*SetParam)(uint32_t subType, const char *paramID, float value, int momentary) = nullptr;
  int (*GetParam)(uint32_t subType, const char *paramID, float *out) = nullptr;
  int (*ExportPressConvert)(void) = nullptr; // shim API v2+; may be null
  bool load();            // false if ASAFShim.component isn't installed / is too old
  bool ok() const { return Count && SetParam; }
};
Shim &shim();

enum : uint32_t { kExport = 'Expt', kObject = 'Objt' };

// Writes the intermediate "bounce" file ASAF Export converts: interleaved 32-bit float WAV
// (object/scene/bed audio channels followed by Export's 8 metadata channels). RF64 if it passes 4 GB.
class BounceWriter {
 public:
  bool open(const char *path, int nch, int srate);
  void write(double **samples, int len, int nch, int offset, int spacing);
  bool close();
  bool isOpen() const { return m_fp != nullptr; }
  int64_t frames() const { return m_frames; }
  int64_t bytes() const { return m_dataBytes + 128; }
  ~BounceWriter() { close(); }
 private:
  FILE *m_fp = nullptr;
  int m_nch = 0, m_srate = 0;
  int64_t m_frames = 0, m_dataBytes = 0;
  std::vector<float> m_buf;
};

// True if the WAV at `path` carries ASAF metadata (an AIAM chunk). outChannels gets its channel count.
bool isASAFFile(const char *path, int *outChannels);

// Arm / disarm metadata output on the project's ASAF Export unit. Main thread.
bool armExport(bool armed, std::string *err);

// Convert a finished bounce file to an ASAF BWF in place, by driving ASAF Export. Main thread.
bool convertBounceToASAF(const char *path, std::string *err);

// As above, and also encode an APAC .mp4 next to it (same name, .mp4 extension) with ASAF Export's
// built-in encoder. Blocks until both are done. Returns false with *err set if the ASAF BWF could not
// be made. If the BWF was made but APAC could not be, returns true and sets *apacErr. Main thread.
bool convertBounceToASAFAndAPAC(const char *path, std::string *err, std::string *apacErr);

// Path of the APAC file written for a given ASAF BWF path.
std::string apacPathFor(const char *path);

} // namespace asaf
