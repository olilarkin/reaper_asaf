// "ASAF Video Overlay": a REAPER video processor, delivered as a CLAP plug-in, that draws an
// equirectangular grid and a marker for every ASAF Object in the project over the video.
//
// Azimuth runs from +180 (left edge) through 0 (centre) to -180 (right edge), because positive azimuth
// is to the listener's left; elevation from +90 (top) to -90 (bottom).
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#include <clap/clap.h>
#include <atomic>
#include <cmath>
#include <map>
#include <mutex>
#include <memory>
#include <functional>
#include "marks.h"
#include "reaper_plugin.h"      // reaper_plugin_info_t
#include "wdltypes.h"           // WDL_FIXALIGN, used by video_frame.h
#include "video_processor.h"    // IREAPERVideoProcessor, IVideoFrame
#undef min
#undef max

// ============================================================================ shared object positions

namespace asaf {
static std::mutex gMarkLock;
static std::map<const void *, ObjectMark> &markMap() { static std::map<const void *, ObjectMark> m; return m; }

void publishMark(const void *owner, const ObjectMark &mark) { std::lock_guard<std::mutex> l(gMarkLock); markMap()[owner] = mark; }
void removeMark(const void *owner) { std::lock_guard<std::mutex> l(gMarkLock); markMap().erase(owner); }
std::vector<ObjectMark> currentMarks()
{
  std::vector<ObjectMark> v;
  { std::lock_guard<std::mutex> l(gMarkLock); for (auto &kv : markMap()) v.push_back(kv.second); }
  std::sort(v.begin(), v.end(), [](const ObjectMark &a, const ObjectMark &b) { return a.index < b.index; });
  return v;
}
} // namespace asaf

// ============================================================================ plug-in

enum { kGrid, kLabels, kMarkerSize, kDim, kRefresh, kNumParams };
static const struct { const char *name; double min, max, def; bool stepped; } kParamInfo[kNumParams] = {
  { "Grid", 0, 1, 1, true }, { "Labels", 0, 1, 1, true }, { "Marker Size", 0.5, 3, 1, false }, { "Dim Video", 0, 1, 0, false },
  // Not a user control: the plug-in steps this whenever an object moves, because REAPER only redraws a
  // (stopped) video frame when one of the video processor's own parameters changes.
  { "Objects Changed", 0, 255, 0, true } };

struct VideoPlugin {
  clap_plugin_t clap;
  const clap_host_t *host;
  IREAPERVideoProcessor *video = nullptr;
  std::atomic<double> values[kNumParams];
  const clap_host_params_t *hostParams = nullptr;
  dispatch_source_t timer = nullptr;
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);
  uint64_t lastHash = 0;
  std::atomic<bool> refreshPending{false};
};
static VideoPlugin *vself(const clap_plugin_t *p) { return (VideoPlugin *)p->plugin_data; }

// ---- drawing

