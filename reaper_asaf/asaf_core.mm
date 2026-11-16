#include "asaf_core.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

namespace asaf {

// ------------------------------------------------------------------ shim API

Shim &shim() { static Shim s; return s; }

// The control API is provided by ASAF.clap and by the older ASAFShim.component. A project may use
// either (or both), so talk to every one that is installed.
namespace {
struct Backend {
  int (*Count)(uint32_t); int (*SetParam)(uint32_t, const char *, float, int);
  int (*GetParam)(uint32_t, const char *, float *); int (*PressConvert)(void);
};
std::vector<Backend> &backends() { static std::vector<Backend> v; return v; }

int allCount(uint32_t t) { int n = 0; for (auto &b : backends()) n += b.Count(t); return n; }
int allSetParam(uint32_t t, const char *id, float v, int m) { int n = 0; for (auto &b : backends()) n += b.SetParam(t, id, v, m); return n; }
int allGetParam(uint32_t t, const char *id, float *out) { for (auto &b : backends()) if (b.GetParam && b.GetParam(t, id, out)) return 1; return 0; }
int allPressConvert() { for (auto &b : backends()) if (b.PressConvert && b.Count('Expt') == 1) return b.PressConvert(); return 0; }
}

bool Shim::load()
{
  if (ok()) return true;
  NSArray<NSString *> *paths = @[
    [@"~/Library/Audio/Plug-Ins/CLAP/ASAF.clap/Contents/MacOS/ASAF" stringByExpandingTildeInPath],
    @"/Library/Audio/Plug-Ins/CLAP/ASAF.clap/Contents/MacOS/ASAF",
    [@"~/Library/Audio/Plug-Ins/Components/ASAFShim.component/Contents/MacOS/ASAFShim" stringByExpandingTildeInPath],
    @"/Library/Audio/Plug-Ins/Components/ASAFShim.component/Contents/MacOS/ASAFShim" ];
  bool pressConvert = false;
  for (NSString *p in paths) {
    // dlopen by path returns the same image the host loaded, so we share its instance registry.
    void *h = dlopen(p.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) continue;
    int (*ver)(void) = (int (*)(void))dlsym(h, "ASAFShim_APIVersion");
    if (!ver || ver() < 1) continue;
    Backend b = { (int (*)(uint32_t))dlsym(h, "ASAFShim_Count"), (int (*)(uint32_t, const char *, float, int))dlsym(h, "ASAFShim_SetParam"),
                  (int (*)(uint32_t, const char *, float *))dlsym(h, "ASAFShim_GetParam"), (int (*)(void))dlsym(h, "ASAFShim_ExportPressConvert") };
    if (!b.Count || !b.SetParam) continue;
    backends().push_back(b);
    pressConvert = pressConvert || b.PressConvert;
  }
  if (backends().empty()) return false;
  Count = allCount; SetParam = allSetParam; GetParam = allGetParam;
  ExportPressConvert = pressConvert ? allPressConvert : nullptr;
  return true;
}

// ------------------------------------------------------------------ bounce writer

static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }

// Header layout (fixed 128 bytes before sample data):
//   RIFF/RF64 hdr 12 | JUNK-or-ds64 chunk 8+28 | fmt (extensible) 8+40 | pad chunk 8+16 | data hdr 8
static void writeHeader(FILE *f, int nch, int srate, int64_t dataBytes)
{
  const bool rf64 = dataBytes + 120 > 0xFFFFFFF0LL;
  fseeko(f, 0, SEEK_SET);
  fwrite(rf64 ? "RF64" : "RIFF", 4, 1, f);
  put32(f, rf64 ? 0xFFFFFFFFu : (uint32_t)(dataBytes + 120));
  fwrite("WAVE", 4, 1, f);
  if (rf64) {
    fwrite("ds64", 4, 1, f); put32(f, 28);
    uint64_t riffSize = (uint64_t)dataBytes + 120, dataSize = (uint64_t)dataBytes, sampleCount = dataSize / (4 * (uint64_t)nch);
    fwrite(&riffSize, 8, 1, f); fwrite(&dataSize, 8, 1, f); fwrite(&sampleCount, 8, 1, f); put32(f, 0);
  } else {
    fwrite("JUNK", 4, 1, f); put32(f, 28);
    char z[28] = {0}; fwrite(z, 28, 1, f);
  }
  fwrite("fmt ", 4, 1, f); put32(f, 40);
  put16(f, 0xFFFE);                       // WAVE_FORMAT_EXTENSIBLE
  put16(f, (uint16_t)nch); put32(f, (uint32_t)srate);
  put32(f, (uint32_t)(srate * nch * 4)); put16(f, (uint16_t)(nch * 4)); put16(f, 32);
  put16(f, 22); put16(f, 32); put32(f, 0); // cbSize, valid bits, channel mask (none: discrete)
  static const unsigned char kFloatGUID[16] = { 0x03,0,0,0, 0,0, 0x10,0, 0x80,0, 0,0xAA,0,0x38,0x9B,0x71 };
  fwrite(kFloatGUID, 16, 1, f);
  fwrite("PAD ", 4, 1, f); put32(f, 16); { char z[16] = {0}; fwrite(z, 16, 1, f); }
  fwrite("data", 4, 1, f); put32(f, rf64 ? 0xFFFFFFFFu : (uint32_t)dataBytes);
}

