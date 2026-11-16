// The ASAF panner window: REAPER-side data source for the SwiftUI view, and the window that hosts it.
#import <Cocoa/Cocoa.h>
#include <map>
#include <vector>
#include <array>
#include "reaper_api.h"
#include "swell/swell-dlggen.h"
#import "panner_bridge.h"
#import "ASAFPannerUI-Swift.h"

@implementation ASAFObjectState
@end

namespace {

struct Entry { MediaTrack *track; int fx; NSInteger ident; };

// Parameter indices of ASAF Object (identical for every instance; looked up by name once).
struct ObjectParams { int azimuth = -1, elevation = -1, r = -1, index = -1, enabled = -1, count = 0; bool ok() const { return azimuth >= 0 && elevation >= 0 && r >= 0; } };

} // namespace

@implementation ASAFPannerBridge {
  std::vector<Entry> _entries;
  std::map<std::array<unsigned char, 16>, NSInteger> _idents; // FX GUID -> ident
  NSInteger _nextIdent;
  ObjectParams _p;
}

- (const Entry *)entry:(NSInteger)ident
{
  for (const Entry &e : _entries)
    if (e.ident == ident) return ValidatePtr2(nullptr, e.track, "MediaTrack*") ? &e : nullptr;
  return nullptr;
}

- (NSArray<ASAFObjectState *> *)snapshot
{
  _entries.clear();
  NSMutableArray<ASAFObjectState *> *out = [NSMutableArray array];
  const int ntracks = CountTracks(nullptr);
  for (int t = 0; t < ntracks; t++) {
    MediaTrack *tr = GetTrack(nullptr, t);
    const int nfx = TrackFX_GetCount(tr);
    for (int fx = 0; fx < nfx; fx++) {
      if (fxBaseName(tr, fx) != "ASAF Object") continue;
      const int np = TrackFX_GetNumParams(tr, fx);
      if (!_p.ok() || _p.count != np) {
        _p = ObjectParams();
        _p.count = np;
        _p.azimuth = findFXParam(tr, fx, "azimuth"); _p.elevation = findFXParam(tr, fx, "elevation");
        _p.r = findFXParam(tr, fx, "r"); _p.index = findFXParam(tr, fx, "index"); _p.enabled = findFXParam(tr, fx, "playbackEnabled");
        if (!_p.ok()) continue; // not the shimmed unit (no parameters published)
      }
      std::array<unsigned char, 16> key{};
      if (GUID *g = TrackFX_GetFXGUID(tr, fx)) memcpy(key.data(), g, 16);
      auto it = _idents.find(key);
      if (it == _idents.end()) it = _idents.emplace(key, ++_nextIdent).first;
      _entries.push_back({ tr, fx, it->second });

      ASAFObjectState *s = [ASAFObjectState new];
      s.ident = it->second;
      char name[256] = ""; GetTrackName(tr, name, sizeof name);
      s.name = @(name) ?: @"";
      double mn, mx;
      s.azimuth = TrackFX_GetParam(tr, fx, _p.azimuth, &mn, &mx);
      s.elevation = TrackFX_GetParam(tr, fx, _p.elevation, &mn, &mx);
      s.distance = TrackFX_GetParam(tr, fx, _p.r, &mn, &mx);
      s.objectIndex = _p.index >= 0 ? (NSInteger)lround(TrackFX_GetParam(tr, fx, _p.index, &mn, &mx)) : (NSInteger)out.count;
      s.enabled = _p.enabled < 0 || TrackFX_GetParam(tr, fx, _p.enabled, &mn, &mx) >= 0.5;
      if (int c = GetTrackColor(tr)) {
        int r = 0, g = 0, b = 0; ColorFromNative(c, &r, &g, &b);
        s.hasColor = YES; s.red = r / 255.0; s.green = g / 255.0; s.blue = b / 255.0;
      }
      [out addObject:s];
    }
  }
  return out;
}

- (void)beginEdit:(NSInteger)ident {}

- (void)setAzimuth:(double)azimuth elevation:(double)elevation distance:(double)distance forObject:(NSInteger)ident
{
  const Entry *e = [self entry:ident];
  if (!e || !_p.ok()) return;
  TrackFX_SetParam(e->track, e->fx, _p.azimuth, azimuth);
  TrackFX_SetParam(e->track, e->fx, _p.elevation, elevation);
  TrackFX_SetParam(e->track, e->fx, _p.r, distance);
}

