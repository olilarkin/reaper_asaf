// Prints a CLAP parameter's value texts and checks text -> value round-trips.
#import <Foundation/Foundation.h>
#include <clap/clap.h>
#include <dlfcn.h>
#include <string>
static const void *hostExt(const clap_host_t *, const char *) { return nullptr; }
static void hostNop(const clap_host_t *) {}
static clap_host_t gHost = { CLAP_VERSION_INIT, nullptr, "text_test", "test", "", "1", hostExt, hostNop, hostNop, hostNop };
int main(int argc, char **argv) { @autoreleasepool {
  std::string path = std::string(argv[1]) + "/Contents/MacOS/ASAF"; void *h = dlopen(path.c_str(), RTLD_NOW);
  const clap_plugin_entry_t *entry = (const clap_plugin_entry_t *)dlsym(h, "clap_entry"); entry->init(argv[1]);
  const clap_plugin_factory_t *f = (const clap_plugin_factory_t *)entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
  for (int a = 2; a + 1 < argc; a += 2) {
    const clap_plugin_t *p = f->create_plugin(f, &gHost, argv[a]); if (!p || !p->init(p)) { printf("no %s\n", argv[a]); continue; }
    const clap_plugin_params_t *pr = (const clap_plugin_params_t *)p->get_extension(p, CLAP_EXT_PARAMS);
    for (uint32_t i = 0; i < pr->count(p); i++) { clap_param_info_t pi; pr->get_info(p, i, &pi); if (strcmp(pi.name, argv[a + 1])) continue;
      printf("%s / %s:", argv[a], pi.name); int bad = 0;
      for (double v = pi.min_value; v <= pi.max_value; v += 1) { char buf[64] = ""; pr->value_to_text(p, pi.id, v, buf, sizeof buf); double back = -99; pr->text_to_value(p, pi.id, buf, &back); if (back != v) bad++; printf(" %g=%s", v, buf); }
      printf("  (round-trip failures: %d)\n", bad); }
    p->destroy(p);
  }
  fflush(stdout); _exit(0);
} }
