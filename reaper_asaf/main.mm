// reaper_asaf — ASAF support for REAPER, built on Apple's ASAF AudioUnits (via ASAFShim.component).
//
//  * Render format "ASAF (Apple Spatial Audio Format)": writes the bounce file ASAF Export expects and
//    has ASAF Export convert it to an ASAF BWF when the render finishes.
//  * Action "ASAF: Set up session": creates object tracks, a binaural monitor bus and the export bus.
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <algorithm>
#include <unistd.h>

#define REAPERAPI_IMPLEMENT
#include "reaper_api.h"
#include "swell/swell-dlggen.h"

#include "asaf_core.h"

#define SINK_FOURCC REAPER_FOURCC('a','s','a','f')
static const int kMetadataChannels = 8;   // ASAF Export's output bus
static const int kRenderBlockSize = 1024; // ASAF Export only emits metadata at this block size
static const int kMaxObjects = 128 - kMetadataChannels; // one REAPER track = 128 channels

// Set ASAF_DEBUG=1 in REAPER's environment to trace the exporter to stderr.
#define DBG(...) do { if (getenv("ASAF_DEBUG")) NSLog(@"reaper_asaf: " __VA_ARGS__); } while (0)

static void onMain(void (^block)(void))
{
  if ([NSThread isMainThread]) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}

// Set ASAF_NO_DIALOGS=1 to log problems to stderr instead of showing them (for unattended test runs).
static void report(const std::string &msg)
{
  if (getenv("ASAF_NO_DIALOGS")) { NSLog(@"reaper_asaf: %s", msg.c_str()); return; }
  onMain(^{ if (ShowMessageBox) ShowMessageBox(msg.c_str(), "ASAF", 0); });
}

// Set ASAF_KEEP_BOUNCE=1 to keep a copy of each render as it was before conversion, next to the output
// as "<name>.bounce.wav" (see tools/export_test).
static void keepBounce(const std::string &fn)
{
  if (!getenv("ASAF_KEEP_BOUNCE")) return;
  const size_t dot = fn.rfind('.');
  NSString *copy = @((fn.substr(0, dot == std::string::npos ? fn.size() : dot) + ".bounce.wav").c_str());
  [[NSFileManager defaultManager] removeItemAtPath:copy error:nil];
  const bool ok = [[NSFileManager defaultManager] copyItemAtPath:@(fn.c_str()) toPath:copy error:nil];
  NSLog(@"reaper_asaf: bounce kept at %@: %d", copy, (int)ok);
}

static int *renderBlockSizeVar()
{
  int sz = 0;
  void *p = get_config_var ? get_config_var("renderbsnew", &sz) : nullptr;
  return (p && sz == (int)sizeof(int)) ? (int *)p : nullptr;
}

// Set the render block size to the one ASAF Export needs, and save it in reaper.ini so it survives a
// restart (a value only changed in memory is lost when REAPER quits). False if it couldn't be set.
static bool setRenderBlockSize()
{
  if (set_config_var_string && set_config_var_string("renderbsnew", std::to_string(kRenderBlockSize).c_str(), 1)) return true;
  int *bs = renderBlockSizeVar();
  if (bs) *bs = kRenderBlockSize;
  return bs != nullptr;
}

// ============================================================================ render sink

static std::string g_partProblem; // the last problem a sink had; read by "Export project"
static bool g_renderingParts = false; // "Export project" is rendering several files that it will join: sinks must not convert them

class ASAF_Sink : public PCM_sink
{
 public:
  ASAF_Sink(const char *fn, int nch, int srate, bool apac, bool part) : m_fn(fn ? fn : ""), m_nch(nch), m_srate(srate), m_apac(apac), m_part(part)
  {
    DBG("create sink '%s' nch=%d srate=%d main=%d", m_fn.c_str(), nch, srate, (int)[NSThread isMainThread]);
    if (!m_writer.open(m_fn.c_str(), nch, srate)) { m_problem = "Could not create " + m_fn; return; }
    __block std::string err; __block bool armed = false;
    onMain(^{ armed = asaf::armExport(true, &err); });
    if (!armed) m_problem = err.empty() ? "Could not arm ASAF Export." : err;
    m_armed = armed;
    if (srate != 48000) m_problem = "ASAF requires a 48 kHz render (this render is " + std::to_string(srate) + " Hz).";
    // The wrong block size (REAPER's default, or a setting lost in a restart): fix it here. Whether
    // that is in time for this render shows in the blocks we are given, so decide when it finishes.
    if (int *bs = renderBlockSizeVar()) {
      if (*bs != kRenderBlockSize) {
        const int was = *bs;
        __block bool set = false;
        onMain(^{ set = setRenderBlockSize(); });
        m_blockSizeFixed = set;
        DBG("render block size was %d; set to %d: %d", was, kRenderBlockSize, (int)set);
        if (!set) m_problem = "ASAF requires a render block size of 1024 samples. Set it in Preferences > Audio > Rendering, then render again.";
      }
    }
  }

  ~ASAF_Sink() override
  {
    m_writer.close();
    disarm();
  }

  void GetOutputInfoString(char *buf, int buflen) override
  {
    snprintf(buf, buflen, "ASAF BWF%s, %d Hz, %d object/scene channel%s", m_apac ? " + APAC" : "", m_srate,
             m_nch - kMetadataChannels, m_nch - kMetadataChannels == 1 ? "" : "s");
  }
  const char *GetFileName() override { return m_fn.c_str(); }
  int GetNumChannels() override { return m_nch; }
  double GetLength() override { return m_srate > 0 ? (double)m_writer.frames() / m_srate : 0.0; }
  INT64 GetFileSize() override { return m_writer.bytes(); }
  void WriteMIDI(MIDI_eventlist *, int, double) override {}

  void WriteDoubles(ReaSample **samples, int len, int nch, int offset, int spacing) override
  {
    // every block but the last has to be 1024 samples
    if (m_lastLen >= 0 && m_lastLen != kRenderBlockSize) m_wrongBlocks = true;
    m_lastLen = len;
    m_writer.write(samples, len, nch, offset, spacing);
  }

  int Extended(int call, void *parm1, void *parm2, void *parm3) override
  {
    DBG("Extended 0x%x frames=%lld", call, (long long)m_writer.frames());
    if (call == PCM_SINK_EXT_DONE) { finish(); return 1; }
    return 0;
  }

 private:
  void disarm()
  {
    if (!m_armed) return;
    m_armed = false;
    onMain(^{ asaf::armExport(false, nullptr); });
  }