bool BounceWriter::open(const char *path, int nch, int srate)
{
  close();
  m_fp = fopen(path, "wb");
  if (!m_fp) return false;
  setvbuf(m_fp, nullptr, _IOFBF, 1 << 20);
  m_nch = nch; m_srate = srate; m_frames = 0; m_dataBytes = 0;
  writeHeader(m_fp, nch, srate, 0);
  return true;
}

void BounceWriter::write(double **samples, int len, int nch, int offset, int spacing)
{
  if (!m_fp || len <= 0) return;
  m_buf.resize((size_t)len * m_nch);
  for (int c = 0; c < m_nch; c++) {
    float *o = m_buf.data() + c;
    if (c < nch && samples[c]) {
      const double *in = samples[c] + offset;
      for (int i = 0; i < len; i++) { o[(size_t)i * m_nch] = (float)*in; in += spacing; }
    } else {
      for (int i = 0; i < len; i++) o[(size_t)i * m_nch] = 0.f;
    }
  }
  fwrite(m_buf.data(), sizeof(float), m_buf.size(), m_fp);
  m_frames += len; m_dataBytes += (int64_t)len * m_nch * 4;
}

bool BounceWriter::close()
{
  if (!m_fp) return true;
  writeHeader(m_fp, m_nch, m_srate, m_dataBytes);
  bool ok = fclose(m_fp) == 0;
  m_fp = nullptr;
  return ok;
}

// ------------------------------------------------------------------ conversion

bool isASAFFile(const char *path, int *outChannels)
{
  FILE *f = fopen(path, "rb");
  if (!f) return false;
  bool found = false; char id[4]; uint32_t sz; char hdr[12];
  if (fread(hdr, 12, 1, f) == 1 && !memcmp(hdr + 8, "WAVE", 4)) {
    uint64_t dataSize64 = 0;
    while (fread(id, 4, 1, f) == 1 && fread(&sz, 4, 1, f) == 1) {
      uint64_t skip = sz;
      if (!memcmp(id, "ds64", 4)) { uint64_t v[2]; if (fread(v, 16, 1, f) == 1) dataSize64 = v[1]; skip = sz - 16; }
      else if (!memcmp(id, "fmt ", 4)) { uint16_t v[2]; if (fread(v, 4, 1, f) == 1 && outChannels) *outChannels = v[1]; skip = sz - 4; }
      else if (!memcmp(id, "data", 4) && sz == 0xFFFFFFFFu) skip = dataSize64;
      else if (!memcmp(id, "AIAM", 4)) { found = true; }
      if (fseeko(f, (off_t)(skip + (skip & 1)), SEEK_CUR)) break;
    }
  }
  fclose(f);
  return found;
}

static bool requireOneExport(std::string *err)
{
  if (!shim().load()) { if (err) *err = "Neither ASAF.clap nor ASAFShim.component is installed. Build one (asaf_clap/build.sh) and restart REAPER."; return false; }
  int n = shim().Count(kExport);
  if (n == 1) return true;
  if (err) *err = n == 0 ? "No ASAF Export plug-in is loaded. Add ASAF Export to the export bus (run \"ASAF: Set up session\")."
                         : "More than one ASAF Export plug-in is loaded; keep exactly one in the project.";
  return false;
}

bool armExport(bool armed, std::string *err)
{
  if (!requireOneExport(err)) return false;
  return shim().SetParam(kExport, "bounceArmed", armed ? 1.f : 0.f, 0) == 1;
}

bool convertBounceToASAF(const char *path, std::string *err)
{
  if (!requireOneExport(err)) return false;
  int nch = 0;
  isASAFFile(path, &nch);

  // ASAF Export (headless build) takes the file to convert from this preference, then converts when
  // its createAIAFile parameter goes to 1.
  CFStringRef domain = CFSTR("com.Apple.AIAExport"), key = CFSTR("sdkBounceFile");
  CFPreferencesSetAppValue(key, (__bridge CFStringRef)@(path), domain);
  CFPreferencesAppSynchronize(domain);

  shim().SetParam(kExport, "createAIAFile", 1.f, 1);

  // The conversion normally completes inside the call above; allow for it finishing asynchronously.
  bool ok = isASAFFile(path, nullptr);
  off_t lastSize = -1; int idle = 0;
  while (!ok && idle < 50) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    struct stat st; off_t size = stat(path, &st) == 0 ? st.st_size : -1;
    idle = (size == lastSize) ? idle + 1 : 0; lastSize = size;
    ok = isASAFFile(path, nullptr);
  }
  CFPreferencesSetAppValue(key, nullptr, domain);
  CFPreferencesAppSynchronize(domain);

  if (!ok && err) {
    char msg[512];
    snprintf(msg, sizeof msg,
             "ASAF Export did not convert the file (%d channels).\n\n"
             "It expects exactly one channel per enabled object (plus scene and bed channels), followed by "
             "its own 8 metadata channels, rendered at 48 kHz with a 1024-sample block size.", nch);
    *err = msg;
  }
  return ok;
}

