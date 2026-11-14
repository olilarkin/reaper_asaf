// Prints the plug-ins' own value labels for stepped parameters.
#import <Foundation/Foundation.h>
#include "../unit.h"
int main(int argc, char **argv) { @autoreleasepool {
  const char *only = argc > 1 ? argv[1] : nullptr; const char *param = argc > 2 ? argv[2] : nullptr;
  for (const asaf::UnitDesc &d : asaf::unitDescs()) {
    if (only && strcmp(only, d.name)) continue;
    asaf::Unit u(d); std::string err;
    if (!u.open(&err)) { printf("%s: %s\n", d.name, err.c_str()); continue; }
    printf("== %s (%d params)\n", d.name, u.paramCount());
    for (int i = 0; i < u.paramCount(); i++) {
      const asaf::ParamDef &p = u.paramDef(i);
      if (param && p.ident != param) continue;
      if (!param && (!p.stepped || p.max - p.min > 60 || p.ident.find("object") == 0 && p.ident.find("object0") != 0)) continue;
      printf("  %s [%g..%g]:", p.ident.c_str(), p.min, p.max);
      for (double v = p.min; v <= p.max + 1e-9; v += 1) printf(" %g=\"%s\"", v, u.pluginText(i, v).c_str());
      printf("\n");
    }
  }
  fflush(stdout); _exit(0);
} }
