// reaper_asaf — ASAF support for REAPER, built on Apple's ASAF AudioUnits (via ASAFShim.component).
//
//  * Render format "ASAF (Apple Spatial Audio Format)": writes the bounce file ASAF Export expects and
//    has ASAF Export convert it to an ASAF BWF when the render finishes.
//  * Action "ASAF: Set up session": creates object tracks, a binaural monitor bus and the export bus.
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
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

class ASAF_Sink : public PCM_sink
{
 public:
  ASAF_Sink(const char *fn, int nch, int srate, bool apac) : m_fn(fn ? fn : ""), m_nch(nch), m_srate(srate), m_apac(apac)
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
    keepBounce(m_fn);
    disarm();
    DBG("finish: blockSizeFixed=%d wrongBlocks=%d lastLen=%d", (int)m_blockSizeFixed, (int)m_wrongBlocks, m_lastLen);
    if (m_problem.empty() && m_blockSizeFixed && m_wrongBlocks)
      m_problem = "This render did not use the 1024-sample block size ASAF needs. The setting "
                  "(Preferences > Audio > Rendering) has now been changed to 1024: render again.";
    if (!m_problem.empty()) { report("The file was rendered but not converted to ASAF.\n\n" + m_problem); return; }
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
  bool m_armed = false, m_finished = false, m_apac = false;
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
static HINSTANCE g_hInst;

static INT_PTR SinkCfgProc(HWND hwndDlg, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
  switch (uMsg) {
    case WM_INITDIALOG:
      CheckDlgButton(hwndDlg, IDC_APAC, ((int)lParam & kFlagAPAC) ? BST_CHECKED : BST_UNCHECKED);
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
  LTEXT "Render the ASAF export bus at 48 kHz: one channel per object,", -1, 4, 19, 292, 10
  LTEXT "then the 8 metadata channels. ASAF Export converts it afterwards.", -1, 4, 30, 292, 10
END
SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_ASAF_CFG)

static PCM_sink *SinkCreate(const char *filename, void *cfg, int cfg_l, int nch, int srate, bool buildpeaks)
{
  DBG("CreateSink cfg_l=%d fourcc=%08x file=%s", cfg_l, cfg_l >= 4 ? *((int *)cfg) : 0, filename ? filename : "(null)");
  if (cfg_l >= 4 && *((int *)cfg) == (int)SINK_FOURCC)
    return new ASAF_Sink(filename, nch, srate, (cfgFlags(cfg, cfg_l) & kFlagAPAC) != 0);
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

// Builds the session. Returns a list of problems (empty if everything was created).
static std::string buildSession(int nobj)
{
  Undo_BeginBlock();
  PreventUIRefresh(1);
  std::string problems;

  // Export bus: object i on channel i, then ASAF Export's 8 metadata channels. Not sent to the master.
  const int busCh = nobj + kMetadataChannels, busChEven = (busCh + 1) & ~1;
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
      if (p < kMetadataChannels) mapOutputPin(bus, exFx, p, nobj + p);
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
    monoSend(tr, bus, i);
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
  char val[64] = "16";
  if (!GetUserInputs("ASAF: Set up session", 1, "Number of objects (1-120):", val, sizeof val)) return;
  int nobj = atoi(val);
  if (nobj < 1 || nobj > kMaxObjects) { report("Enter a number of objects between 1 and 120."); return; }
  std::string problems = buildSession(nobj);
  std::string msg =
      "Created " + std::to_string(nobj) + " object tracks, the monitor bus and \"ASAF Export Bus\".\n\n"
      "To export, open File > Render and set:\n"
      "  Source:  Selected tracks (stems), with \"ASAF Export Bus\" selected\n"
      "  Sample rate:  48000 Hz\n"
      "  Channels:  " + std::to_string(nobj + kMetadataChannels) + "\n"
      "  Format:  ASAF (Apple Spatial Audio Format)\n\n"
      "Position objects with the parameters of ASAF Object on each track.";
  if (!problems.empty()) msg += "\n\nProblems:\n" + problems;
  report(msg);
}

// ReaScript: integer ASAF_SetupSession(integer objectCount) -- no dialogs; returns 0 on success.
static int ASAF_SetupSession(int nobj)
{
  if (nobj < 1 || nobj > kMaxObjects) return -1;
  std::string problems = buildSession(nobj);
  if (problems.empty()) return 0;
  if (ShowConsoleMsg) ShowConsoleMsg(("ASAF: Set up session reported problems:\n" + problems).c_str());
  return 1;
}
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

// ============================================================================ entry point

static int g_cmdSetup = 0, g_cmdPanner = 0, g_cmdDock = 0;

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
  rec->Register("API_ASAF_AddUnit", (void *)ASAF_AddUnit);
  rec->Register("APIdef_ASAF_AddUnit", (void *)"int\0MediaTrack*,const char*\0track,unitName\0Adds one of the ASAF plug-ins (e.g. \"ASAF Object\") to a track by exact name. Returns the FX index, or -1.");
  rec->Register("APIvararg_ASAF_AddUnit", (void *)ASAF_AddUnit_vararg);
  rec->Register("API_ASAF_ShowEmbeddedUI", (void *)ASAF_ShowEmbeddedUI);
  rec->Register("APIdef_ASAF_ShowEmbeddedUI", (void *)"void\0MediaTrack*\0track\0Shows a track's FX in the track panel and mixer (embedded UI). Reloads the track's FX; call before setting parameters.");
  rec->Register("APIvararg_ASAF_ShowEmbeddedUI", (void *)ASAF_ShowEmbeddedUI_vararg);
  return 1;
}
}