  // Render finished: close the bounce file and have ASAF Export turn it into an ASAF BWF.
  void finish()
  {
    if (m_finished) return;
    m_finished = true;
    m_writer.close();
    if (!m_part) keepBounce(m_fn);
    disarm();
    DBG("finish: blockSizeFixed=%d wrongBlocks=%d lastLen=%d", (int)m_blockSizeFixed, (int)m_wrongBlocks, m_lastLen);
    if (m_problem.empty() && m_blockSizeFixed && m_wrongBlocks)
      m_problem = "This render did not use the 1024-sample block size ASAF needs. The setting "
                  "(Preferences > Audio > Rendering) has now been changed to 1024: render again.";
    if (!m_problem.empty()) { g_partProblem = m_problem; if (!m_part) report("The file was rendered but not converted to ASAF.\n\n" + m_problem); return; }
    if (m_part) return; // one of several parts: "Export project" merges and converts them
    if (m_nch <= kMetadataChannels) {
      report("The file was rendered but not converted to ASAF.\n\nThe render has only " + std::to_string(m_nch) +
             " channels. Render the ASAF export bus with one channel per object plus 8 metadata channels.");
      return;
    }
    __block std::string err, apacErr; __block bool ok = false;
    std::string fn = m_fn; const bool apac = m_apac;
    onMain(^{
      ok = apac ? asaf::convertBounceToASAFAndAPAC(fn.c_str(), &err, &apacErr) : asaf::convertBounceToASAF(fn.c_str(), &err);
    });
    DBG("convert ok=%d apac=%d err='%s' apacErr='%s'", (int)ok, (int)apac, err.c_str(), apacErr.c_str());
    if (!ok) report("The file was rendered but not converted to ASAF.\n\n" + err);
    else if (!apacErr.empty()) report("The ASAF BWF was written, but the APAC file was not.\n\n" + apacErr);
  }

  std::string m_fn, m_problem;
  bool m_blockSizeFixed = false, m_wrongBlocks = false; // the setting was wrong and we changed it / blocks weren't 1024 samples
  int m_lastLen = -1;
  int m_nch, m_srate;
  asaf::BounceWriter m_writer;
  bool m_armed = false, m_finished = false, m_apac = false, m_part = false;
};

static unsigned int SinkGetFmt(const char **desc)
{
  DBG("GetFmt");
  if (desc) *desc = "ASAF (Apple Spatial Audio Format)";
  return SINK_FOURCC;
}

static const char *SinkGetExtension(const void *cfg, int cfg_l)
{
  DBG("GetExtension cfg_l=%d fourcc=%08x", cfg_l, cfg_l >= 4 ? *((const int *)cfg) : 0);
  if (cfg_l >= 4 && *((const int *)cfg) == (int)SINK_FOURCC) return "wav";
  return nullptr;
}

// Sink configuration: { fourcc, flags }. REAPER reads it back from the config panel (WM_USER+1024), so
// the format is only usable if ShowConfig returns a real window.
enum { kCfgSize = 8, kFlagAPAC = 1 };
static int cfgFlags(const void *cfg, int cfg_l)
{
  return (cfg_l >= kCfgSize && *((const int *)cfg) == (int)SINK_FOURCC) ? ((const int *)cfg)[1] : 0;
}

#define IDD_ASAF_CFG 2000
#define IDC_APAC 2001
#define IDC_CHANNELS 2002
static HINSTANCE g_hInst;

// What the current project needs in the render dialog's Channels field, as a sentence for the format
// panel. The total comes from where ASAF Export's last metadata output is routed on its track, which
// holds for sessions built by hand too; the breakdown is given when the project's units add up to it.
struct RenderNeeds { int nobj = 0, sceneCh = 0, exports = 0, total = 0; MediaTrack *exportTrack = nullptr; };
static RenderNeeds renderNeeds()
{
  RenderNeeds r; int &nobj = r.nobj, &sceneCh = r.sceneCh, &exports = r.exports, &total = r.total;
  for (int t = 0; t < CountTracks(nullptr); t++) {
    MediaTrack *tr = GetTrack(nullptr, t);
    for (int fx = 0; fx < TrackFX_GetCount(tr); fx++) {
      const std::string name = fxBaseName(tr, fx);
      if (name == "ASAF Object") nobj++;
      else if (name == "ASAF Scene") {
        const int i = findFXParam(tr, fx, "order");
        const int order = i < 0 ? 7 : (int)lround(TrackFX_GetParam(tr, fx, i, nullptr, nullptr));
        sceneCh += (order + 1) * (order + 1);
      } else if (name == "ASAF Export") {
        exports++;
        int ins = 0, outs = 0; TrackFX_GetIOSize(tr, fx, &ins, &outs);
        const int pin = (outs < kMetadataChannels ? outs : kMetadataChannels) - 1;
        if (pin < 0 || !TrackFX_GetPinMappings) continue;
        int top = 0; // highest track channel the last metadata output goes to, 1-based
        for (int word = 0; word < 4; word++) {
          int hi = 0; const unsigned lo = (unsigned)TrackFX_GetPinMappings(tr, fx, 1, pin + (word / 2) * 0x1000000, &hi);
          const unsigned bits = (word & 1) ? (unsigned)hi : lo;
          for (int b = 0; b < 32; b++) if (bits & (1u << b)) top = word * 32 + b + 1;
        }
        total = top; r.exportTrack = tr;
      }
    }
  }
  if (exports != 1 || total <= kMetadataChannels) total = 0;
  return r;
}
struct ExportPart { MediaTrack *tr; int order, audioCh, metaOffset; }; // metaOffset: channel of the first of the 8 metadata channels, or -1
static bool exportParts(std::vector<ExportPart> &parts, std::string &why);

static std::string renderChannelsAdvice()
{
  const RenderNeeds r = renderNeeds();
  std::vector<ExportPart> parts; std::string why;
  if (exportParts(parts, why) && parts.size() > 1)
    return "This project is too large for one render: use Extensions > ASAF > Export project.";
  const int nobj = r.nobj, sceneCh = r.sceneCh, exports = r.exports, total = r.total;
  if (!exports) return "This project has no ASAF Export. Run Extensions > ASAF > Set up session first.";
  if (exports > 1) return "This project has more than one ASAF Export; an export needs exactly one.";
  if (!total) return "ASAF Export's outputs are not routed to the end of its track's channels.";
  std::string s = "This project: set Channels to " + std::to_string(total);
  if (sceneCh + nobj + kMetadataChannels == total) {
    s += " (";
    if (sceneCh) s += std::to_string(sceneCh) + " scene + ";
    if (nobj) s += std::to_string(nobj) + (nobj == 1 ? " object + " : " objects + ");
    s += "8 metadata)";
  } else
    s += " (ASAF Export's metadata ends on channel " + std::to_string(total) + ")";
  return s + ".";
}

static INT_PTR SinkCfgProc(HWND hwndDlg, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
  switch (uMsg) {
    case WM_INITDIALOG:
      CheckDlgButton(hwndDlg, IDC_APAC, ((int)lParam & kFlagAPAC) ? BST_CHECKED : BST_UNCHECKED);
      SetDlgItemText(hwndDlg, IDC_CHANNELS, renderChannelsAdvice().c_str());
      SetTimer(hwndDlg, 1, 1000, nullptr); // the project can change while the render dialog is open
      return 0;
    case WM_TIMER: {
      const std::string now = renderChannelsAdvice();
      char cur[256] = ""; GetDlgItemText(hwndDlg, IDC_CHANNELS, cur, sizeof cur);
      if (now != cur) SetDlgItemText(hwndDlg, IDC_CHANNELS, now.c_str());
      return 0;
    }
    case WM_DESTROY:
      KillTimer(hwndDlg, 1);
      return 0;
    case WM_USER + 1024:
      if (wParam) *((int *)wParam) = kCfgSize;
      if (lParam) {
        ((int *)lParam)[0] = (int)SINK_FOURCC;
        ((int *)lParam)[1] = IsDlgButtonChecked(hwndDlg, IDC_APAC) ? kFlagAPAC : 0;
      }
      return 0;
  }
  return 0;
}

