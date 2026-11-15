// Export test without a DAW: hosts ASAF Object x N and ASAF Export from ASAF.clap the way REAPER's
// offline render does, writes the bounce file and has ASAF Export convert it.
//
//   export_test <ASAF.clap> <out.wav> [options]
//
// Writes <out.wav> (the ASAF BWF, if conversion works) and <out.bounce.wav> (a copy of the bounce
// before conversion). Check both with tools/export_test/asaf_inspect.py.
//
// The scenario is the one tools/export_test/reaper_export_test.lua builds in REAPER (4 s, 48 kHz):
//   object 1: 220 Hz, azimuth +90, elevation 0,  distance 1
//   object 2: 440 Hz, azimuth -90, elevation 0,  distance 1
//   object 3: 660 Hz, azimuth 0,   elevation 45, distance 2
//   object 4: 880 Hz, azimuth automated -90 -> +90 over the 4 s, elevation 0, distance 1
// Objects after the fourth (--objects) sit at azimuth 0.
//
// Options, to reproduce what a host might do differently:
//   --objects N        number of objects (default 4)
//   --block N          process block size (default 1024)
//   --mode offline     render on a worker thread as fast as possible while the main run loop runs
//                      (REAPER's offline render; the default)
//   --mode realtime    as offline, but paced at real time (REAPER's online render)
//   --mode blocked     render on the main thread: the plug-ins' main-thread timers never fire
//   --stopped          report the transport as stopped
//   --no-transport     pass no transport to process()
//   --settle S         seconds between setting the static positions and rendering (default 0.5)
//   --apac             also make the APAC .mp4
//
// Options that replace the scenario (used by tools/export_test/speech_demo.sh):
//   --seconds S        length of the render (default 4)
//   --pos AZ,EL,DIST   static position of the next object (repeat per object; sets --objects)
//   --audio FILE       audio for the next object instead of a tone: mono 48 kHz 32-bit float WAV
//   --set NAME=VALUE   set a parameter on every ASAF Object, e.g. --set Reverb=1 --set "Reverb Mix=70"
//   --session NAME=VALUE  set a session parameter through an ASAF Panner, e.g. --session "Reverb Preset=8"
//   --sweep N,T0,T1    object N's azimuth is automated -90 -> +90 between T0 and T1 seconds
//                      (default 4,0,<seconds>; with --pos, no object is automated unless this is given)
#import <Foundation/Foundation.h>
#include <clap/clap.h>
#include <dlfcn.h>
#include <unistd.h>
#include <cmath>
#include <string>
#include <vector>
#include "../../reaper_asaf/asaf_core.h"

static const void *hostExt(const clap_host_t *, const char *) { return nullptr; }
static void hostNop(const clap_host_t *) {}
static clap_host_t gHost = { CLAP_VERSION_INIT, nullptr, "export_test", "test", "", "1", hostExt, hostNop, hostNop, hostNop };

struct Events { std::vector<clap_event_param_value_t> in; };
static uint32_t inSize(const clap_input_events_t *l) { return (uint32_t)((Events *)l->ctx)->in.size(); }
static const clap_event_header_t *inGet(const clap_input_events_t *l, uint32_t i) { return &((Events *)l->ctx)->in[i].header; }
static bool outPush(const clap_output_events_t *, const clap_event_header_t *) { return true; }

enum Transport { kPlaying, kStopped, kNone };

