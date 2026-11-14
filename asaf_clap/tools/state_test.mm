// Does a host parameter change stick after the plug-in's state has been restored?
#import <Foundation/Foundation.h>
#include <clap/clap.h>
#include <dlfcn.h>
#include <vector>
#include <string>
#include <cmath>
static void pump(double s) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
static const void *hostExt(const clap_host_t *, const char *) { return nullptr; }
static void hostNop(const clap_host_t *) {}
static clap_host_t gHost = { CLAP_VERSION_INIT, nullptr, "state_test", "test", "", "1", hostExt, hostNop, hostNop, hostNop };
struct Ev { std::vector<clap_event_param_value_t> in; };
static uint32_t inSize(const clap_input_events_t *l) { return (uint32_t)((Ev *)l->ctx)->in.size(); }
static const clap_event_header_t *inGet(const clap_input_events_t *l, uint32_t i) { return &((Ev *)l->ctx)->in[i].header; }
static bool outPush(const clap_output_events_t *, const clap_event_header_t *) { return true; }
struct Mem { std::vector<uint8_t> d; size_t pos = 0; };
static int64_t memWrite(const clap_ostream_t *s, const void *b, uint64_t n) { Mem *m = (Mem *)s->ctx; m->d.insert(m->d.end(), (const uint8_t *)b, (const uint8_t *)b + n); return (int64_t)n; }
static int64_t memRead(const clap_istream_t *s, void *b, uint64_t n) { Mem *m = (Mem *)s->ctx; uint64_t k = std::min<uint64_t>(n, m->d.size() - m->pos); memcpy(b, m->d.data() + m->pos, k); m->pos += k; return (int64_t)k; }
struct Inst { const clap_plugin_t *p; const clap_plugin_params_t *pr; const clap_plugin_state_t *st;
  clap_id id(const char *name) { for (uint32_t i = 0; i < pr->count(p); i++) { clap_param_info_t pi; pr->get_info(p, i, &pi); if (!strcmp(pi.name, name)) return pi.id; } return CLAP_INVALID_ID; }
  void set(const char *name, double v) { Ev ev; clap_event_param_value_t e = {}; e.header = { sizeof e, 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0 }; e.param_id = id(name); e.note_id = -1; e.port_index = -1; e.channel = -1; e.key = -1; e.value = v; ev.in.push_back(e);
    clap_input_events_t ie = { &ev, inSize, inGet }; clap_output_events_t oe = { nullptr, outPush }; pr->flush(p, &ie, &oe); }
  double get(const char *name) { double v = NAN; pr->get_value(p, id(name), &v); return v; } };
static Inst make(const clap_plugin_factory_t *f) { Inst x; x.p = f->create_plugin(f, &gHost, "com.asafbridge.object"); x.p->init(x.p);
  x.pr = (const clap_plugin_params_t *)x.p->get_extension(x.p, CLAP_EXT_PARAMS); x.st = (const clap_plugin_state_t *)x.p->get_extension(x.p, CLAP_EXT_STATE); return x; }
int main(int argc, char **argv) { @autoreleasepool {
  std::string path = std::string(argv[1]) + "/Contents/MacOS/ASAF"; void *h = dlopen(path.c_str(), RTLD_NOW);
  const clap_plugin_entry_t *entry = (const clap_plugin_entry_t *)dlsym(h, "clap_entry"); entry->init(argv[1]);
  const clap_plugin_factory_t *f = (const clap_plugin_factory_t *)entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
  int nobj = argc > 2 ? atoi(argv[2]) : 1; bool reload = argc > 3 && atoi(argv[3]);
  std::vector<Inst> v; for (int i = 0; i < nobj; i++) { v.push_back(make(f)); v[i].set("Index", i); } pump(0.3);
  if (reload) for (auto &x : v) { Mem m; clap_ostream_t os = { &m, memWrite }; x.st->save(x.p, &os); clap_istream_t is = { &m, memRead }; x.st->load(x.p, &is); }
  pump(0.5);
  for (int i = 0; i < nobj; i++) v[i].set("Azimuth", 30 + 20 * i);
  for (double t : { 0.1, 0.5, 1.5 }) { pump(t); printf("objs=%d reload=%d  +%.1fs:", nobj, (int)reload, t); for (int i = 0; i < nobj; i++) printf("  idx %.0f az %.1f", v[i].get("Index"), v[i].get("Azimuth")); printf("\n"); }
  fflush(stdout); _exit(0);
} }