static HWND SinkShowConfig(const void *cfg, int cfg_l, HWND parent)
{
  if (cfg_l >= 4 && *((const int *)cfg) == (int)SINK_FOURCC)
    return CreateDialogParam(g_hInst, MAKEINTRESOURCE(IDD_ASAF_CFG), parent, SinkCfgProc, (LPARAM)cfgFlags(cfg, cfg_l));
  return nullptr;
}

// REAPER gives sink panels about 45 dialog units of height (cf. the SDK's example sink); keep within it.
SWELL_DEFINE_DIALOG_RESOURCE_BEGIN(IDD_ASAF_CFG, SWELL_DLG_WS_CHILD | SWELL_DLG_WS_FLIPPED | SWELL_DLG_WS_NOAUTOSIZE, "", 300, 45, 1.8)
BEGIN
  CONTROL "Also create an APAC file (.mp4) next to the ASAF BWF", IDC_APAC, "Button", BS_AUTOCHECKBOX | WS_TABSTOP, 4, 3, 292, 12
  LTEXT "", IDC_CHANNELS, 4, 19, 292, 10
  LTEXT "Render the ASAF Export track as a selected-track stem, at 48 kHz.", -1, 4, 30, 292, 10
END
SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_ASAF_CFG)

static PCM_sink *SinkCreate(const char *filename, void *cfg, int cfg_l, int nch, int srate, bool buildpeaks)
{
  DBG("CreateSink cfg_l=%d fourcc=%08x file=%s", cfg_l, cfg_l >= 4 ? *((int *)cfg) : 0, filename ? filename : "(null)");
  if (cfg_l >= 4 && *((int *)cfg) == (int)SINK_FOURCC)
    return new ASAF_Sink(filename, nch, srate, (cfgFlags(cfg, cfg_l) & kFlagAPAC) != 0, g_renderingParts);
  return nullptr;
}

static pcmsink_register_t g_sinkReg = { SinkGetFmt, SinkGetExtension, SinkShowConfig, SinkCreate };

// ============================================================================ session setup

// Add one of the ASAF AudioUnits by its exact name ("ASAF Object" must not match "ASAF Object Renderer").
static int addASAF(MediaTrack *tr, const char *name)
{
  const std::string n = name;
  // Prefer the CLAP plug-ins (ASAF.clap); fall back to the AU shim.
  for (const std::string &q : { "CLAP:" + n + " (ASAF Bridge)", "CLAP:" + n, "AU:" + n + " (Apple)", "AU: " + n + " (Apple)", "AU:" + n, n }) {
    int fx = TrackFX_AddByName(tr, q.c_str(), false, -1);
    if (fx < 0) continue;
    if (fxBaseName(tr, fx) == n) return fx;
    TrackFX_Delete(tr, fx);
  }
  return -1;
}

static bool setFXParam(MediaTrack *tr, int fx, const char *rawId, double value)
{
  const int i = findFXParam(tr, fx, rawId);
  return i >= 0 && TrackFX_SetParam(tr, fx, i, value);
}

// Route output pin `pin` of an FX to exactly one track channel (0-based, < 128).
static void mapOutputPin(MediaTrack *tr, int fx, int pin, int chan)
{
  int lo = 0, hi = 0, lo2 = 0, hi2 = 0;
  if (chan < 32) lo = 1 << chan; else if (chan < 64) hi = 1 << (chan - 32);
  else if (chan < 96) lo2 = 1 << (chan - 64); else hi2 = 1 << (chan - 96);
  TrackFX_SetPinMappings(tr, fx, 1, pin, lo, hi);
  TrackFX_SetPinMappings(tr, fx, 1, pin + 0x1000000, lo2, hi2); // second 64 channels
}

// Show a track's first FX in the track panel and mixer (REAPER's "embedded UI"). There is no API for
// this, so flip the flag in the track's state chunk: "WAK <keys> <embed>", bit 0 = TCP, bit 1 = MCP.
// This reloads the track's FX, so call it before setting parameters.
static void showEmbeddedUI(MediaTrack *tr)
{
  std::vector<char> buf(4 << 20);
  if (!GetTrackStateChunk || !SetTrackStateChunk || !GetTrackStateChunk(tr, buf.data(), (int)buf.size(), false)) return;
  std::string chunk = buf.data();
  const size_t p = chunk.find("\nWAK ");
  if (p == std::string::npos) return;
  const size_t eol = chunk.find('\n', p + 1), sp = chunk.find(' ', p + 5);
  if (eol == std::string::npos || sp == std::string::npos || sp > eol) return;
  chunk.replace(sp + 1, eol - sp - 1, "3");
  SetTrackStateChunk(tr, chunk.c_str(), false);
}

static MediaTrack *newTrack(const char *name, int nch, bool mainSend)
{
  int idx = CountTracks(nullptr);
  InsertTrackAtIndex(idx, false);
  MediaTrack *tr = GetTrack(nullptr, idx);
  GetSetMediaTrackInfo_String(tr, "P_NAME", (char *)name, true);
  SetMediaTrackInfo_Value(tr, "I_NCHAN", nch);
  SetMediaTrackInfo_Value(tr, "B_MAINSEND", mainSend ? 1 : 0);
  return tr;
}

// Post-fader mono send from channel 1 of `src` to channel `dstChan` (0-based) of `dst`.
static void monoSend(MediaTrack *src, MediaTrack *dst, int dstChan)
{
  int s = CreateTrackSend(src, dst);
  if (s < 0) return;
  SetTrackSendInfo_Value(src, 0, s, "I_SRCCHAN", 1024 | 0);
  SetTrackSendInfo_Value(src, 0, s, "I_DSTCHAN", 1024 | dstChan);
  SetTrackSendInfo_Value(src, 0, s, "I_MIDIFLAGS", 31); // no MIDI
}

// Send `nch` channels (rounded up to a pair) from channel 1 of `src` to channels starting at `dstChan` of `dst`.
static void multiSend(MediaTrack *src, MediaTrack *dst, int nch, int dstChan)
{
  int s = CreateTrackSend(src, dst);
  if (s < 0) return;
  SetTrackSendInfo_Value(src, 0, s, "I_SRCCHAN", ((nch + 1) / 2) << 10);
  SetTrackSendInfo_Value(src, 0, s, "I_DSTCHAN", dstChan);
  SetTrackSendInfo_Value(src, 0, s, "I_MIDIFLAGS", 31); // no MIDI
}

static int sceneChannels(int order) { return order < 0 ? 0 : (order + 1) * (order + 1); }

