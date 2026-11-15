// Hosts one of Apple's ASAF AudioUnits and exposes its hidden controls as ordinary parameters.
// Independent of CLAP so it can be tested on its own.
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace asaf {

struct UnitDesc {
  const char *name;       // "ASAF Object"
  uint32_t subType;       // Apple's AU subtype, e.g. 'Objt'
  int numInputs;          // input busses
  int inChannels[2];
  int outChannels;
  const char *summary;
};
const std::vector<UnitDesc> &unitDescs();

struct ParamDef {
  std::string ident;      // the plug-in's own parameter id, e.g. "azimuth"
  double min = 0, max = 1, def = 0;
  bool stepped = false, readOnly = false;
  uint32_t hash = 0;      // stable id derived from ident
};

class Unit {
 public:
  explicit Unit(const UnitDesc &desc);
  ~Unit();
  Unit(const Unit &) = delete;

  // ---- main thread
  bool open(std::string *err);                 // instantiate Apple's AU and find its parameters
  bool activate(double sampleRate, uint32_t maxFrames, std::string *err);
  void deactivate();
  uint32_t latencySamples() const { return m_latency; }
  bool saveState(std::vector<uint8_t> &out);
  bool loadState(const uint8_t *data, size_t size);
  void tick();                                  // apply pending host changes, pick up plug-in-side changes
  void setFromUI(int index, double value);      // applies immediately and queues a notification to the host
  void gesture(int index, bool begin);
  void *juceProcessor() const { return m_processor; }
  // The plug-in's own display text for a parameter value (e.g. "Binaural" for a choice), or "" if it
  // can't be asked. Each call leaks one small string inside the plug-in, so callers cache the result.
  std::string pluginText(int index, double value) const;
  // Display labels for a stepped parameter's values, first entry = minimum (e.g. "Binaural", "Stereo",
  // ...). Empty for continuous parameters and for stepped ones with too many values to list. Cached.
  const std::vector<std::string> &valueLabels(int index) const;
  // Display text for a value: its label if it has one, else a number.
  std::string valueText(int index, double value) const;
  AudioUnit audioUnit() const { return m_au; }

  // ---- any thread
  const UnitDesc &desc() const { return m_desc; }
  int paramCount() const { return (int)m_defs.size(); }
  const ParamDef &paramDef(int i) const { return m_defs[i]; }
  int paramIndex(const char *ident) const;
  int paramIndexForHash(uint32_t hash) const;
  double value(int i) const { return m_values[i].load(std::memory_order_relaxed); }
  void setFromHost(int index, double value);   // queued: applied by applyFromHost() or the next tick()
  bool hasPendingHostWork() const { return m_anyDirty.load(std::memory_order_relaxed); }
  bool hasPendingToHost() const { return m_anyToHost.load(std::memory_order_relaxed); }

  // Changes the host hasn't been told about yet (made in the UI or by the plug-in). Audio thread or
  // main thread, never both at once. Calls fn(index, kind, value) with kind 0 = value, 1 = gesture
  // begin, 2 = gesture end.
  template <class F> void drainToHost(F &&fn)
  {
    if (!m_anyToHost.exchange(false, std::memory_order_acq_rel)) return;
    for (int i = 0; i < (int)m_defs.size(); i++) {
      const uint8_t f = m_toHost[i].exchange(0, std::memory_order_acq_rel);
      if (!f) continue;
      if (f & 2) fn(i, 1, 0.0);
      if (f & 1) fn(i, 0, value(i));
      if (f & 4) fn(i, 2, 0.0);
    }
  }

  // ---- audio thread
  // Apply values queued by setFromHost() now, so they take effect in the block about to be processed.
  // Automation has to be applied here rather than on the main-thread timer: an offline render runs
  // many blocks between two timer ticks.
  void applyFromHost();
  void setTransport(bool playing, bool recording) { m_playing.store(playing, std::memory_order_relaxed); m_recording.store(recording, std::memory_order_relaxed); }
  // inputs[bus][channel] / outputs[channel]; missing channels are treated as silence / discarded.
  void process(const float *const *const *inputs, const int *inputChannelCounts, float *const *outputs, int outputChannelCount, uint32_t frames);

 private:
  bool resolveParameters();
  double directGet(int i) const;
  void directSet(int i, double v);
  bool applyDirty();                                  // true if anything was pending
  void refreshFromPlugin(bool notifyHost);
  void markToHost(int i, uint8_t bits);
  static OSStatus inputCallback(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32 bus, UInt32 frames, AudioBufferList *io);
  static OSStatus transportCallback(void *ref, Boolean *isPlaying, Boolean *changed, Float64 *sampleInTimeLine, Boolean *isCycling, Float64 *cycleStart, Float64 *cycleEnd);

  const UnitDesc m_desc;
  AudioUnit m_au = nullptr;
  void *m_processor = nullptr;
  bool m_initialized = false;
  uint32_t m_maxFrames = 0, m_latency = 0;
  double m_sampleTime = 0;

  std::vector<ParamDef> m_defs;
  std::vector<void *> m_params;                       // juce::RangedAudioParameter*
  float (*m_to0to1)(void *, float) = nullptr;
  float (*m_from0to1)(void *, float) = nullptr;
  void (*m_sendChanged)(void *, float) = nullptr;
  std::unique_ptr<std::atomic<float>[]> m_values;
  std::unique_ptr<std::atomic<bool>[]> m_dirty;       // host -> plug-in, not yet applied
  std::unique_ptr<std::atomic<uint8_t>[]> m_toHost;   // plug-in/UI -> host, not yet reported
  std::atomic<bool> m_anyDirty{false}, m_anyToHost{false}, m_playing{false}, m_recording{false};
  std::atomic<bool> m_refreshSoon{false};             // applyFromHost() changed something: re-read on the next tick()
  unsigned m_tick = 0;

  std::vector<std::vector<float>> m_scratch[2];       // copies of the input busses for the AU to pull
  std::vector<float> m_discard;
  uint32_t m_scratchFrames = 0;
};

// Colour (0xRRGGBB) for an object's puck when its track has no colour of its own. The same ten colours
// are used by the panner window in reaper_asaf (PannerUI.swift).
uint32_t paletteColor(int objectIndex);

// Live units, for the control API and the exporter. Main thread.
const std::vector<Unit *> &liveUnits();

// Press ASAF Export's hidden Convert button (see shim/shim.m for the story). 1 = started; 0 = not exactly
// one ASAF Export; -1 wrong CPU architecture; -2 not the supported build; -3 unexpected internals.
int exportPressConvert();

} // namespace asaf