// ------------------------------------------------------------------ APAC

std::string apacPathFor(const char *path)
{
  return [[@(path) stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"].fileSystemRepresentation;
}

// A finished MP4 has a top-level 'moov' box (written when the encoder closes the file).
static bool mp4IsComplete(const char *path)
{
  FILE *f = fopen(path, "rb");
  if (!f) return false;
  bool moov = false; unsigned char h[16];
  while (fread(h, 1, 8, f) == 8) {
    uint64_t size = ((uint64_t)h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
    uint64_t hdr = 8;
    if (size == 1) { if (fread(h + 8, 1, 8, f) != 8) break; size = 0; for (int i = 8; i < 16; i++) size = (size << 8) | h[i]; hdr = 16; }
    if (!memcmp(h + 4, "moov", 4)) { moov = true; break; }
    if (size < hdr || fseeko(f, (off_t)(size - hdr), SEEK_CUR)) break;
  }
  fclose(f);
  return moov;
}

static off_t fileSize(const char *p) { struct stat st; return stat(p, &st) == 0 ? st.st_size : -1; }

bool convertBounceToASAFAndAPAC(const char *path, std::string *err, std::string *apacErr)
{
  if (!requireOneExport(err)) return false;
  auto fallback = [&](const char *why) {
    if (apacErr) *apacErr = why;
    return convertBounceToASAF(path, err);
  };
  if (!shim().ExportPressConvert) return fallback("The installed ASAF plug-ins are too old for APAC export; rebuild them with asaf_clap/build.sh.");

  const std::string mp4 = apacPathFor(path);
  remove(mp4.c_str());

  // ASAF Export's APAC encoder only runs from its (hidden) Convert button, straight after that same
  // button press has written the BWF. The button needs the session description and file path that the
  // createAIAFile parameter fills in -- but that parameter also converts the file there and then. So:
  // fill them in while the file is briefly out of the way (the plug-in sees "file does not exist" and
  // stops), put the file back, then press Convert, which does BWF + APAC in one go.
  const std::string hidden = std::string(path) + ".asafbounce";
  if (rename(path, hidden.c_str()) != 0) return fallback("Could not prepare the bounce file for APAC export.");
  CFStringRef domain = CFSTR("com.Apple.AIAExport"), key = CFSTR("sdkBounceFile");
  CFPreferencesSetAppValue(key, (__bridge CFStringRef)@(path), domain);
  CFPreferencesAppSynchronize(domain);
  shim().SetParam(kExport, "createAIAFile", 1.f, 1);
  CFPreferencesSetAppValue(key, nullptr, domain);
  CFPreferencesAppSynchronize(domain);
  if (rename(hidden.c_str(), path) != 0) { if (err) *err = "Could not restore the bounce file; it is at " + hidden; return false; }

  shim().SetParam(kExport, "createAPACFile", 1.f, 0);
  int rc = shim().ExportPressConvert();
  if (rc != 1) {
    shim().SetParam(kExport, "createAPACFile", 0.f, 0);
    return fallback(rc == -1 ? "APAC export needs REAPER running natively on Apple silicon."
                  : rc == -2 ? "APAC export only supports ASAF Export v2.1.8 and v2.1.13; a different version is installed."
                             : "APAC export is not available with this ASAF Export plug-in.");
  }

  // The work now runs on a plug-in thread. Wait (without running the event loop) until the BWF and the
  // MP4 are complete, giving up if nothing has changed on disk for a while.
  const int kIdleLimit = 300; // x 100 ms
  bool bwf = false, apac = false; int idle = 0; off_t lastA = -2, lastB = -2;
  while (idle < kIdleLimit) {
    usleep(100000);
    if (!bwf) bwf = isASAFFile(path, nullptr);
    if (bwf && !apac) apac = mp4IsComplete(mp4.c_str());
    if (bwf && apac) break;
    off_t a = fileSize(path), b = fileSize(mp4.c_str());
    idle = (a == lastA && b == lastB) ? idle + 1 : 0; lastA = a; lastB = b;
    if (!bwf && idle >= 50) break; // BWF conversion fails fast; don't wait the full limit
  }
  if (apac) usleep(300000); // let the plug-in thread finish closing the file
  shim().SetParam(kExport, "createAPACFile", 0.f, 0);

  if (!bwf) {
    if (err) {
      int nch = 0; isASAFFile(path, &nch);
      char msg[512];
      snprintf(msg, sizeof msg,
               "ASAF Export did not convert the file (%d channels).\n\n"
               "It expects exactly one channel per enabled object (plus scene and bed channels), followed by "
               "its own 8 metadata channels, rendered at 48 kHz with a 1024-sample block size.", nch);
      *err = msg;
    }
    return false;
  }
  if (!apac) { remove(mp4.c_str()); if (apacErr) *apacErr = "ASAF Export wrote the ASAF BWF but its APAC encoder did not produce a file."; }
  return true;
}

} // namespace asaf