// Builds the session: `nobj` objects and, if sceneOrder >= 0, one ambisonic scene of that order.
// Returns a list of problems (empty if everything was created).
static std::string buildSession(int nobj, int sceneOrder)
{
  Undo_BeginBlock();
  PreventUIRefresh(1);
  std::string problems;

  // Export bus: the scene's channels (ASAF Export lists scenes before objects), then object i on the
  // next channel i, then ASAF Export's 8 metadata channels. Not sent to the master.
  const int sceneCh = sceneChannels(sceneOrder), nAudio = sceneCh + nobj;
  const int busCh = nAudio + kMetadataChannels, busChEven = (busCh + 1) & ~1;
  MediaTrack *bus = newTrack("ASAF Export Bus", busChEven, false);
  // Object positions reach ASAF Export through a shared metadata bus, not along the audio path, so
  // the object tracks and this bus must be processed in step: no anticipative FX on either. Otherwise
  // REAPER runs the object tracks a varying few blocks ahead and automation lands early in the export.
  SetMediaTrackInfo_Value(bus, "I_PERFFLAGS", 2);
  int exFx = addASAF(bus, "ASAF Export");
  if (exFx < 0) problems += "- Could not add ASAF Export (is ASAF.clap installed and scanned?)\n";
  else {
    int ins = 0, outs = 0; TrackFX_GetIOSize(bus, exFx, &ins, &outs);
    for (int p = 0; p < outs; p++) {
      if (p < kMetadataChannels) mapOutputPin(bus, exFx, p, nAudio + p);
      else { TrackFX_SetPinMappings(bus, exFx, 1, p, 0, 0); TrackFX_SetPinMappings(bus, exFx, 1, p + 0x1000000, 0, 0); }
    }
    if (outs != kMetadataChannels) problems += "- ASAF Export reports " + std::to_string(outs) + " outputs (expected 8); check its pin routing\n";
  }

  // Monitor busses: one ASAF Object Renderer per block of 64 objects, sent to the master.
  std::vector<MediaTrack *> monitors;
  for (int b = 0; b * 64 < nobj; b++) {
    char name[64]; snprintf(name, sizeof name, "ASAF Monitor %d-%d", b * 64 + 1, (nobj < b * 64 + 64 ? nobj : b * 64 + 64));
    MediaTrack *mon = newTrack(name, 64, true);
    int fx = addASAF(mon, "ASAF Object Renderer");
    if (fx < 0) problems += "- Could not add ASAF Object Renderer\n";
    else setFXParam(mon, fx, "inputIndex", b);
    monitors.push_back(mon);
  }

  // Scene track: ASAF Scene carries the scene's metadata; rotation, gain and spatial filters are applied
  // to its audio. Put ACN/SN3D ambisonic media of the chosen order on it.
  if (sceneCh) {
    const int trCh = (sceneCh + 1) & ~1;
    char name[32]; snprintf(name, sizeof name, "Scene (order %d)", sceneOrder);
    MediaTrack *tr = newTrack(name, trCh < 2 ? 2 : trCh, false);
    SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", 2); // see the export bus above
    int fx = addASAF(tr, "ASAF Scene");
    if (fx < 0) problems += "- Could not add ASAF Scene\n";
    else { setFXParam(tr, fx, "index", 0); setFXParam(tr, fx, "order", sceneOrder); }
    MediaTrack *mon = newTrack("ASAF Scene Monitor", 64, true);
    SetMediaTrackInfo_Value(mon, "C_MAINSEND_NCH", 2);
    int rfx = addASAF(mon, "ASAF Scene Renderer");
    if (rfx < 0) problems += "- Could not add ASAF Scene Renderer\n";
    else { setFXParam(mon, rfx, "inputIndex", 0); setFXParam(mon, rfx, "channelOutputType", 1); }
    multiSend(tr, bus, sceneCh, 0);
    multiSend(tr, mon, sceneCh, 0);
  }

  // Object tracks: mono, ASAF Object carries the position metadata; audio goes to the two busses only.
  bool objFailed = false;
  for (int i = 0; i < nobj; i++) {
    char name[32]; snprintf(name, sizeof name, "Object %d", i + 1);
    MediaTrack *tr = newTrack(name, 2, false);
    SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", 2); // see the export bus above
    int fx = addASAF(tr, "ASAF Object");
    if (fx < 0) objFailed = true;
    else {
      showEmbeddedUI(tr); // the small panner in the track panel / mixer (CLAP version only)
      setFXParam(tr, fx, "index", i);
    }
    monoSend(tr, bus, sceneCh + i);
    monoSend(tr, monitors[i / 64], i % 64);
  }
  if (objFailed) problems += "- Could not add ASAF Object to one or more tracks\n";

  if (!setRenderBlockSize()) problems += "- Could not set the render block size; set it to 1024 in Preferences > Audio > Rendering\n";

  SetOnlyTrackSelected(bus);
  PreventUIRefresh(-1);
  TrackList_AdjustWindows(false);
  UpdateArrange();
  Undo_EndBlock("ASAF: Set up session", -1);

  return problems;
}

static void setupSessionInteractive()
{
  char val[128] = "16,";
  if (!GetUserInputs("ASAF: Set up session", 2, "Number of objects (0-120):,Scene order (0-7; blank = no scene):", val, sizeof val)) return;
  const char *comma = strchr(val, ',');
  const int nobj = atoi(val);
  const char *so = comma ? comma + 1 : ""; while (*so == ' ') so++;
  const int sceneOrder = *so ? atoi(so) : -1;
  if (sceneOrder > 7 || (*so && (sceneOrder < 0 || !isdigit((unsigned char)*so)))) { report("Enter a scene order between 0 and 7, or leave it blank for no scene."); return; }
  if (nobj < 0 || nobj + sceneChannels(sceneOrder) < 1 || nobj + sceneChannels(sceneOrder) > kMaxObjects) {
    report("Objects plus scene channels must be between 1 and 120 (a scene of order n uses (n+1)\u00b2 channels)."); return;
  }
  std::string problems = buildSession(nobj, sceneOrder);
  std::string msg =
      "Created " + std::to_string(nobj) + " object tracks" + (sceneOrder >= 0 ? ", a scene track of order " + std::to_string(sceneOrder) : std::string()) +
      ", the monitor busses and \"ASAF Export Bus\".\n\n"
      "To export, open File > Render and set:\n"
      "  Source:  Selected tracks (stems), with \"ASAF Export Bus\" selected\n"
      "  Sample rate:  48000 Hz\n"
      "  Channels:  " + std::to_string(nobj + sceneChannels(sceneOrder) + kMetadataChannels) + "\n"
      "  Format:  ASAF (Apple Spatial Audio Format)\n\n"
      "Position objects with the parameters of ASAF Object on each track." +
      (sceneOrder >= 0 ? "\nPut ACN/SN3D ambisonic audio on the scene track." : "");
  if (!problems.empty()) msg += "\n\nProblems:\n" + problems;
  report(msg);
}

