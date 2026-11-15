// ASAF.clap — Apple's ASAF AudioUnits as CLAP plug-ins, with SwiftUI editors.
#import <Cocoa/Cocoa.h>
#include <clap/clap.h>
#include <regex>
#include "unit.h"
#include "embed.h"
#include "marks.h"
#include "../reaper_asaf/asaf_core.h"
#import "ui_bridge.h"
#import "ASAFClapUI-Swift.h"

using asaf::Unit;
using asaf::UnitDesc;

// ============================================================================ names

// "object12azimuth" -> group "Object 13", name "Azimuth"; "roomSimulationLateReverb" -> "Room Simulation Late Reverb"
static void displayName(const std::string &ident, std::string &name, std::string &group)
{
  static const std::regex indexed("^(object|chanBed|HOA|filter|input)([0-9]+)(.+)$");
  std::string rest = ident; group.clear();
  std::smatch m;
  if (std::regex_match(ident, m, indexed)) {
    const std::string kind = m[1];
    group = (kind == "object" ? "Object " : kind == "chanBed" ? "Channel Bed " : kind == "HOA" ? "Scene " : kind == "filter" ? "Filter " : "Input ")
          + std::to_string(std::stoi(m[2]) + 1);
    rest = m[3];
  }
  if (rest == "r") { name = "Distance"; return; }
  if (rest == "rOffset") { name = "Distance Offset"; return; }
  name.clear();
  for (size_t i = 0; i < rest.size(); i++) {
    const char c = rest[i];
    const bool upper = c >= 'A' && c <= 'Z';
    const bool prevLower = i > 0 && rest[i - 1] >= 'a' && rest[i - 1] <= 'z';
    const bool nextLower = i + 1 < rest.size() && rest[i + 1] >= 'a' && rest[i + 1] <= 'z';
    if (i > 0 && upper && (prevLower || nextLower)) name += ' ';
    name += (i == 0 && c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
  }
}

// ============================================================================ UI bridge

@implementation ASAFParamInfo
@end

@implementation ASAFUnitBridge {
  Unit *_unit;
  NSArray<ASAFParamInfo *> *_params;
  uint32_t (^_color)(void);
}

- (instancetype)initWithUnit:(Unit *)unit color:(uint32_t (^)(void))color
{
  if ((self = [super init])) {
    _unit = unit;
    _color = [color copy];
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < unit->paramCount(); i++) {
      const asaf::ParamDef &d = unit->paramDef(i);
      std::string name, group; displayName(d.ident, name, group);
      ASAFParamInfo *p = [ASAFParamInfo new];
      p.ident = @(d.ident.c_str()); p.name = @(name.c_str()); p.group = @(group.c_str());
      p.minValue = d.min; p.maxValue = d.max; p.defaultValue = d.def; p.stepped = d.stepped; p.readOnly = d.readOnly;
      NSMutableArray<NSString *> *labels = [NSMutableArray array];
      for (const std::string &s : unit->valueLabels(i)) [labels addObject:@(s.c_str()) ?: @""];
      p.labels = labels;
      [a addObject:p];
    }
    _params = a;
  }
  return self;
}

- (void)invalidate { _unit = nullptr; _color = nil; }
- (NSInteger)puckRGB { return _color ? _color() : 0xF09632; }

- (NSString *)unitName { return _unit ? @(_unit->desc().name) : @""; }
- (NSString *)kind
{
  if (!_unit) return @"";
  const uint32_t s = _unit->desc().subType;
  const char cc[5] = { (char)(s >> 24), (char)(s >> 16), (char)(s >> 8), (char)s, 0 };
  return @(cc);
}
- (NSArray<ASAFParamInfo *> *)parameters { return _params; }
- (NSInteger)indexOf:(NSString *)ident { return _unit ? _unit->paramIndex(ident.UTF8String) : -1; }
- (double)valueAt:(NSInteger)index { return (_unit && index >= 0 && index < _unit->paramCount()) ? _unit->value((int)index) : 0; }
- (void)setValue:(double)value at:(NSInteger)index { if (_unit) _unit->setFromUI((int)index, value); }
- (void)beginGesture:(NSInteger)index { if (_unit) _unit->gesture((int)index, true); }
- (void)endGesture:(NSInteger)index { if (_unit) _unit->gesture((int)index, false); }

