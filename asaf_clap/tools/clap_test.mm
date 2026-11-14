// Minimal CLAP host: exercises every plug-in in ASAF.clap without a DAW.
#import <Foundation/Foundation.h>
#include <clap/clap.h>
#include <dlfcn.h>
#include <vector>
#include <string>
#include <cmath>

static void pump(double s) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
static const void *hostExt(const clap_host_t *, const char *) { return nullptr; }
static void hostNop(const clap_host_t *) {}
static clap_host_t gHost = { CLAP_VERSION_INIT, nullptr, "clap_test", "test", "", "1", hostExt, hostNop, hostNop, hostNop };

struct Events { std::vector<clap_event_param_value_t> in; int outCount = 0; };
static uint32_t inSize(const clap_input_events_t *l) { return (uint32_t)((Events *)l->ctx)->in.size(); }
static const clap_event_header_t *inGet(const clap_input_events_t *l, uint32_t i) { return &((Events *)l->ctx)->in[i].header; }
static bool outPush(const clap_output_events_t *l, const clap_event_header_t *) { ((Events *)l->ctx)->outCount++; return true; }

struct Mem { std::vector<uint8_t> d; size_t pos = 0; };
static int64_t memWrite(const clap_ostream_t *s, const void *b, uint64_t n) { Mem *m = (Mem *)s->ctx; m->d.insert(m->d.end(), (const uint8_t *)b, (const uint8_t *)b + n); return (int64_t)n; }
static int64_t memRead(const clap_istream_t *s, void *b, uint64_t n) { Mem *m = (Mem *)s->ctx; uint64_t k = std::min<uint64_t>(n, m->d.size() - m->pos); memcpy(b, m->d.data() + m->pos, k); m->pos += k; return (int64_t)k; }

struct Instance {
  const clap_plugin_t *p = nullptr; const clap_plugin_params_t *params = nullptr; const clap_plugin_audio_ports_t *ports = nullptr;
  std::vector<std::vector<std::vector<float>>> in; std::vector<std::vector<float>> out; Events ev; int64_t steady = 0;
  clap_id paramId(const char *name) { for (uint32_t i = 0; i < params->count(p); i++) { clap_param_info_t pi; params->get_info(p, i, &pi); if (!strcmp(pi.name, name)) return pi.id; } return CLAP_INVALID_ID; }
  void set(const char *name, double v) { clap_event_param_value_t e = {}; e.header = { sizeof e, 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0 }; e.param_id = paramId(name); e.note_id = -1; e.port_index = -1; e.channel = -1; e.key = -1; e.value = v; ev.in.push_back(e); }
  double get(const char *name) { double v = NAN; params->get_value(p, paramId(name), &v); return v; }
  void process(uint32_t n) {
    std::vector<clap_audio_buffer_t> ib(in.size()); std::vector<std::vector<float *>> ip(in.size());
    for (size_t b = 0; b < in.size(); b++) { for (auto &c : in[b]) ip[b].push_back(c.data()); ib[b] = {}; ib[b].data32 = ip[b].data(); ib[b].channel_count = (uint32_t)ip[b].size(); }
    std::vector<float *> op; for (auto &c : out) op.push_back(c.data());
    clap_audio_buffer_t ob = {}; ob.data32 = op.data(); ob.channel_count = (uint32_t)op.size();
    clap_input_events_t ie = { &ev, inSize, inGet }; clap_output_events_t oe = { &ev, outPush };
    clap_process_t pr = {}; pr.steady_time = steady; pr.frames_count = n; pr.audio_inputs = ib.data(); pr.audio_outputs = &ob;
    pr.audio_inputs_count = (uint32_t)ib.size(); pr.audio_outputs_count = 1; pr.in_events = &ie; pr.out_events = &oe;
    p->process(p, &pr); ev.in.clear(); steady += n;
  }
};

static bool make(const clap_plugin_factory_t *f, const char *id, Instance &x, uint32_t N) {
  x.p = f->create_plugin(f, &gHost, id);
  if (!x.p || !x.p->init(x.p)) return false;
  x.params = (const clap_plugin_params_t *)x.p->get_extension(x.p, CLAP_EXT_PARAMS);
  x.ports = (const clap_plugin_audio_ports_t *)x.p->get_extension(x.p, CLAP_EXT_AUDIO_PORTS);
  for (uint32_t b = 0; b < x.ports->count(x.p, true); b++) { clap_audio_port_info_t pi; x.ports->get(x.p, b, true, &pi); x.in.push_back(std::vector<std::vector<float>>(pi.channel_count, std::vector<float>(N, 0.f))); }
  clap_audio_port_info_t po; x.ports->get(x.p, 0, false, &po); x.out.assign(po.channel_count, std::vector<float>(N, 0.f));
  return true;
}