// ReaScript: integer ASAF_SetupSession(integer objectCount) -- no dialogs; returns 0 on success.
static int setupSession(int nobj, int sceneOrder)
{
  if (sceneOrder > 7) return -1;
  if (sceneOrder < 0) sceneOrder = -1;
  if (nobj < 0 || nobj + sceneChannels(sceneOrder) < 1 || nobj + sceneChannels(sceneOrder) > kMaxObjects) return -1;
  std::string problems = buildSession(nobj, sceneOrder);
  if (problems.empty()) return 0;
  if (ShowConsoleMsg) ShowConsoleMsg(("ASAF: Set up session reported problems:\n" + problems).c_str());
  return 1;
}
static int ASAF_SetupSession(int nobj) { return nobj < 1 ? -1 : setupSession(nobj, -1); }
// ReaScript: integer ASAF_SetupSceneSession(integer objectCount, integer sceneOrder) -- as ASAF_SetupSession,
// with an ambisonic scene of the given order (0-7) ahead of the objects. objectCount may be 0.
static int ASAF_SetupSceneSession(int nobj, int sceneOrder) { return sceneOrder < 0 ? -1 : setupSession(nobj, sceneOrder); }
static void *ASAF_SetupSceneSession_vararg(void **arglist, int numparms)
{
  return (void *)(intptr_t)(numparms >= 2 ? ASAF_SetupSceneSession((int)(intptr_t)arglist[0], (int)(intptr_t)arglist[1]) : -1);
}
// ReaScript: integer ASAF_RenderChannels() -- the number to put in the render dialog's Channels field
// for the current project (scene channels + objects + 8), or 0 if it has no usable ASAF Export.
static int ASAF_RenderChannels() { return renderNeeds().total; }
static void *ASAF_RenderChannels_vararg(void **, int) { return (void *)(intptr_t)ASAF_RenderChannels(); }
// ReaScript: integer ASAF_AddUnit(MediaTrack track, string unitName) -- adds e.g. "ASAF Object" by its
// exact name (CLAP version if installed, else the AU shim). Returns the FX index or -1.
static int ASAF_AddUnit(MediaTrack *track, const char *unitName)
{
  return (track && unitName && ValidatePtr2(nullptr, track, "MediaTrack*")) ? addASAF(track, unitName) : -1;
}
static void *ASAF_AddUnit_vararg(void **arglist, int numparms)
{
  return (void *)(intptr_t)(numparms >= 2 ? ASAF_AddUnit((MediaTrack *)arglist[0], (const char *)arglist[1]) : -1);
}

// ReaScript: ASAF_ShowEmbeddedUI(MediaTrack track) -- shows the track's FX in the track panel and mixer.
// Reloads the track's FX, so call it before setting parameters.
static void ASAF_ShowEmbeddedUI(MediaTrack *track)
{
  if (track && ValidatePtr2(nullptr, track, "MediaTrack*")) showEmbeddedUI(track);
}
static void *ASAF_ShowEmbeddedUI_vararg(void **arglist, int numparms)
{
  if (numparms >= 1) ASAF_ShowEmbeddedUI((MediaTrack *)arglist[0]);
  return nullptr;
}

static void *ASAF_SetupSession_vararg(void **arglist, int numparms)
{
  return (void *)(intptr_t)ASAF_SetupSession(numparms > 0 ? (int)(intptr_t)arglist[0] : 0);
}

// ============================================================================ export project
//
// One REAPER track carries at most 128 channels, so a project with more scene and object channels than
// that (the templates: a 64-channel scene and 64 or more objects) cannot be rendered as one stem.
// "Export project" renders the tracks that carry the audio as separate files in one pass, joins them
// into a single bounce file and has ASAF Export convert that.
//
// The tracks are marked with P_EXT:ASAF_EXPORT = "<order>:<audio channels>:<1 if it has the metadata>",
// in the order ASAF Export lists things: scenes, then objects by index, with the metadata last.

static std::string trackName(MediaTrack *tr)
{
  char buf[256] = ""; GetSetMediaTrackInfo_String(tr, "P_NAME", buf, false); return buf;
}

static bool exportParts(std::vector<ExportPart> &parts, std::string &why)
{
  parts.clear();
  const int n = CountTracks(nullptr);
  for (int t = 0; t < n; t++) { // marked tracks
    MediaTrack *tr = GetTrack(nullptr, t);
    char buf[64] = ""; int order = 0, ch = 0, meta = 0;
    if (GetSetMediaTrackInfo_String(tr, "P_EXT:ASAF_EXPORT", buf, false) && sscanf(buf, "%d:%d:%d", &order, &ch, &meta) == 3)
      parts.push_back({ tr, order, ch, meta ? ch : -1 });
  }
  if (parts.empty()) { // a session with one export bus
    const RenderNeeds r = renderNeeds();
    if (r.total > kMetadataChannels) parts.push_back({ r.exportTrack, 0, r.total - kMetadataChannels, r.total - kMetadataChannels });
  }
  if (parts.empty()) { // a project made from a template before the tracks were marked: go by the names
    MediaTrack *scene = nullptr, *ex = nullptr; std::vector<std::pair<int, MediaTrack *>> busses;
    for (int t = 0; t < n; t++) {
      MediaTrack *tr = GetTrack(nullptr, t); const std::string name = trackName(tr); int a = 0, z = 0;
      if (name == "Scene 1") scene = tr;
      else if (name == "ASAF Export") ex = tr;
      else if (sscanf(name.c_str(), "ASAF Objects %d-%d", &a, &z) == 2 && z == a + 63) busses.push_back({ a, tr });
    }
    if (scene && ex && !busses.empty()) {
      std::sort(busses.begin(), busses.end());
      parts.push_back({ scene, 0, 64, -1 });
      for (auto &b : busses) parts.push_back({ b.second, b.first, 64, -1 });
      parts.push_back({ ex, 1 << 20, 0, 0 });
    }
  }
  if (parts.empty()) { why = "This project has no ASAF export bus. Run Extensions > ASAF > Set up session, or start from a template."; return false; }
  std::stable_sort(parts.begin(), parts.end(), [](const ExportPart &a, const ExportPart &b) { return a.order < b.order; });
  int metas = 0, audio = 0;
  for (const ExportPart &p : parts) { if (p.metaOffset >= 0) metas++; audio += p.audioCh; }
  if (metas != 1) { why = "The project's export tracks must include exactly one with ASAF Export's metadata (found " + std::to_string(metas) + ")."; return false; }
  const RenderNeeds r = renderNeeds();
  if (r.sceneCh + r.nobj != audio) {
    why = "The export tracks carry " + std::to_string(audio) + " audio channels, but the project's ASAF Scene and ASAF Object plug-ins add up to " +
          std::to_string(r.sceneCh + r.nobj) + " (" + std::to_string(r.sceneCh) + " scene + " + std::to_string(r.nobj) + " objects). They have to match.";
    return false;
  }
  return true;
}

// The data of a 32-bit float WAV / RF64 file written by BounceWriter.
struct PartFile {
  FILE *fp = nullptr; int nch = 0; int64_t frames = 0;
  bool open(const char *path)
  {
    fp = fopen(path, "rb"); if (!fp) return false;
    char hdr[12], id[4]; uint32_t sz; uint64_t data64 = 0;
    if (fread(hdr, 12, 1, fp) != 1) return false;
    while (fread(id, 4, 1, fp) == 1 && fread(&sz, 4, 1, fp) == 1) {
      if (!memcmp(id, "ds64", 4)) { uint64_t v[2]; if (sz < 16 || fread(v, 16, 1, fp) != 1) return false; data64 = v[1]; fseeko(fp, sz - 16 + (sz & 1), SEEK_CUR); }
      else if (!memcmp(id, "fmt ", 4)) { uint16_t f[2]; if (fread(f, 4, 1, fp) != 1) return false; nch = f[1]; fseeko(fp, sz - 4 + (sz & 1), SEEK_CUR); }
      else if (!memcmp(id, "data", 4)) { const uint64_t bytes = sz == 0xFFFFFFFFu ? data64 : sz; frames = nch ? (int64_t)(bytes / ((uint64_t)nch * 4)) : 0; return nch > 0; }
      else fseeko(fp, sz + (sz & 1), SEEK_CUR);
    }
    return false;
  }
  ~PartFile() { if (fp) fclose(fp); }
};