- (void)endEdit:(NSInteger)ident
{
  const Entry *e = [self entry:ident];
  if (!e || !_p.ok()) return;
  for (int p : { _p.azimuth, _p.elevation, _p.r }) TrackFX_EndParamEdit(e->track, e->fx, p);
}

- (void)selectTrack:(NSInteger)ident
{
  if (const Entry *e = [self entry:ident]) SetOnlyTrackSelected(e->track);
}

- (BOOL)docked { return ASAF_PannerDocked(); }

- (void)toggleDock
{
  // Re-docking destroys the window this call came from, so do it after the click has been handled.
  dispatch_async(dispatch_get_main_queue(), ^{ ASAF_SetPannerDocked(!ASAF_PannerDocked()); });
}

@end

// ============================================================================ window

#define IDD_ASAF_PANNER 2100
static HWND g_pannerWnd;
static HINSTANCE g_pannerInst;
static bool g_pannerInDock; // the current window was added to the docker

static const char *kExtSection = "reaper_asaf", *kExtDocked = "panner_docked";

bool ASAF_PannerDocked()
{
  const char *v = GetExtState ? GetExtState(kExtSection, kExtDocked) : nullptr;
  return v && v[0] == '1';
}

static INT_PTR PannerProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
  switch (msg) {
    case WM_INITDIALOG: {
      NSView *parent = (__bridge NSView *)hwnd;
      NSView *host = [ASAFPannerUIFactory makeViewWithBridge:[ASAFPannerBridge new]];
      host.frame = parent.bounds;
      host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      [parent addSubview:host];
      return 0;
    }
    case WM_CLOSE:
      DestroyWindow(hwnd);
      return 0;
    case WM_DESTROY:
      if (g_pannerWnd == hwnd) {
        if (g_pannerInDock && DockWindowRemove) DockWindowRemove(hwnd);
        g_pannerInDock = false;
        g_pannerWnd = nullptr;
      }
      return 0;
  }
  return 0;
}

SWELL_DEFINE_DIALOG_RESOURCE_BEGIN(IDD_ASAF_PANNER, SWELL_DLG_WS_RESIZABLE | SWELL_DLG_WS_FLIPPED, "ASAF Panner", 420, 300, 1.8)
BEGIN
END
SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_ASAF_PANNER)

bool ASAF_PannerVisible() { return g_pannerWnd != nullptr; }

void ASAF_ClosePanner()
{
  if (g_pannerWnd) DestroyWindow(g_pannerWnd);
  g_pannerWnd = nullptr;
}

static void openPanner()
{
  g_pannerWnd = CreateDialogParam(g_pannerInst, MAKEINTRESOURCE(IDD_ASAF_PANNER), GetMainHwnd(), PannerProc, 0);
  if (!g_pannerWnd) return;
  if (ASAF_PannerDocked() && DockWindowAddEx && DockWindowActivate) {
    g_pannerInDock = true;
    DockWindowAddEx(g_pannerWnd, "ASAF Panner", "asaf_panner", true);
    DockWindowActivate(g_pannerWnd);
    // Bring its tab to the front once the docker has settled (activating straight away can be undone
    // when another docked window, e.g. the mixer, is refreshed in the same pass).
    HWND wnd = g_pannerWnd;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      if (g_pannerWnd == wnd && g_pannerInDock) DockWindowActivate(wnd);
    });
  } else {
    ShowWindow(g_pannerWnd, SW_SHOW);
  }
}

void ASAF_TogglePanner(HINSTANCE hInst)
{
  g_pannerInst = hInst;
  if (g_pannerWnd) { ASAF_ClosePanner(); return; }
  openPanner();
}

void ASAF_SetPannerDocked(bool docked)
{
  if (SetExtState) SetExtState(kExtSection, kExtDocked, docked ? "1" : "0", true);
  if (!g_pannerWnd) return;
  ASAF_ClosePanner();
  openPanner();
}

bool ASAF_ChooseExportFile(const char *defaultName, std::string &path, bool &apac)
{
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.title = @"ASAF: Export project";
  panel.allowedFileTypes = @[ @"wav" ];
  panel.nameFieldStringValue = @(defaultName ? defaultName : "ASAF export");
  NSButton *apacBox = [NSButton checkboxWithTitle:@"Also create an APAC file (.mp4)" target:nil action:nil];
  [apacBox sizeToFit];
  panel.accessoryView = apacBox;
  if ([panel runModal] != NSModalResponseOK || !panel.URL) return false;
  path = panel.URL.path.UTF8String;
  apac = apacBox.state == NSControlStateValueOn;
  return true;
}