int main(int argc, char **argv) { @autoreleasepool {
  const uint32_t N = 1024;
  std::string path = std::string(argv[1]) + "/Contents/MacOS/ASAF";
  void *h = dlopen(path.c_str(), RTLD_NOW); if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
  const clap_plugin_entry_t *entry = (const clap_plugin_entry_t *)dlsym(h, "clap_entry");
  if (!entry || !entry->init(argv[1])) { printf("no entry\n"); return 1; }
  const clap_plugin_factory_t *f = (const clap_plugin_factory_t *)entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
  int failures = 0;
  for (uint32_t i = 0; i < f->get_plugin_count(f); i++) {
    const clap_plugin_descriptor_t *d = f->get_plugin_descriptor(f, i);
    Instance x; bool ok = make(f, d->id, x, N);
    if (!ok) { printf("%-24s FAILED to create/init\n", d->name); failures++; continue; }
    bool act = x.p->activate(x.p, 48000, 1, N);
    if (act) { x.p->start_processing(x.p); for (int k = 0; k < 4; k++) x.process(N); x.p->stop_processing(x.p); }
    const clap_plugin_state_t *st = (const clap_plugin_state_t *)x.p->get_extension(x.p, CLAP_EXT_STATE);
    Mem m; clap_ostream_t os = { &m, memWrite }; bool saved = st->save(x.p, &os);
    clap_istream_t is = { &m, memRead }; bool loaded = saved && st->load(x.p, &is);
    clap_param_info_t first = {}; if (x.params->count(x.p)) x.params->get_info(x.p, 0, &first);
    printf("%-24s %-28s in=%zu(%zu%s) out=%zu params=%-4u activate=%d state=%zuB load=%d first='%s%s%s'\n", d->name, d->id, x.in.size(), x.in[0].size(),
           x.in.size() > 1 ? "+1" : "", x.out.size(), x.params->count(x.p), act, m.d.size(), loaded, first.module, first.module[0] ? " / " : "", first.name);
    if (!act && strcmp(d->name, "ASAF Object to Scene")) failures++;
    if (act) x.p->deactivate(x.p);
    x.p->destroy(x.p); pump(0.02);
  }

  // Object -> Object Renderer: does a host parameter event move the sound?
  Instance obj, rd;
  if (make(f, "com.asafbridge.object", obj, N) && make(f, "com.asafbridge.object-renderer", rd, N)) {
    obj.p->activate(obj.p, 48000, 1, N); rd.p->activate(rd.p, 48000, 1, N);
    obj.set("Index", 0); obj.process(N); pump(0.1);
    for (double az : { 0.0, 90.0, -90.0 }) {
      obj.set("Azimuth", az); double e[2] = { 0, 0 };
      for (int blk = 0; blk < 40; blk++) {
        for (uint32_t k = 0; k < N; k++) obj.in[0][0][k] = 0.25f * sinf((float)((obj.steady + k) * 2 * M_PI * 440 / 48000.0));
        obj.process(N); if (blk == 2) pump(0.1);
        rd.in[0][0] = obj.out[0]; rd.process(N);
        if (blk >= 20) for (int c = 0; c < 2; c++) for (uint32_t k = 0; k < N; k++) e[c] += rd.out[c][k] * rd.out[c][k];
      }
      printf("azimuth %+4.0f (plug-in reports %+.1f): L %.1f dB  R %.1f dB\n", az, obj.get("Azimuth"), 10 * log10(e[0] / (20.0 * N) + 1e-12), 10 * log10(e[1] / (20.0 * N) + 1e-12));
    }
    obj.p->destroy(obj.p); rd.p->destroy(rd.p);
  } else { printf("could not create object + renderer\n"); failures++; }
  printf("%s\n", failures ? "FAILURES" : "ALL OK");
  fflush(stdout); _exit(failures ? 1 : 0);
} }