- (NSString *)convertFile:(NSString *)path createAPAC:(BOOL)apac
{
  if (!_unit) return @"The plug-in was closed.";
  std::string err, apacErr;
  const bool ok = apac ? asaf::convertBounceToASAFAndAPAC(path.fileSystemRepresentation, &err, &apacErr)
                       : asaf::convertBounceToASAF(path.fileSystemRepresentation, &err);
  if (!ok) return @(err.c_str());
  if (!apacErr.empty()) return [@"The ASAF BWF was written, but the APAC file was not. " stringByAppendingString:@(apacErr.c_str())];
  return nil;
}

@end

// ============================================================================ plug-in

struct Plugin {
  clap_plugin_t clap;
  const clap_host_t *host;
  const clap_host_params_t *hostParams = nullptr;
  Unit unit;
  dispatch_source_t timer = nullptr;
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);
  ASAFUnitBridge *bridge = nil;
  NSView *view = nil;
  asaf::EmbedState embed;
  unsigned flushTick = 0;
  const clap_host_track_info_t *hostTrack = nullptr;
  bool hasTrackColor = false;
  uint32_t trackColor = 0; // 0xRRGGBB
  std::string trackName;

  Plugin(const clap_plugin_descriptor_t *desc, const clap_host_t *h, const UnitDesc &u);
};

static Plugin *self(const clap_plugin_t *p) { return (Plugin *)p->plugin_data; }

// ---- track colour (for the pucks)

// REAPER's API as handed to CLAP plug-ins (host extension "cockos.reaper_extension"; this mirrors the
// start of reaper_plugin_info_t in REAPER's SDK).
struct ReaperPluginInfo { int callerVersion; void *mainWindow; int (*Register)(const char *, void *); void *(*GetFunc)(const char *); };

static void updateTrackInfo(Plugin *pl)
{
  clap_track_info_t info = {};
  pl->hasTrackColor = false;
  const bool got = pl->hostTrack && pl->hostTrack->get && pl->hostTrack->get(pl->host, &info);
  if (got) pl->trackName = (info.flags & CLAP_TRACK_INFO_HAS_TRACK_NAME) ? info.name : "";

  // In REAPER, ask it directly: the CLAP track info reports the theme's default colour for tracks the
  // user hasn't coloured, and we want those to fall back to our own palette.
  static const ReaperPluginInfo *reaper = (const ReaperPluginInfo *)pl->host->get_extension(pl->host, "cockos.reaper_extension");
  if (reaper && reaper->GetFunc) {
    static void *(*context)(const clap_host_t *, int) = (void *(*)(const clap_host_t *, int))reaper->GetFunc("clap_get_reaper_context");
    static int (*trackColor)(void *) = (int (*)(void *))reaper->GetFunc("GetTrackColor");
    static void (*fromNative)(int, int *, int *, int *) = (void (*)(int, int *, int *, int *))reaper->GetFunc("ColorFromNative");
    void *track = context ? context(pl->host, 1) : nullptr;
    if (track && trackColor && fromNative) {
      if (const int c = trackColor(track)) {
        int r = 0, g = 0, b = 0; fromNative(c, &r, &g, &b);
        pl->hasTrackColor = true;
        pl->trackColor = ((uint32_t)(r & 0xff) << 16) | ((uint32_t)(g & 0xff) << 8) | (uint32_t)(b & 0xff);
      }
      return;
    }
  }
  if (got && (info.flags & CLAP_TRACK_INFO_HAS_TRACK_COLOR)) {
    pl->hasTrackColor = true;
    pl->trackColor = ((uint32_t)info.color.red << 16) | ((uint32_t)info.color.green << 8) | info.color.blue;
  }
}

static uint32_t puckColor(Plugin *pl)
{
  if (pl->hasTrackColor) return pl->trackColor;
  const int i = pl->unit.paramIndex("index");
  return asaf::paletteColor(i >= 0 ? (int)std::lround(pl->unit.value(i)) : 0);
}