struct Instance {
  const clap_plugin_t *p = nullptr; const clap_plugin_params_t *params = nullptr;
  std::vector<std::vector<float>> in, out; Events ev; int64_t steady = 0;
  bool make(const clap_plugin_factory_t *f, const char *id, uint32_t N) {
    p = f->create_plugin(f, &gHost, id);
    if (!p || !p->init(p)) return false;
    params = (const clap_plugin_params_t *)p->get_extension(p, CLAP_EXT_PARAMS);
    auto *ports = (const clap_plugin_audio_ports_t *)p->get_extension(p, CLAP_EXT_AUDIO_PORTS);
    clap_audio_port_info_t pi; ports->get(p, 0, true, &pi); in.assign(pi.channel_count, std::vector<float>(N, 0.f));
    ports->get(p, 0, false, &pi); out.assign(pi.channel_count, std::vector<float>(N, 0.f));
    return p->activate(p, 48000, 1, N) && p->start_processing(p);
  }
  clap_id paramId(const char *name) {
    for (uint32_t i = 0; i < params->count(p); i++) { clap_param_info_t pi; params->get_info(p, i, &pi); if (!pi.module[0] && !strcmp(pi.name, name)) return pi.id; }
    printf("no parameter '%s'\n", name); return CLAP_INVALID_ID;
  }
  void set(clap_id id, double v) {
    clap_event_param_value_t e = {}; e.header = { sizeof e, 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0 };
    e.param_id = id; e.note_id = -1; e.port_index = -1; e.channel = -1; e.key = -1; e.value = v; ev.in.push_back(e);
  }
  void set(const char *name, double v) { set(paramId(name), v); }
  double get(const char *name) { double v = NAN; params->get_value(p, paramId(name), &v); return v; }
  // Parameter changes made while not rendering reach a CLAP plug-in through flush().
  void flush() { clap_input_events_t ie = { &ev, inSize, inGet }; clap_output_events_t oe = { nullptr, outPush }; params->flush(p, &ie, &oe); ev.in.clear(); }
  void process(uint32_t n, Transport t) {
    std::vector<float *> ip, op; for (auto &c : in) ip.push_back(c.data()); for (auto &c : out) op.push_back(c.data());
    clap_audio_buffer_t ib = {}, ob = {}; ib.data32 = ip.data(); ib.channel_count = (uint32_t)ip.size(); ob.data32 = op.data(); ob.channel_count = (uint32_t)op.size();
    clap_input_events_t ie = { &ev, inSize, inGet }; clap_output_events_t oe = { nullptr, outPush };
    clap_event_transport_t tr = {}; tr.header = { sizeof tr, 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_TRANSPORT, 0 };
    tr.flags = t == kPlaying ? CLAP_TRANSPORT_IS_PLAYING : 0;
    clap_process_t pr = {}; pr.steady_time = steady; pr.frames_count = n; pr.transport = t == kNone ? nullptr : &tr;
    pr.audio_inputs = &ib; pr.audio_outputs = &ob; pr.audio_inputs_count = 1; pr.audio_outputs_count = 1; pr.in_events = &ie; pr.out_events = &oe;
    p->process(p, &pr); ev.in.clear(); steady += n;
  }
};

// Mono 32-bit float WAV -> samples (empty if it isn't one).
static std::vector<float> readMonoFloatWav(const char *path)
{
  std::vector<float> out; FILE *f = fopen(path, "rb"); if (!f) return out;
  char hdr[12], id[4]; uint32_t sz; bool fmtOk = false;
  if (fread(hdr, 12, 1, f) == 1 && !memcmp(hdr + 8, "WAVE", 4))
    while (fread(id, 4, 1, f) == 1 && fread(&sz, 4, 1, f) == 1) {
      if (!memcmp(id, "fmt ", 4) && sz >= 16) {
        std::vector<uint8_t> b(sz); if (fread(b.data(), sz, 1, f) != 1) break;
        uint16_t tag, ch, bits; uint32_t rate; memcpy(&tag, &b[0], 2); memcpy(&ch, &b[2], 2); memcpy(&rate, &b[4], 4); memcpy(&bits, &b[14], 2);
        if (tag == 0xFFFE && sz >= 26) memcpy(&tag, &b[24], 2);
        fmtOk = tag == 3 && ch == 1 && rate == 48000 && bits == 32;
        if (sz & 1) fseek(f, 1, SEEK_CUR);
      } else if (!memcmp(id, "data", 4)) {
        if (fmtOk) { out.resize(sz / 4); out.resize(fread(out.data(), 4, out.size(), f)); }
        break;
      } else fseeko(f, sz + (sz & 1), SEEK_CUR);
    }
  fclose(f);
  return out;
}

static void pump(double s) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }

int main(int argc, char **argv) { @autoreleasepool {
  if (argc < 3) { printf("usage: export_test <ASAF.clap> <out.wav> [--objects N] [--block N] [--mode offline|realtime|blocked] [--stopped] [--no-transport] [--settle S] [--apac]\n"); return 2; }
  int nobj = 4; uint32_t N = 1024; std::string mode = "offline"; Transport transport = kPlaying; double settle = 0.5; bool apac = false;
  double seconds = 4, sweepT0 = 0, sweepT1 = -1; int sweepObj = 3; bool sweepGiven = false;
  struct Pos { double az, el, dist; };
  std::vector<Pos> pos = { { 90, 0, 1 }, { -90, 0, 1 }, { 0, 45, 2 }, { -90, 0, 1 } }; bool posGiven = false;
  std::vector<std::vector<float>> audio;
  std::vector<std::pair<std::string, double>> objSet, sessionSet;
  for (int i = 3; i < argc; i++) {
    const std::string a = argv[i]; const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (a == "--objects") { nobj = atoi(v); i++; } else if (a == "--block") { N = (uint32_t)atoi(v); i++; }
    else if (a == "--mode") { mode = v; i++; } else if (a == "--settle") { settle = atof(v); i++; }
    else if (a == "--seconds") { seconds = atof(v); i++; }
    else if (a == "--pos") { if (!posGiven) pos.clear(); posGiven = true; Pos p = { 0, 0, 1 }; sscanf(v, "%lf,%lf,%lf", &p.az, &p.el, &p.dist); pos.push_back(p); nobj = (int)pos.size(); i++; }
    else if (a == "--audio") { audio.push_back(readMonoFloatWav(v)); if (audio.back().empty()) { printf("%s: not a mono 48 kHz 32-bit float WAV\n", v); return 2; } i++; }
    else if (a == "--set" || a == "--session") {
      const char *eq = strchr(v, '='); if (!eq) { printf("%s needs NAME=VALUE\n", a.c_str()); return 2; }
      (a == "--set" ? objSet : sessionSet).push_back({ std::string(v, eq - v), atof(eq + 1) }); i++;
    }
    else if (a == "--sweep") { sweepGiven = true; sscanf(v, "%d,%lf,%lf", &sweepObj, &sweepT0, &sweepT1); sweepObj--; i++; }
    else if (a == "--stopped") transport = kStopped; else if (a == "--no-transport") transport = kNone; else if (a == "--apac") apac = true;
    else { printf("unknown option %s\n", a.c_str()); return 2; }
  }
  const int kMeta = 8, kRate = 48000, NCH = nobj + kMeta;
  const int64_t total = (int64_t)(seconds * kRate);
  if (posGiven && !sweepGiven) sweepObj = -1;
  if (sweepT1 < 0) sweepT1 = seconds;
  if (sweepObj >= nobj) sweepObj = -1;
  const std::vector<std::vector<float>> *paudio = &audio;
  const std::string out = argv[2], keep = out.substr(0, out.rfind('.')) + ".bounce.wav";

  const std::string bin = std::string(argv[1]) + "/Contents/MacOS/ASAF";
  void *h = dlopen(bin.c_str(), RTLD_NOW); if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
  const clap_plugin_entry_t *entry = (const clap_plugin_entry_t *)dlsym(h, "clap_entry");
  if (!entry || !entry->init(argv[1])) { printf("no CLAP entry\n"); return 1; }
  const clap_plugin_factory_t *f = (const clap_plugin_factory_t *)entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
  // asaf_core drives the plug-ins through this control API; use the copy of ASAF.clap under test.
  asaf::Shim &s = asaf::shim();
  s.Count = (int (*)(uint32_t))dlsym(h, "ASAFShim_Count"); s.SetParam = (int (*)(uint32_t, const char *, float, int))dlsym(h, "ASAFShim_SetParam");
  s.GetParam = (int (*)(uint32_t, const char *, float *))dlsym(h, "ASAFShim_GetParam"); s.ExportPressConvert = (int (*)(void))dlsym(h, "ASAFShim_ExportPressConvert");
  if (!s.ok()) { printf("ASAF.clap has no control API\n"); return 1; }

  std::vector<Instance> objs(nobj); Instance ex;
  for (int i = 0; i < nobj; i++) if (!objs[i].make(f, "com.asafbridge.object", N)) { printf("could not create ASAF Object %d\n", i + 1); return 1; }
  if (!ex.make(f, "com.asafbridge.export", N)) { printf("could not create ASAF Export\n"); return 1; }
  pump(0.3);

  // Static positions, set while stopped as in a session that was set up before rendering.
  pos.resize(nobj, Pos{ 0, 0, 1 });
  for (int i = 0; i < nobj; i++) {
    objs[i].set("Index", i); objs[i].flush(); pump(0.05);
    objs[i].set("Azimuth", pos[i].az); objs[i].set("Elevation", pos[i].el); objs[i].set("Distance", pos[i].dist);
    objs[i].flush();
  }
  for (auto &kv : objSet) for (int i = 0; i < nobj; i++) { objs[i].set(kv.first.c_str(), kv.second); objs[i].flush(); }
  Instance panner;
  if (!sessionSet.empty()) {
    if (!panner.make(f, "com.asafbridge.panner", N)) { printf("could not create ASAF Panner\n"); return 1; }
    pump(0.3);
    for (auto &kv : sessionSet) { panner.set(kv.first.c_str(), kv.second); panner.flush(); }
  }
  pump(settle);
  for (auto &kv : objSet) printf("object parameter %s = %g (object 1 reports %g)\n", kv.first.c_str(), kv.second, objs[0].get(kv.first.c_str()));
  for (auto &kv : sessionSet) printf("session parameter %s = %g (panner reports %g)\n", kv.first.c_str(), kv.second, panner.get(kv.first.c_str()));
  for (int i = 0; i < nobj; i++)
    printf("object %d before render: index %g azimuth %+g elevation %+g distance %g\n", i + 1, objs[i].get("Index"), objs[i].get("Azimuth"), objs[i].get("Elevation"), objs[i].get("Distance"));
  const clap_id azId = sweepObj >= 0 ? objs[sweepObj].paramId("Azimuth") : CLAP_INVALID_ID;

  std::string err;
  if (!asaf::armExport(true, &err)) { printf("arm failed: %s\n", err.c_str()); return 1; }
  asaf::BounceWriter w; if (!w.open(out.c_str(), NCH, kRate)) { printf("could not write %s\n", out.c_str()); return 1; }

  __block double metaPeak = 0; __block bool done = false;
  Instance *po = objs.data(), *pe = &ex, *pp = &panner; asaf::BounceWriter *pw = &w;
  void (^render)(void) = ^{
    std::vector<std::vector<double>> db(NCH, std::vector<double>(N)); std::vector<double *> ptrs(NCH); for (int c = 0; c < NCH; c++) ptrs[c] = db[c].data();
    for (int64_t pos = 0; pos < total; pos += N) {
      const uint32_t n = (uint32_t)std::min<int64_t>(N, total - pos);
      for (int i = 0; i < nobj; i++) {
        const double hz = 220.0 * (i + 1);
        if (i < (int)paudio->size()) { const std::vector<float> &a = (*paudio)[i]; for (uint32_t k = 0; k < n; k++) po[i].in[0][k] = pos + k < (int64_t)a.size() ? a[pos + k] : 0.f; }
        else for (uint32_t k = 0; k < n; k++) po[i].in[0][k] = 0.25f * sinf((float)(fmod((pos + k) * hz / kRate, 1.0) * 2 * M_PI));
        if (i == sweepObj) // automation, once per block
          po[i].set(azId, -90.0 + 180.0 * std::min(1.0, std::max(0.0, ((double)pos / kRate - sweepT0) / (sweepT1 - sweepT0))));
        po[i].process(n, transport);
        for (uint32_t k = 0; k < n; k++) db[i][k] = po[i].out[0][k];
      }
      if (pp->p) pp->process(n, transport); // the panner, if there is one, runs alongside as it would on its own track
      // like REAPER's default pin mapping: ASAF Export's inputs are the first channels of the bus
      for (size_t c = 0; c < pe->in.size(); c++) for (uint32_t k = 0; k < n; k++) pe->in[c][k] = (int)c < nobj ? (float)db[c][k] : 0.f;
      pe->process(n, transport);
      for (int c = 0; c < kMeta; c++) for (uint32_t k = 0; k < n; k++) { const float v = pe->out[c][k]; db[nobj + c][k] = v; if (fabsf(v) > metaPeak) metaPeak = fabsf(v); }
      pw->write(ptrs.data(), (int)n, NCH, 0, 1);
      if (mode == "realtime") usleep((useconds_t)(1e6 * n / kRate));
    }
    done = true;
  };
  const double t0 = CFAbsoluteTimeGetCurrent();
  if (mode == "blocked") render();
  else { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), render); while (!done) pump(0.005); }
  w.close();
  printf("rendered %g s in %.2f s (%s, block %u): %d channels, metadata channel peak %.3f\n", seconds, CFAbsoluteTimeGetCurrent() - t0, mode.c_str(), N, NCH, metaPeak);

  [[NSFileManager defaultManager] removeItemAtPath:@(keep.c_str()) error:nil];
  [[NSFileManager defaultManager] copyItemAtPath:@(out.c_str()) toPath:@(keep.c_str()) error:nil];
  asaf::armExport(false, nullptr);
  std::string apacErr;
  const bool ok = apac ? asaf::convertBounceToASAFAndAPAC(out.c_str(), &err, &apacErr) : asaf::convertBounceToASAF(out.c_str(), &err);
  int ch = 0; const bool isASAF = asaf::isASAFFile(out.c_str(), &ch);
  printf("convert %s: %s has %d channels, ASAF metadata chunk %s\n", ok ? "OK" : "FAILED", out.c_str(), ch, isASAF ? "present" : "missing");
  if (!ok) printf("  %s\n", err.c_str());
  if (apac) printf("APAC: %s %s\n", apacErr.empty() ? asaf::apacPathFor(out.c_str()).c_str() : "FAILED:", apacErr.c_str());
  fflush(stdout); _exit(ok ? 0 : 1);
} }