static double getInfo(const char *key) { return GetSetProjectInfo(nullptr, key, 0, false); }
static std::string getInfoStr(const char *key) { std::vector<char> b(16384, 0); GetSetProjectInfo_String(nullptr, key, b.data(), false); return b.data(); }
static void setInfoStr(const char *key, const std::string &v) { std::vector<char> b(v.begin(), v.end()); b.resize(v.size() + 4096, 0); GetSetProjectInfo_String(nullptr, key, b.data(), true); }

static std::string sinkFormat(int flags)
{
  const int cfg[2] = { (int)SINK_FOURCC, flags };
  return [[[NSData dataWithBytes:cfg length:sizeof cfg] base64EncodedStringWithOptions:0] UTF8String];
}

// Renders the project's export tracks to `path` (.wav) and converts the result. Main thread. Returns
// false with `err` set if no ASAF file was made; `warn` gets problems that left a usable ASAF BWF.
static bool exportProject(const std::string &path, bool apac, std::string &err, std::string &warn)
{
  std::vector<ExportPart> parts;
  if (!exportParts(parts, err)) return false;
  const size_t slash = path.rfind('/'), dot = path.rfind('.');
  if (slash == std::string::npos) { err = "The output file needs a full path."; return false; }
  const std::string dir = path.substr(0, slash);
  const std::string base = path.substr(slash + 1, (dot != std::string::npos && dot > slash ? dot : path.size()) - slash - 1);
  const bool multi = parts.size() > 1;
  setRenderBlockSize();

  // what the user had, to put back afterwards
  static const char *const numKeys[] = { "RENDER_SETTINGS", "RENDER_CHANNELS", "RENDER_SRATE", "RENDER_DITHER", "RENDER_NORMALIZE", "RENDER_ADDTOPROJ" };
  static const char *const strKeys[] = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" };
  double numWas[6]; std::string strWas[4];
  for (int i = 0; i < 6; i++) numWas[i] = getInfo(numKeys[i]);
  for (int i = 0; i < 4; i++) strWas[i] = getInfoStr(strKeys[i]);
  std::vector<MediaTrack *> selWas;
  for (int t = 0; t < CountTracks(nullptr); t++) { MediaTrack *tr = GetTrack(nullptr, t); if (IsTrackSelected(tr)) selWas.push_back(tr); }

  int channels = 2;
  for (const ExportPart &p : parts) channels = (std::max)(channels, p.metaOffset >= 0 ? p.metaOffset + kMetadataChannels : p.audioCh);
  for (int t = 0; t < CountTracks(nullptr); t++) SetTrackSelected(GetTrack(nullptr, t), false);
  for (const ExportPart &p : parts) SetTrackSelected(p.tr, true);
  GetSetProjectInfo(nullptr, "RENDER_SETTINGS", 3, true); // stems, selected tracks only
  GetSetProjectInfo(nullptr, "RENDER_CHANNELS", channels, true);
  GetSetProjectInfo(nullptr, "RENDER_SRATE", 48000, true);
  GetSetProjectInfo(nullptr, "RENDER_DITHER", 0, true);
  GetSetProjectInfo(nullptr, "RENDER_NORMALIZE", 0, true);
  GetSetProjectInfo(nullptr, "RENDER_ADDTOPROJ", 0, true);
  setInfoStr("RENDER_FILE", dir);
  setInfoStr("RENDER_PATTERN", multi ? base + ".part$tracknumber" : base);
  setInfoStr("RENDER_FORMAT", sinkFormat(apac && !multi ? kFlagAPAC : 0));
  setInfoStr("RENDER_FORMAT2", "");

  // the files REAPER will write, one per selected track in track order
  std::vector<std::string> targets;
  { const std::string t = getInfoStr("RENDER_TARGETS"); size_t a = 0; while (a < t.size()) { size_t b = t.find(';', a); if (b == std::string::npos) b = t.size(); if (b > a) targets.push_back(t.substr(a, b - a)); a = b + 1; } }
  DBG("export: %d part(s), %d channels each, %d target(s)", (int)parts.size(), channels, (int)targets.size());
  bool ok = true;
  if (getInfoStr("RENDER_FORMAT") != sinkFormat(apac && !multi ? kFlagAPAC : 0)) { err = "REAPER did not accept the ASAF render format."; ok = false; }
  else if (targets.size() != parts.size()) { err = "REAPER would render " + std::to_string(targets.size()) + " files for " + std::to_string(parts.size()) + " export tracks."; ok = false; }
  if (ok) {
    for (const std::string &t : targets) unlink(t.c_str());
    g_partProblem.clear();
    g_renderingParts = multi;
    Main_OnCommand(42230, 0); // render with the most recent settings, close the dialog when done
    g_renderingParts = false;
    if (!g_partProblem.empty()) { err = g_partProblem; ok = false; }
  }

  for (int i = 0; i < 6; i++) GetSetProjectInfo(nullptr, numKeys[i], numWas[i], true);
  for (int i = 0; i < 4; i++) setInfoStr(strKeys[i], strWas[i]);
  for (int t = 0; t < CountTracks(nullptr); t++) SetTrackSelected(GetTrack(nullptr, t), false);
  for (MediaTrack *tr : selWas) SetTrackSelected(tr, true);
  if (!ok) { if (multi) for (const std::string &t : targets) unlink(t.c_str()); return false; }

  if (!multi) { // the sink converted it, and reported any problem itself
    if (!asaf::isASAFFile(targets[0].c_str(), nullptr)) { err = "The render was not converted to ASAF."; return false; }
    if (targets[0] != path) rename(targets[0].c_str(), path.c_str());
    return true;
  }

  // Join the parts: targets are in track order; write the parts' audio in export order, then the metadata.
  std::vector<int> trackOrder(parts.size());
  for (size_t i = 0; i < parts.size(); i++) trackOrder[i] = (int)GetMediaTrackInfo_Value(parts[i].tr, "IP_TRACKNUMBER");
  std::vector<PartFile> files(parts.size());
  int audio = 0; int64_t frames = INT64_MAX;
  for (size_t i = 0; i < parts.size() && ok; i++) {
    int rank = 0; for (size_t j = 0; j < parts.size(); j++) if (trackOrder[j] < trackOrder[i]) rank++;
    const ExportPart &p = parts[i];
    if (!files[i].open(targets[rank].c_str())) { err = "A rendered part is missing or unreadable: " + targets[rank]; ok = false; break; }
    if (files[i].nch < (p.metaOffset >= 0 ? p.metaOffset + kMetadataChannels : p.audioCh)) { err = "A rendered part has too few channels: " + targets[rank]; ok = false; break; }
    frames = (std::min)(frames, files[i].frames); audio += p.audioCh;
  }
  if (ok) {
    const int nch = audio + kMetadataChannels, kBlock = 4096;
    asaf::BounceWriter w;
    if (!w.open(path.c_str(), nch, 48000)) { err = "Could not create " + path; ok = false; }
    else {
      std::vector<std::vector<double>> buf(nch, std::vector<double>(kBlock)); std::vector<double *> ptrs(nch);
      for (int c = 0; c < nch; c++) ptrs[c] = buf[c].data();
      std::vector<float> in;
      for (int64_t pos = 0; pos < frames && ok; pos += kBlock) {
        const int len = (int)(std::min<int64_t>)(kBlock, frames - pos); int c0 = 0;
        for (size_t i = 0; i < parts.size() && ok; i++) {
          const ExportPart &p = parts[i]; const int fch = files[i].nch;
          in.resize((size_t)len * fch);
          if (fread(in.data(), sizeof(float) * fch, len, files[i].fp) != (size_t)len) { err = "A rendered part is shorter than expected."; ok = false; break; }
          for (int c = 0; c < p.audioCh; c++) for (int k = 0; k < len; k++) buf[c0 + c][k] = in[(size_t)k * fch + c];
          if (p.metaOffset >= 0) for (int c = 0; c < kMetadataChannels; c++) for (int k = 0; k < len; k++) buf[audio + c][k] = in[(size_t)k * fch + p.metaOffset + c];
          c0 += p.audioCh;
        }
        if (ok) w.write(ptrs.data(), len, nch, 0, 1);
      }
      if (!w.close() && ok) { err = "Could not finish writing " + path; ok = false; }
    }
  }
  files.clear();
  for (const std::string &t : targets) unlink(t.c_str());
  if (!ok) return false;
  keepBounce(path);
  std::string apacErr;
  ok = apac ? asaf::convertBounceToASAFAndAPAC(path.c_str(), &err, &apacErr) : asaf::convertBounceToASAF(path.c_str(), &err);
  DBG("export: convert ok=%d apac=%d err='%s' apacErr='%s'", (int)ok, (int)apac, err.c_str(), apacErr.c_str());
  if (ok && !apacErr.empty()) warn = "The ASAF BWF was written, but the APAC file was not.\n\n" + apacErr;
  return ok;
}