// ASAF Object: tell the video overlay where this object is.
static void publishObjectMark(Plugin *pl)
{
  Unit &u = pl->unit;
  if (u.desc().subType != 'Objt' || u.paramCount() == 0) return;
  static int az = -2, el, dist, index, enabled; // same for every ASAF Object
  if (az == -2) { az = u.paramIndex("azimuth"); el = u.paramIndex("elevation"); dist = u.paramIndex("r"); index = u.paramIndex("index"); enabled = u.paramIndex("playbackEnabled"); }
  if (az < 0 || el < 0 || dist < 0) return;
  asaf::ObjectMark m;
  m.azimuth = u.value(az); m.elevation = u.value(el); m.distance = u.value(dist);
  m.index = index >= 0 ? (int)std::lround(u.value(index)) : 0;
  m.enabled = enabled < 0 || u.value(enabled) >= 0.5;
  m.color = puckColor(pl); m.name = pl->trackName;
  asaf::publishMark(pl, m);
}

static void trackInfoChanged(const clap_plugin_t *p) { updateTrackInfo(self(p)); }
static const clap_plugin_track_info_t kTrackInfo = { trackInfoChanged };

// ---- parameters

static void emitToHost(Plugin *pl, const clap_output_events_t *out)
{
  if (!out) return;
  pl->unit.drainToHost([&](int index, int kind, double value) {
    const clap_id pid = pl->unit.paramDef(index).hash;
    if (kind == 0) {
      clap_event_param_value_t ev = {};
      ev.header = { sizeof ev, 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0 };
      ev.param_id = pid; ev.cookie = (void *)(intptr_t)(index + 1);
      ev.note_id = -1; ev.port_index = -1; ev.channel = -1; ev.key = -1; ev.value = value;
      out->try_push(out, &ev.header);
    } else {
      clap_event_param_gesture_t ev = {};
      ev.header = { sizeof ev, 0, CLAP_CORE_EVENT_SPACE_ID, (uint16_t)(kind == 1 ? CLAP_EVENT_PARAM_GESTURE_BEGIN : CLAP_EVENT_PARAM_GESTURE_END), 0 };
      ev.param_id = pid;
      out->try_push(out, &ev.header);
    }
  });
}

static void readFromHost(Plugin *pl, const clap_input_events_t *in)
{
  if (!in) return;
  const uint32_t n = in->size(in);
  for (uint32_t i = 0; i < n; i++) {
    const clap_event_header_t *h = in->get(in, i);
    if (h->space_id != CLAP_CORE_EVENT_SPACE_ID || h->type != CLAP_EVENT_PARAM_VALUE) continue;
    const clap_event_param_value_t *ev = (const clap_event_param_value_t *)h;
    int index = (int)(intptr_t)ev->cookie - 1;
    if (index < 0 || index >= pl->unit.paramCount() || pl->unit.paramDef(index).hash != ev->param_id)
      index = pl->unit.paramIndexForHash(ev->param_id);
    if (getenv("ASAF_CLAP_DEBUG")) NSLog(@"ASAF.clap %p: host set param %d (%s) = %g", pl, index, index >= 0 ? pl->unit.paramDef(index).ident.c_str() : "?", ev->value);
    pl->unit.setFromHost(index, ev->value);
  }
}

static uint32_t paramsCount(const clap_plugin_t *p) { return (uint32_t)self(p)->unit.paramCount(); }

static bool paramsGetInfo(const clap_plugin_t *p, uint32_t index, clap_param_info_t *info)
{
  Unit &u = self(p)->unit;
  if ((int)index >= u.paramCount()) return false;
  const asaf::ParamDef &d = u.paramDef((int)index);
  *info = {};
  info->id = d.hash;
  info->flags = d.readOnly ? CLAP_PARAM_IS_READONLY : CLAP_PARAM_IS_AUTOMATABLE;
  if (d.stepped) info->flags |= CLAP_PARAM_IS_STEPPED;
  info->cookie = (void *)(intptr_t)(index + 1);
  std::string name, group; displayName(d.ident, name, group);
  snprintf(info->name, sizeof info->name, "%s", name.c_str());
  snprintf(info->module, sizeof info->module, "%s", group.c_str());
  info->min_value = d.min; info->max_value = d.max;
  info->default_value = std::min(d.max, std::max(d.min, d.def));
  return true;
}

static bool paramsGetValue(const clap_plugin_t *p, clap_id id, double *out)
{
  Unit &u = self(p)->unit;
  const int i = u.paramIndexForHash(id);
  if (i < 0) return false;
  *out = u.value(i);
  return true;
}

