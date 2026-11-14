// Dumps the layout tables inside ASAF Object Renderer (addresses from `nm`, arm64 build 2.1.8).
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "../unit.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
static bool rd(uintptr_t a, void *o, size_t n) { mach_vm_size_t g = 0; return a > 0x1000 && mach_vm_read_overwrite(mach_task_self(), a, n, (mach_vm_address_t)o, &g) == KERN_SUCCESS && g == n; }
int main() { @autoreleasepool {
  const asaf::UnitDesc *d = nullptr; for (auto &x : asaf::unitDescs()) if (x.subType == 'ORdr') d = &x;
  asaf::Unit u(*d); std::string err; if (!u.open(&err)) { printf("%s\n", err.c_str()); return 1; }
  Dl_info info = {}; dladdr(*(void **)u.juceProcessor(), &info); printf("image %s base %p\n", info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?", info.dli_fbase); fflush(stdout); const char *base = (const char *)info.dli_fbase;
  auto strs = [&](const char *title, uintptr_t off, int n) { printf("%s:\n", title); for (int i = 0; i < n; i++) { uintptr_t p = 0; char buf[64] = {0}; bool ok = rd((uintptr_t)base + off + 8 * i, &p, 8) && rd(p, buf, 40); buf[40] = 0; printf("  [%2d] %s\n", i, ok ? buf : "(unreadable)"); fflush(stdout); } };
  strs("kChannelLayoutStrings", 0x215fd0, 14);
  strs("kTwoChannelOutputTypeStrings", 0x217878, 2);
  strs("kChannelLayoutOrderStrings", 0x216040, 14);
  printf("kChannelLayoutTags:"); for (int i = 0; i < 14; i++) { uint32_t v = 0; rd((uintptr_t)base + 0x1d3180 + 4 * i, &v, 4); printf(" 0x%X", v); } printf("\n");
  printf("kRendererChannelLayoutNumChannels:"); for (int i = 0; i < 16; i++) { int32_t v = 0; rd((uintptr_t)base + 0x1d31b8 + 4 * i, &v, 4); printf(" %d", v); } printf("\n");
  fflush(stdout); _exit(0);
} }