static void exportProjectInteractive()
{
  std::vector<ExportPart> parts; std::string err, warn;
  if (!exportParts(parts, err)) { report(err); return; }
  char name[512] = ""; GetProjectName(nullptr, name, sizeof name);
  std::string stem = name; const size_t dot = stem.rfind('.'); if (dot != std::string::npos) stem = stem.substr(0, dot);
  std::string path; bool apac = false;
  if (!ASAF_ChooseExportFile(stem.empty() ? "ASAF export" : stem.c_str(), path, apac)) return;
  if (!exportProject(path, apac, err, warn)) report("The project was not exported to ASAF.\n\n" + err);
  else if (!warn.empty()) report(warn);
}

// ReaScript: integer ASAF_ExportProject(string path, boolean apac) -- renders the project's export
// tracks to an ASAF BWF at path (.wav), and an APAC .mp4 next to it if apac. Returns 0 on success.
static int ASAF_ExportProject(const char *path, bool apac)
{
  std::string err, warn;
  if (!path || !*path) return -1;
  if (exportProject(path, apac, err, warn)) { if (!warn.empty()) report(warn); return warn.empty() ? 0 : 2; }
  report("The project was not exported to ASAF.\n\n" + err);
  return 1;
}
static void *ASAF_ExportProject_vararg(void **arglist, int numparms)
{
  return (void *)(intptr_t)(numparms >= 2 ? ASAF_ExportProject((const char *)arglist[0], arglist[1] != nullptr) : -1);
}

// ============================================================================ entry point

static int g_cmdSetup = 0, g_cmdPanner = 0, g_cmdDock = 0, g_cmdExport = 0;

// "New project from template" actions, for the templates in ProjectTemplates (see templates/).
static const int kTemplateSizes[] = { 64, 128, 192, 256 };
static int g_cmdTemplate[4];

static std::string templatePath(int objects)
{
  return std::string(GetResourcePath()) + "/ProjectTemplates/ASAF - Up to " + std::to_string(objects) + " Objects + 1 Scene.RPP";
}

static void openTemplate(int objects)
{
  const std::string path = templatePath(objects);
  if (access(path.c_str(), R_OK) != 0) {
    report("The template for " + std::to_string(objects) + " objects is not installed.\n\nExpected at:\n" + path);
    return;
  }
  Main_openProject(("template:" + path).c_str());
}

static bool hookCommand(int command, int flag)
{
  if (!command) return false;
  if (command == g_cmdSetup) { setupSessionInteractive(); return true; }
  if (command == g_cmdExport) { exportProjectInteractive(); return true; }
  if (command == g_cmdPanner) { ASAF_TogglePanner(g_hInst); return true; }
  if (command == g_cmdDock) {
    if (!ASAF_PannerVisible()) ASAF_TogglePanner(g_hInst);
    ASAF_SetPannerDocked(!ASAF_PannerDocked());
    return true;
  }
  for (int i = 0; i < 4; i++) if (command == g_cmdTemplate[i]) { openTemplate(kTemplateSizes[i]); return true; }
  return false;
}

// Lets REAPER show a tick next to the panner actions (action list, toolbars, menus).
static int toggleActionState(int command)
{
  if (command && command == g_cmdPanner) return ASAF_PannerVisible() ? 1 : 0;
  if (command && command == g_cmdDock) return ASAF_PannerVisible() && ASAF_PannerDocked() ? 1 : 0;
  return -1;
}

// ---- Extensions > ASAF menu

static void addMenuItem(HMENU menu, const char *text, int command)
{
  MENUITEMINFO mi = { sizeof(MENUITEMINFO) };
  if (command) { mi.fMask = MIIM_TYPE | MIIM_ID; mi.fType = MFT_STRING; mi.wID = (UINT)command; mi.dwTypeData = (char *)text; }
  else { mi.fMask = MIIM_TYPE; mi.fType = MFT_SEPARATOR; }
  InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &mi);
}

static void addSubmenu(HMENU menu, const char *text, HMENU sub)
{
  MENUITEMINFO mi = { sizeof(MENUITEMINFO) };
  mi.fMask = MIIM_TYPE | MIIM_SUBMENU; mi.fType = MFT_STRING; mi.hSubMenu = sub; mi.dwTypeData = (char *)text;
  InsertMenuItem(menu, GetMenuItemCount(menu), TRUE, &mi);
}