static bool paramsValueToText(const clap_plugin_t *p, clap_id id, double value, char *buf, uint32_t cap)
{
  Unit &u = self(p)->unit;
  const int i = u.paramIndexForHash(id);
  if (i < 0) return false;
  snprintf(buf, cap, "%s", u.valueText(i, value).c_str());
  return true;
}

static bool paramsTextToValue(const clap_plugin_t *p, clap_id id, const char *text, double *out)
{
  Unit &u = self(p)->unit;
  const int i = u.paramIndexForHash(id);
  if (i < 0) return false;
  const std::vector<std::string> &labels = u.valueLabels(i);
  for (size_t k = 0; k < labels.size(); k++)
    if (!strcasecmp(labels[k].c_str(), text)) { *out = u.paramDef(i).min + (double)k; return true; }
  char *end = nullptr; *out = strtod(text, &end);
  return end != text;
}

static void paramsFlush(const clap_plugin_t *p, const clap_input_events_t *in, const clap_output_events_t *out)
{
  Plugin *pl = self(p);
  readFromHost(pl, in);
  emitToHost(pl, out);
}

static const clap_plugin_params_t kParams = { paramsCount, paramsGetInfo, paramsGetValue, paramsValueToText, paramsTextToValue, paramsFlush };

// ---- audio ports

static uint32_t portsCount(const clap_plugin_t *p, bool isInput) { return isInput ? (uint32_t)self(p)->unit.desc().numInputs : 1; }

static bool portsGet(const clap_plugin_t *p, uint32_t index, bool isInput, clap_audio_port_info_t *info)
{
  const UnitDesc &d = self(p)->unit.desc();
  if (index >= (isInput ? (uint32_t)d.numInputs : 1u)) return false;
  *info = {};
  const int ch = isInput ? d.inChannels[index] : d.outChannels;
  info->id = (isInput ? 100 : 200) + index;
  snprintf(info->name, sizeof info->name, "%s", isInput ? (index == 0 ? "Input" : "Aux Input") : "Output");
  info->channel_count = (uint32_t)ch;
  info->flags = index == 0 ? CLAP_AUDIO_PORT_IS_MAIN : 0;
  info->port_type = ch == 1 ? CLAP_PORT_MONO : ch == 2 ? CLAP_PORT_STEREO : nullptr;
  info->in_place_pair = CLAP_INVALID_ID;
  return true;
}

static const clap_plugin_audio_ports_t kPorts = { portsCount, portsGet };

// ---- state

static bool stateSave(const clap_plugin_t *p, const clap_ostream_t *stream)
{
  if (getenv("ASAF_CLAP_DEBUG")) NSLog(@"ASAF.clap %p: state save", self(p));
  std::vector<uint8_t> data;
  if (!self(p)->unit.saveState(data)) return false;
  size_t off = 0;
  while (off < data.size()) {
    const int64_t n = stream->write(stream, data.data() + off, data.size() - off);
    if (n <= 0) return false;
    off += (size_t)n;
  }
  return true;
}

static bool stateLoad(const clap_plugin_t *p, const clap_istream_t *stream)
{
  if (getenv("ASAF_CLAP_DEBUG")) NSLog(@"ASAF.clap %p: state load", self(p));
  std::vector<uint8_t> data; uint8_t buf[65536];
  for (;;) {
    const int64_t n = stream->read(stream, buf, sizeof buf);
    if (n < 0) return false;
    if (n == 0) break;
    data.insert(data.end(), buf, buf + n);
  }
  return self(p)->unit.loadState(data.data(), data.size());
}

static const clap_plugin_state_t kState = { stateSave, stateLoad };

// ---- latency

static uint32_t latencyGet(const clap_plugin_t *p) { return self(p)->unit.latencySamples(); }
static const clap_plugin_latency_t kLatency = { latencyGet };

// ---- gui (Cocoa, embedded)

static NSSize preferredSize(Plugin *pl)
{
  switch (pl->unit.desc().subType) {
    case 'Objt': return NSMakeSize(430, 640);
    case 'Expt': return NSMakeSize(430, 330);
    default:     return NSMakeSize(460, pl->unit.paramCount() > 8 ? 560 : 260);
  }
}

static bool guiIsApiSupported(const clap_plugin_t *, const char *api, bool floating) { return !floating && !strcmp(api, CLAP_WINDOW_API_COCOA); }
static bool guiGetPreferredApi(const clap_plugin_t *, const char **api, bool *floating) { *api = CLAP_WINDOW_API_COCOA; *floating = false; return true; }