static void drawText(CGContextRef cg, NSString *text, CGFloat x, CGFloat y, CGFloat size, CGColorRef color, bool bold, int align /* -1 left, 0 centre */)
{
  CTFontRef font = CTFontCreateUIFontForLanguage(bold ? kCTFontUIFontEmphasizedSystem : kCTFontUIFontSystem, size, nullptr);
  NSDictionary *attrs = @{ (id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorAttributeName: (__bridge id)color };
  CFAttributedStringRef as = CFAttributedStringCreate(nullptr, (__bridge CFStringRef)text, (__bridge CFDictionaryRef)attrs);
  CTLineRef line = CTLineCreateWithAttributedString(as);
  const double width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
  CGContextSetTextPosition(cg, align == 0 ? x - width / 2 : x, y);
  CTLineDraw(line, cg);
  CFRelease(line); CFRelease(as); CFRelease(font);
}

// Draws into an RGBA frame. Coordinates below are y-down (0 = top of picture).
static void drawOverlay(IVideoFrame *frame, bool grid, bool labels, double markerScale, double dim)
{
  const int w = frame->get_w(), h = frame->get_h();
  if (w < 16 || h < 16 || !frame->get_bits()) return;
  // REAPER's 'RGBA' frames use LICE's pixel layout: B,G,R,A in memory on little-endian Macs.
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef cg = CGBitmapContextCreate(frame->get_bits(), w, h, 8, frame->get_rowspan(), cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(cs);
  if (!cg) return;
  CGContextTranslateCTM(cg, 0, h); CGContextScaleCTM(cg, 1, -1);      // y-down for geometry
  const CGFloat u = h / 540.0;                                       // one "point" at 540 lines
  auto X = [&](double az) { return (CGFloat)(w * (0.5 - az / 360.0)); };
  auto Y = [&](double el) { return (CGFloat)(h * (0.5 - el / 180.0)); };
  auto text = [&](NSString *s, CGFloat x, CGFloat y, CGFloat size, CGColorRef c, bool bold, int align) {
    CGContextSaveGState(cg); CGContextTranslateCTM(cg, 0, y); CGContextScaleCTM(cg, 1, -1);   // text must be drawn y-up
    drawText(cg, s, x, 0, size, c, bold, align);
    CGContextRestoreGState(cg);
  };

  if (dim > 0.001) { CGContextSetRGBFillColor(cg, 0, 0, 0, std::min(1.0, dim)); CGContextFillRect(cg, CGRectMake(0, 0, w, h)); }

  if (grid) {
    CGColorRef amber = CGColorCreateGenericRGB(0.96, 0.66, 0.35, 1);
    for (int az = -180; az <= 180; az += 45) {
      CGContextSetRGBStrokeColor(cg, 1, 1, 1, az == 0 ? 0.75 : 0.45); CGContextSetLineWidth(cg, std::max<CGFloat>(1, u * (az == 0 ? 1.2 : 0.8)));
      CGContextMoveToPoint(cg, X(az), 0); CGContextAddLineToPoint(cg, X(az), h); CGContextStrokePath(cg);
      if (az != -180) text([NSString stringWithFormat:@"%d", az], X(az) + 3 * u, Y(0) + 13 * u, 11 * u, amber, false, -1);
    }
    for (int el = -90; el <= 90; el += 45) {
      CGContextSetRGBStrokeColor(cg, el == 0 ? 0.96 : 1, el == 0 ? 0.72 : 1, el == 0 ? 0.6 : 1, el == 0 ? 0.9 : 0.45); CGContextSetLineWidth(cg, std::max<CGFloat>(1, u * (el == 0 ? 1.2 : 0.8)));
      CGContextMoveToPoint(cg, 0, Y(el)); CGContextAddLineToPoint(cg, w, Y(el)); CGContextStrokePath(cg);
      if (el != 0 && el != -90) text([NSString stringWithFormat:@"%d", el], X(0) + 3 * u, Y(el) + 13 * u, 11 * u, amber, false, -1);
    }
    CGColorRelease(amber);
  }

  CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
  for (const asaf::ObjectMark &m : asaf::currentMarks()) {
    if (!m.enabled) continue;
    const CGFloat x = X(m.azimuth), y = Y(m.elevation), arm = 22 * u * markerScale;
    const CGFloat r = ((m.color >> 16) & 0xff) / 255.0, g = ((m.color >> 8) & 0xff) / 255.0, b = (m.color & 0xff) / 255.0;
    for (int pass = 0; pass < 2; pass++) { // dark outline, then the colour
      if (pass == 0) CGContextSetRGBStrokeColor(cg, 0, 0, 0, 0.6); else CGContextSetRGBStrokeColor(cg, r, g, b, 1);
      CGContextSetLineWidth(cg, std::max<CGFloat>(1.5, u * markerScale * (pass == 0 ? 4.5 : 2.5)));
      CGContextMoveToPoint(cg, x - arm, y); CGContextAddLineToPoint(cg, x + arm, y);
      CGContextMoveToPoint(cg, x, y - arm); CGContextAddLineToPoint(cg, x, y + arm);
      CGContextStrokePath(cg);
    }
    if (labels) {
      NSString *name = m.name.empty() ? [NSString stringWithFormat:@"Object %d", m.index + 1] : @(m.name.c_str());
      NSString *pos = [NSString stringWithFormat:@"(%.2fm, %d°, %d°)", m.distance, (int)std::lround(m.azimuth), (int)std::lround(m.elevation)];
      const CGFloat size = 13 * u * std::min(1.6, std::max(0.8, markerScale));
      CGContextSetShadowWithColor(cg, CGSizeMake(0, 0), 3 * u, CGColorGetConstantColor(kCGColorBlack));
      text(name ?: @"", x, y + arm + size * 1.5, size, white, true, 0);
      text(pos, x, y + arm + size * 2.8, size, white, true, 0);
      CGContextSetShadowWithColor(cg, CGSizeZero, 0, nullptr);
    }
  }
  CGColorRelease(white);
  CGContextRelease(cg);
}

static IVideoFrame *processFrame(IREAPERVideoProcessor *vproc, const double *, int, double, double, int)
{
  VideoPlugin *pl = (VideoPlugin *)vproc->userdata;
  // Input frames are immutable: draw on a copy. With no video underneath, draw on black (2:1, like an
  // equirectangular picture).
  IVideoFrame *in = vproc->getNumInputs() > 0 ? vproc->renderInputVideoFrame(0, 'RGBA') : nullptr;
  const int w = in ? in->get_w() : 1920, h = in ? in->get_h() : 960;
  IVideoFrame *out = vproc->newVideoFrame(w, h, 'RGBA');
  if (!out) return in;
  if (in && in->get_bits() && out->get_bits() && in->get_w() == out->get_w() && in->get_h() == out->get_h()) {
    const int rowBytes = std::min(in->get_rowspan(), out->get_rowspan());
    for (int y = 0; y < h; y++) memcpy(out->get_bits() + (size_t)y * out->get_rowspan(), in->get_bits() + (size_t)y * in->get_rowspan(), (size_t)rowBytes);
  } else if (out->get_bits()) {
    for (int y = 0; y < out->get_h(); y++) {
      uint32_t *row = (uint32_t *)(out->get_bits() + (size_t)y * out->get_rowspan());
      for (int x = 0; x < out->get_w(); x++) row[x] = 0xFF000000; // opaque black
    }
  }
  if (in) { out->time_start = in->time_start; out->time_end = in->time_end; in->Release(); }
  @autoreleasepool {
    drawOverlay(out, pl->values[kGrid].load() >= 0.5, pl->values[kLabels].load() >= 0.5, pl->values[kMarkerSize].load(), pl->values[kDim].load());
  }
  return out;
}

static bool getVideoParam(IREAPERVideoProcessor *vproc, int idx, double *v)
{
  VideoPlugin *pl = (VideoPlugin *)vproc->userdata;
  if (idx < 0 || idx >= kNumParams) return false;
  *v = pl->values[idx].load();
  return true;
}

// ---- CLAP

static uint64_t marksHash()
{
  uint64_t h = 1469598103934665603ull;
  auto mix = [&](uint64_t v) { h ^= v; h *= 1099511628211ull; };
  for (const asaf::ObjectMark &m : asaf::currentMarks()) {
    mix((uint64_t)m.index); mix((uint64_t)std::llround(m.azimuth * 20)); mix((uint64_t)std::llround(m.elevation * 20)); mix((uint64_t)std::llround(m.distance * 100));
    mix(m.enabled); mix(m.color); mix(std::hash<std::string>()(m.name));
  }
  return h;
}

static void vEmit(VideoPlugin *pl, const clap_output_events_t *out)
{
  if (!out || !pl->refreshPending.exchange(false)) return;
  clap_event_param_value_t ev = {};
  ev.header = { sizeof ev, 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0 };
  ev.param_id = kRefresh; ev.note_id = -1; ev.port_index = -1; ev.channel = -1; ev.key = -1; ev.value = pl->values[kRefresh].load();
  out->try_push(out, &ev.header);
}

static bool vInit(const clap_plugin_t *p)
{
  VideoPlugin *pl = vself(p);
  pl->hostParams = (const clap_host_params_t *)pl->host->get_extension(pl->host, CLAP_EXT_PARAMS);
  std::shared_ptr<bool> alive = pl->alive;
  pl->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(pl->timer, dispatch_time(DISPATCH_TIME_NOW, 0), 40 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(pl->timer, ^{
    if (!*alive) return;
    const uint64_t h = marksHash();
    if (h == pl->lastHash) return;
    pl->lastHash = h;
    pl->values[kRefresh].store(std::fmod(pl->values[kRefresh].load() + 1, 256));
    pl->refreshPending.store(true);
    if (pl->hostParams && pl->hostParams->request_flush) pl->hostParams->request_flush(pl->host);
  });
  dispatch_resume(pl->timer);
  // REAPER hands CLAP plug-ins its API through a host extension (see reaper_plugin.h).
  const reaper_plugin_info_t *rec = (const reaper_plugin_info_t *)pl->host->get_extension(pl->host, "cockos.reaper_extension");
  if (!rec || !rec->GetFunc) { NSLog(@"ASAF Video Overlay: this host is not REAPER; the plug-in will do nothing."); return true; }
  void *(*getContext)(const clap_host_t *, int) = (void *(*)(const clap_host_t *, int))rec->GetFunc("clap_get_reaper_context");
  IREAPERVideoProcessor *(*create)(void *, int) = (IREAPERVideoProcessor *(*)(void *, int))rec->GetFunc("video_CreateVideoProcessor");
  void *ctx = getContext ? getContext(pl->host, 4) : nullptr; // 4 = the FX's DSP context
  if (!create || !ctx) { NSLog(@"ASAF Video Overlay: REAPER's video processor API is not available."); return true; }
  pl->video = create(ctx, IREAPERVideoProcessor::REAPER_VIDEO_PROCESSOR_VERSION);
  if (pl->video) { pl->video->userdata = pl; pl->video->process_frame = processFrame; pl->video->get_parameter_value = getVideoParam; }
  return true;
}

static void vDestroy(const clap_plugin_t *p)
{
  VideoPlugin *pl = vself(p);
  *pl->alive = false;
  if (pl->timer) dispatch_source_cancel(pl->timer);
  delete pl->video;
  delete pl;
}
static bool vActivate(const clap_plugin_t *, double, uint32_t, uint32_t) { return true; }
static void vDeactivate(const clap_plugin_t *) {}
static bool vStart(const clap_plugin_t *) { return true; }
static void vStop(const clap_plugin_t *) {}
static void vReset(const clap_plugin_t *) {}
static void vOnMain(const clap_plugin_t *) {}

static void vReadEvents(VideoPlugin *pl, const clap_input_events_t *in)
{
  for (uint32_t i = 0, n = in ? in->size(in) : 0; i < n; i++) {
    const clap_event_header_t *h = in->get(in, i);
    if (h->space_id != CLAP_CORE_EVENT_SPACE_ID || h->type != CLAP_EVENT_PARAM_VALUE) continue;
    const clap_event_param_value_t *ev = (const clap_event_param_value_t *)h;
    if (ev->param_id < kNumParams) pl->values[ev->param_id].store(std::min(kParamInfo[ev->param_id].max, std::max(kParamInfo[ev->param_id].min, ev->value)));
  }
}

static clap_process_status vProcess(const clap_plugin_t *p, const clap_process_t *proc)
{
  vReadEvents(vself(p), proc->in_events);
  vEmit(vself(p), proc->out_events);
  if (proc->audio_inputs_count && proc->audio_outputs_count) { // audio passes straight through
    const clap_audio_buffer_t &in = proc->audio_inputs[0], &out = proc->audio_outputs[0];
    for (uint32_t c = 0; c < out.channel_count; c++) {
      if (!out.data32 || !out.data32[c]) continue;
      if (in.data32 && c < in.channel_count && in.data32[c]) { if (in.data32[c] != out.data32[c]) memcpy(out.data32[c], in.data32[c], proc->frames_count * sizeof(float)); }
      else memset(out.data32[c], 0, proc->frames_count * sizeof(float));
    }
  }
  return CLAP_PROCESS_CONTINUE;
}

static uint32_t vParamsCount(const clap_plugin_t *) { return kNumParams; }
static bool vParamsInfo(const clap_plugin_t *, uint32_t i, clap_param_info_t *info)
{
  if (i >= kNumParams) return false;
  *info = {}; info->id = i;
  info->flags = (i == kRefresh ? CLAP_PARAM_IS_READONLY : CLAP_PARAM_IS_AUTOMATABLE) | (kParamInfo[i].stepped ? CLAP_PARAM_IS_STEPPED : 0);
  snprintf(info->name, sizeof info->name, "%s", kParamInfo[i].name);
  info->min_value = kParamInfo[i].min; info->max_value = kParamInfo[i].max; info->default_value = kParamInfo[i].def;
  return true;
}
static bool vParamsValue(const clap_plugin_t *p, clap_id id, double *v) { if (id >= kNumParams) return false; *v = vself(p)->values[id].load(); return true; }
static bool vParamsText(const clap_plugin_t *, clap_id id, double v, char *buf, uint32_t cap)
{
  if (id >= kNumParams) return false;
  if (id == kRefresh) snprintf(buf, cap, "%d", (int)v);
  else if (kParamInfo[id].stepped) snprintf(buf, cap, "%s", v >= 0.5 ? "On" : "Off"); else snprintf(buf, cap, "%.2f", v);
  return true;
}
static bool vParamsFromText(const clap_plugin_t *, clap_id, const char *text, double *out)
{
  if (!strcasecmp(text, "on")) { *out = 1; return true; }
  if (!strcasecmp(text, "off")) { *out = 0; return true; }
  char *end = nullptr; *out = strtod(text, &end); return end != text;
}
static void vParamsFlush(const clap_plugin_t *p, const clap_input_events_t *in, const clap_output_events_t *out) { vReadEvents(vself(p), in); vEmit(vself(p), out); }
static const clap_plugin_params_t kVParams = { vParamsCount, vParamsInfo, vParamsValue, vParamsText, vParamsFromText, vParamsFlush };

static uint32_t vPortsCount(const clap_plugin_t *, bool) { return 1; }
static bool vPortsGet(const clap_plugin_t *, uint32_t index, bool isInput, clap_audio_port_info_t *info)
{
  if (index) return false;
  *info = {}; info->id = isInput ? 1 : 2; snprintf(info->name, sizeof info->name, "%s", isInput ? "Input" : "Output");
  info->channel_count = 2; info->flags = CLAP_AUDIO_PORT_IS_MAIN; info->port_type = CLAP_PORT_STEREO; info->in_place_pair = isInput ? 2 : 1;
  return true;
}
static const clap_plugin_audio_ports_t kVPorts = { vPortsCount, vPortsGet };

static bool vStateSave(const clap_plugin_t *p, const clap_ostream_t *s)
{
  double v[kNumParams]; for (int i = 0; i < kNumParams; i++) v[i] = vself(p)->values[i].load();
  return s->write(s, v, sizeof v) == (int64_t)sizeof v;
}
static bool vStateLoad(const clap_plugin_t *p, const clap_istream_t *s)
{
  double v[kNumParams]; size_t got = 0;
  while (got < sizeof v) { const int64_t n = s->read(s, (char *)v + got, sizeof v - got); if (n <= 0) break; got += (size_t)n; }
  for (size_t i = 0; i < got / sizeof(double) && i < kNumParams; i++) vself(p)->values[i].store(std::min(kParamInfo[i].max, std::max(kParamInfo[i].min, v[i])));
  return got >= sizeof(double);
}
static const clap_plugin_state_t kVState = { vStateSave, vStateLoad };

static const void *vExtension(const clap_plugin_t *, const char *id)
{
  if (!strcmp(id, CLAP_EXT_PARAMS)) return &kVParams;
  if (!strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &kVPorts;
  if (!strcmp(id, CLAP_EXT_STATE)) return &kVState;
  return nullptr;
}

const clap_plugin_descriptor_t *videoOverlayDescriptor()
{
  static const char *const features[] = { CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, CLAP_PLUGIN_FEATURE_UTILITY, nullptr };
  static const clap_plugin_descriptor_t d = { CLAP_VERSION_INIT, "com.asafbridge.video-overlay", "ASAF Video Overlay", "ASAF Bridge", "", "", "", "0.1.0",
    "REAPER video processor: draws the project's ASAF object positions over an equirectangular video", features };
  return &d;
}

const clap_plugin_t *videoOverlayCreate(const clap_host_t *host)
{
  VideoPlugin *pl = new VideoPlugin();
  pl->host = host;
  for (int i = 0; i < kNumParams; i++) pl->values[i].store(kParamInfo[i].def);
  pl->clap = {};
  pl->clap.desc = videoOverlayDescriptor(); pl->clap.plugin_data = pl;
  pl->clap.init = vInit; pl->clap.destroy = vDestroy; pl->clap.activate = vActivate; pl->clap.deactivate = vDeactivate;
  pl->clap.start_processing = vStart; pl->clap.stop_processing = vStop; pl->clap.reset = vReset; pl->clap.process = vProcess;
  pl->clap.get_extension = vExtension; pl->clap.on_main_thread = vOnMain;
  return &pl->clap;
}