static void menuHook(const char *menuId, HMENU menu, int flag)
{
  DBG("menu hook '%s' flag %d", menuId ? menuId : "(null)", flag);
  if (!menuId || strcmp(menuId, "Main extensions")) return;
  if (flag == 0) { // build
    HMENU asaf = CreatePopupMenu();
    addMenuItem(asaf, "Show panner", g_cmdPanner);
    addMenuItem(asaf, "Dock panner", g_cmdDock);
    addMenuItem(asaf, nullptr, 0);
    addMenuItem(asaf, "Set up session...", g_cmdSetup);
    addMenuItem(asaf, "Export project...", g_cmdExport);
    HMENU tpl = CreatePopupMenu();
    for (int i = 0; i < 4; i++) {
      char text[64]; snprintf(text, sizeof text, "Up to %d objects + 1 scene", kTemplateSizes[i]);
      addMenuItem(tpl, text, g_cmdTemplate[i]);
    }
    addSubmenu(asaf, "New project from template", tpl);
    addSubmenu(menu, "ASAF", asaf);
  } else if (flag == 1) { // about to be shown: update ticks
    CheckMenuItem(menu, g_cmdPanner, MF_BYCOMMAND | (ASAF_PannerVisible() ? MF_CHECKED : MF_UNCHECKED));
    CheckMenuItem(menu, g_cmdDock, MF_BYCOMMAND | (ASAF_PannerVisible() && ASAF_PannerDocked() ? MF_CHECKED : MF_UNCHECKED));
    if (getenv("ASAF_DEBUG")) { // describe what ended up in the menu
      for (int i = 0; i < GetMenuItemCount(menu); i++) {
        char text[128] = ""; MENUITEMINFO mi = { sizeof(MENUITEMINFO) };
        mi.fMask = MIIM_TYPE | MIIM_SUBMENU; mi.dwTypeData = text; mi.cch = sizeof text;
        GetMenuItemInfo(menu, i, TRUE, &mi);
        DBG("Extensions[%d] '%s'%s", i, text, mi.hSubMenu ? " >" : "");
        for (int j = 0; mi.hSubMenu && !strcmp(text, "ASAF") && j < GetMenuItemCount(mi.hSubMenu); j++) {
          char sub[128] = ""; MENUITEMINFO si = { sizeof(MENUITEMINFO) };
          si.fMask = MIIM_TYPE | MIIM_STATE | MIIM_ID | MIIM_SUBMENU; si.dwTypeData = sub; si.cch = sizeof sub;
          GetMenuItemInfo(mi.hSubMenu, j, TRUE, &si);
          DBG("  ASAF[%d] '%s' id=%u%s%s (%d sub-items)", j, sub, si.wID, (si.fState & MFS_CHECKED) ? " [checked]" : "", si.hSubMenu ? " >" : "", si.hSubMenu ? GetMenuItemCount(si.hSubMenu) : 0);
        }
      }
    }
  }
}

static int registerAction(reaper_plugin_info_t *rec, const char *ident, const char *description)
{
  const int cmd = rec->Register("command_id", (void *)ident);
  if (!cmd) return 0;
  gaccel_register_t *accel = new gaccel_register_t(); // must outlive the registration
  accel->accel.cmd = cmd;
  accel->desc = strdup(description);
  rec->Register("gaccel", accel);
  return cmd;
}

extern "C" {
REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
  g_hInst = hInstance;
  if (!rec) { ASAF_ClosePanner(); return 0; } // unloading
  if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
  REAPERAPI_LoadAPI(rec->GetFunc);
  if (!plugin_register || !TrackFX_AddByName || !GetUserInputs || !ShowMessageBox) return 0;

  rec->Register("pcmsink", &g_sinkReg);

  g_cmdSetup = registerAction(rec, "ASAF_SETUP_SESSION", "ASAF: Set up session (object tracks, monitor and export bus)");
  g_cmdExport = registerAction(rec, "ASAF_EXPORT_PROJECT", "ASAF: Export project (ASAF BWF, optionally APAC)");
  g_cmdPanner = registerAction(rec, "ASAF_SHOW_PANNER", "ASAF: Show/hide panner");
  g_cmdDock = registerAction(rec, "ASAF_DOCK_PANNER", "ASAF: Dock/undock panner");
  for (int i = 0; i < 4; i++) {
    static char ident[4][48], desc[4][96];
    snprintf(ident[i], sizeof ident[i], "ASAF_NEW_FROM_TEMPLATE_%d", kTemplateSizes[i]);
    snprintf(desc[i], sizeof desc[i], "ASAF: New project from template (up to %d objects + 1 scene)", kTemplateSizes[i]);
    g_cmdTemplate[i] = registerAction(rec, ident[i], desc[i]);
  }
  rec->Register("hookcommand", (void *)hookCommand);
  rec->Register("toggleaction", (void *)toggleActionState);
  if (AddExtensionsMainMenu) AddExtensionsMainMenu();
  rec->Register("hookcustommenu", (void *)menuHook);

  rec->Register("API_ASAF_SetupSession", (void *)ASAF_SetupSession);
  rec->Register("APIdef_ASAF_SetupSession", (void *)"int\0int\0objectCount\0Creates ASAF object tracks, monitor bus and export bus without showing dialogs. Returns 0 on success.");
  rec->Register("APIvararg_ASAF_SetupSession", (void *)ASAF_SetupSession_vararg);
  rec->Register("API_ASAF_SetupSceneSession", (void *)ASAF_SetupSceneSession);
  rec->Register("APIdef_ASAF_SetupSceneSession", (void *)"int\0int,int\0objectCount,sceneOrder\0As ASAF_SetupSession, with an ambisonic scene track of the given order (0-7) ahead of the objects on the export bus. objectCount may be 0. Returns 0 on success.");
  rec->Register("APIvararg_ASAF_SetupSceneSession", (void *)ASAF_SetupSceneSession_vararg);
  rec->Register("API_ASAF_RenderChannels", (void *)ASAF_RenderChannels);
  rec->Register("APIdef_ASAF_RenderChannels", (void *)"int\0\0\0The number of channels to render the current project's ASAF export with (scene channels + objects + 8 metadata), or 0 if the project has no usable ASAF Export.");
  rec->Register("APIvararg_ASAF_RenderChannels", (void *)ASAF_RenderChannels_vararg);
  rec->Register("API_ASAF_ExportProject", (void *)ASAF_ExportProject);
  rec->Register("APIdef_ASAF_ExportProject", (void *)"int\0const char*,bool\0path,apac\0Renders the project's ASAF export tracks to an ASAF BWF at path (.wav), joining them if there are several (projects made from the templates), and also an APAC .mp4 next to it if apac. Returns 0 on success.");
  rec->Register("APIvararg_ASAF_ExportProject", (void *)ASAF_ExportProject_vararg);
  rec->Register("API_ASAF_AddUnit", (void *)ASAF_AddUnit);
  rec->Register("APIdef_ASAF_AddUnit", (void *)"int\0MediaTrack*,const char*\0track,unitName\0Adds one of the ASAF plug-ins (e.g. \"ASAF Object\") to a track by exact name. Returns the FX index, or -1.");
  rec->Register("APIvararg_ASAF_AddUnit", (void *)ASAF_AddUnit_vararg);
  rec->Register("API_ASAF_ShowEmbeddedUI", (void *)ASAF_ShowEmbeddedUI);
  rec->Register("APIdef_ASAF_ShowEmbeddedUI", (void *)"void\0MediaTrack*\0track\0Shows a track's FX in the track panel and mixer (embedded UI). Reloads the track's FX; call before setting parameters.");
  rec->Register("APIvararg_ASAF_ShowEmbeddedUI", (void *)ASAF_ShowEmbeddedUI_vararg);
  return 1;
}
}