static bool guiCreate(const clap_plugin_t *p, const char *api, bool floating)
{
  Plugin *pl = self(p);
  if (!guiIsApiSupported(p, api, floating)) return false;
  @autoreleasepool {
    pl->bridge = [[ASAFUnitBridge alloc] initWithUnit:&pl->unit color:^uint32_t { return puckColor(pl); }];
    pl->view = [ASAFClapUIFactory makeViewWithBridge:pl->bridge];
    const NSSize s = preferredSize(pl);
    pl->view.frame = NSMakeRect(0, 0, s.width, s.height);
  }
  return pl->view != nil;
}

static void guiDestroy(const clap_plugin_t *p)
{
  Plugin *pl = self(p);
  @autoreleasepool {
    [pl->view removeFromSuperview];
    [pl->bridge invalidate];
    pl->view = nil; pl->bridge = nil;
  }
}

static bool guiSetScale(const clap_plugin_t *, double) { return false; }
static bool guiGetSize(const clap_plugin_t *p, uint32_t *w, uint32_t *h)
{
  Plugin *pl = self(p);
  const NSSize s = pl->view ? pl->view.frame.size : preferredSize(pl);
  *w = (uint32_t)s.width; *h = (uint32_t)s.height;
  return true;
}
static bool guiCanResize(const clap_plugin_t *) { return true; }
static bool guiGetResizeHints(const clap_plugin_t *, clap_gui_resize_hints_t *hints)
{
  *hints = {}; hints->can_resize_horizontally = true; hints->can_resize_vertically = true;
  return true;
}
static bool guiAdjustSize(const clap_plugin_t *, uint32_t *w, uint32_t *h)
{
  if (*w < 360) *w = 360;
  if (*h < 220) *h = 220;
  return true;
}
static bool guiSetSize(const clap_plugin_t *p, uint32_t w, uint32_t h)
{
  Plugin *pl = self(p);
  if (!pl->view) return false;
  [pl->view setFrameSize:NSMakeSize(w, h)];
  return true;
}
static bool guiSetParent(const clap_plugin_t *p, const clap_window_t *window)
{
  Plugin *pl = self(p);
  if (!pl->view || !window || !window->cocoa) return false;
  NSView *parent = (__bridge NSView *)window->cocoa;
  [parent addSubview:pl->view];
  return true;
}
static bool guiSetTransient(const clap_plugin_t *, const clap_window_t *) { return false; }
static void guiSuggestTitle(const clap_plugin_t *, const char *) {}
static bool guiShow(const clap_plugin_t *p) { Plugin *pl = self(p); if (!pl->view) return false; pl->view.hidden = NO; return true; }
static bool guiHide(const clap_plugin_t *p) { Plugin *pl = self(p); if (!pl->view) return false; pl->view.hidden = YES; return true; }

static const clap_plugin_gui_t kGui = { guiIsApiSupported, guiGetPreferredApi, guiCreate, guiDestroy, guiSetScale, guiGetSize, guiCanResize,
                                        guiGetResizeHints, guiAdjustSize, guiSetSize, guiSetParent, guiSetTransient, guiSuggestTitle, guiShow, guiHide };

// ---- REAPER embedded UI (TCP / MCP), see sdk/reaper_plugin_fx_embed.h

struct clap_plugin_reaper_embedui { intptr_t (CLAP_ABI *inline_editor)(const clap_plugin_t *plugin, int msg, void *param1, void *param2); };

static intptr_t embedInlineEditor(const clap_plugin_t *p, int msg, void *param1, void *param2)
{
  Plugin *pl = self(p);
  if (getenv("ASAF_CLAP_DEBUG") && msg != 0xF && msg != 0x200 && msg != 0x20 && msg != 0x100002) NSLog(@"ASAF.clap %p: embed msg 0x%x", pl, msg);
  return asaf::embedMessage(pl->unit, pl->embed, puckColor(pl), msg, param1, param2);
}
static const clap_plugin_reaper_embedui kEmbed = { embedInlineEditor };

// ---- plug-in callbacks

static bool pluginInit(const clap_plugin_t *p)
{
  Plugin *pl = self(p);
  std::string err;
  if (!pl->unit.open(&err)) { NSLog(@"ASAF.clap: %s", err.c_str()); return false; }
  pl->hostParams = (const clap_host_params_t *)pl->host->get_extension(pl->host, CLAP_EXT_PARAMS);
  pl->hostTrack = (const clap_host_track_info_t *)pl->host->get_extension(pl->host, CLAP_EXT_TRACK_INFO);
  if (!pl->hostTrack) pl->hostTrack = (const clap_host_track_info_t *)pl->host->get_extension(pl->host, CLAP_EXT_TRACK_INFO_COMPAT);
  updateTrackInfo(pl);

  // Automation is applied in process(). This timer applies what the host sent through flush() and
  // picks up what the plug-in changed, ~60 times a second.
  std::shared_ptr<bool> alive = pl->alive;
  pl->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(pl->timer, dispatch_time(DISPATCH_TIME_NOW, 0), 15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(pl->timer, ^{
    if (!*alive) return;
    pl->unit.tick();
    publishObjectMark(pl);
    // Ask the host to exchange parameter events (it calls flush() or process()) when the editor or the
    // plug-in changed something -- and a few times a second regardless, because REAPER only delivers
    // its own parameter changes through process(), which doesn't run while its audio device is closed.
    static const unsigned kPollTicks = 6; // ~100 ms
    if (pl->flushTick % 32 == 0) updateTrackInfo(pl); // in case the host doesn't announce colour changes
    if (pl->hostParams && pl->hostParams->request_flush && (pl->unit.hasPendingToHost() || ++pl->flushTick % kPollTicks == 0))
      pl->hostParams->request_flush(pl->host);
  });
  dispatch_resume(pl->timer);
  return true;
}

static void pluginDestroy(const clap_plugin_t *p)
{
  Plugin *pl = self(p);
  *pl->alive = false;
  asaf::removeMark(pl);
  if (pl->timer) dispatch_source_cancel(pl->timer);
  guiDestroy(p);
  delete pl;
}

static bool pluginActivate(const clap_plugin_t *p, double sampleRate, uint32_t, uint32_t maxFrames)
{
  std::string err;
  if (self(p)->unit.activate(sampleRate, maxFrames, &err)) return true;
  NSLog(@"ASAF.clap: %s", err.c_str());
  return false;
}
static void pluginDeactivate(const clap_plugin_t *p) { self(p)->unit.deactivate(); }
static bool pluginStartProcessing(const clap_plugin_t *) { return true; }
static void pluginStopProcessing(const clap_plugin_t *) {}
static void pluginReset(const clap_plugin_t *) {}

static clap_process_status pluginProcess(const clap_plugin_t *p, const clap_process_t *proc)
{
  Plugin *pl = self(p);
  Unit &u = pl->unit;
  readFromHost(pl, proc->in_events);
  u.applyFromHost();
  if (proc->transport)
    u.setTransport((proc->transport->flags & CLAP_TRANSPORT_IS_PLAYING) != 0, (proc->transport->flags & CLAP_TRANSPORT_IS_RECORDING) != 0);

  const float *const *inputs[2] = { nullptr, nullptr }; int inCh[2] = { 0, 0 };
  for (uint32_t b = 0; b < proc->audio_inputs_count && b < 2; b++) {
    inputs[b] = (const float *const *)proc->audio_inputs[b].data32;
    inCh[b] = inputs[b] ? (int)proc->audio_inputs[b].channel_count : 0;
  }
  float *const *outputs = nullptr; int outCh = 0;
  if (proc->audio_outputs_count > 0 && proc->audio_outputs[0].data32) { outputs = proc->audio_outputs[0].data32; outCh = (int)proc->audio_outputs[0].channel_count; }
  if (outputs) u.process(inputs, inCh, outputs, outCh, proc->frames_count);

  emitToHost(pl, proc->out_events);
  return CLAP_PROCESS_CONTINUE;
}

static const void *pluginGetExtension(const clap_plugin_t *, const char *id)
{
  if (!strcmp(id, CLAP_EXT_PARAMS)) return &kParams;
  if (!strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &kPorts;
  if (!strcmp(id, CLAP_EXT_STATE)) return &kState;
  if (!strcmp(id, CLAP_EXT_LATENCY)) return &kLatency;
  if (!strcmp(id, CLAP_EXT_GUI)) return &kGui;
  if (!strcmp(id, "cockos.reaper_embedui")) return &kEmbed;
  if (!strcmp(id, CLAP_EXT_TRACK_INFO) || !strcmp(id, CLAP_EXT_TRACK_INFO_COMPAT)) return &kTrackInfo;
  return nullptr;
}

static void pluginOnMainThread(const clap_plugin_t *p) { self(p)->unit.tick(); }

Plugin::Plugin(const clap_plugin_descriptor_t *desc, const clap_host_t *h, const UnitDesc &u) : host(h), unit(u)
{
  clap = {};
  clap.desc = desc; clap.plugin_data = this;
  clap.init = pluginInit; clap.destroy = pluginDestroy; clap.activate = pluginActivate; clap.deactivate = pluginDeactivate;
  clap.start_processing = pluginStartProcessing; clap.stop_processing = pluginStopProcessing; clap.reset = pluginReset;
  clap.process = pluginProcess; clap.get_extension = pluginGetExtension; clap.on_main_thread = pluginOnMainThread;
}

// ============================================================================ factory / entry

static std::vector<clap_plugin_descriptor_t> &descriptors()
{
  static std::vector<clap_plugin_descriptor_t> v;
  static std::vector<std::string> ids;
  if (v.empty()) {
    static const char *const kFeatures[] = { CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, CLAP_PLUGIN_FEATURE_SURROUND, CLAP_PLUGIN_FEATURE_AMBISONIC, nullptr };
    for (const UnitDesc &u : asaf::unitDescs()) {
      std::string slug;
      for (const char *c = u.name + 5; *c; c++) slug += *c == ' ' ? '-' : (char)tolower(*c); // drop "ASAF "
      ids.push_back("com.asafbridge." + slug);
    }
    for (size_t i = 0; i < asaf::unitDescs().size(); i++) {
      const UnitDesc &u = asaf::unitDescs()[i];
      clap_plugin_descriptor_t d = {};
      d.clap_version = CLAP_VERSION_INIT;
      d.id = ids[i].c_str(); d.name = u.name; d.vendor = "ASAF Bridge";
      d.url = ""; d.manual_url = ""; d.support_url = ""; d.version = "0.1.0";
      d.description = u.summary; d.features = kFeatures;
      v.push_back(d);
    }
  }
  return v;
}

// The nine Apple units, then the video overlay.
static uint32_t factoryCount(const clap_plugin_factory_t *) { return (uint32_t)descriptors().size() + 1; }
static const clap_plugin_descriptor_t *factoryDescriptor(const clap_plugin_factory_t *, uint32_t i)
{
  if (i < descriptors().size()) return &descriptors()[i];
  return i == descriptors().size() ? videoOverlayDescriptor() : nullptr;
}

static const clap_plugin_t *factoryCreate(const clap_plugin_factory_t *, const clap_host_t *host, const char *pluginId)
{
  if (!clap_version_is_compatible(host->clap_version)) return nullptr;
  if (!strcmp(pluginId, videoOverlayDescriptor()->id)) return videoOverlayCreate(host);
  auto &d = descriptors();
  for (size_t i = 0; i < d.size(); i++)
    if (!strcmp(d[i].id, pluginId)) return &(new Plugin(&d[i], host, asaf::unitDescs()[i]))->clap;
  return nullptr;
}

static const clap_plugin_factory_t kFactory = { factoryCount, factoryDescriptor, factoryCreate };

extern "C" int ASAFShim_Count(uint32_t);
extern "C" int ASAFShim_SetParam(uint32_t, const char *, float, int);
extern "C" int ASAFShim_GetParam(uint32_t, const char *, float *);
extern "C" int ASAFShim_ExportPressConvert(void);

static bool entryInit(const char *)
{
  // The conversion code shared with reaper_asaf talks to "the shim" through these pointers; here they
  // are our own functions.
  asaf::Shim &s = asaf::shim();
  s.Count = ASAFShim_Count; s.SetParam = ASAFShim_SetParam; s.GetParam = ASAFShim_GetParam; s.ExportPressConvert = ASAFShim_ExportPressConvert;
  return true;
}
static void entryDeinit(void) {}
static const void *entryGetFactory(const char *id) { return !strcmp(id, CLAP_PLUGIN_FACTORY_ID) ? &kFactory : nullptr; }

extern "C" CLAP_EXPORT const clap_plugin_entry_t clap_entry = { CLAP_VERSION_INIT, entryInit, entryDeinit, entryGetFactory };
