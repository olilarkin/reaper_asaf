#include "unit.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <cmath>
#include <map>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <malloc/malloc.h>

namespace asaf {

// ------------------------------------------------------------------ descriptors

const std::vector<UnitDesc> &unitDescs()
{
  // Channel counts are the largest configuration each Apple unit accepts; smaller layouts use the
  // first channels. The renderers take a second, mono input bus.
  static const std::vector<UnitDesc> d = {
    { "ASAF Object",            'Objt', 1, { 1, 0 },   1, "Positions one mono object in the ASAF scene" },
    { "ASAF Channels",          'Chan', 1, { 16, 0 }, 16, "Channel bed metadata for the ASAF scene" },
    { "ASAF Scene",             'Scen', 1, { 64, 0 }, 64, "Ambisonic scene (up to 7th order) with rotation and spatial filters" },
    { "ASAF Object to Scene",   'Ob2S', 1, { 64, 0 }, 64, "Converts up to 64 objects to an ambisonic scene" },
    { "ASAF Object Renderer",   'ORdr', 2, { 64, 1 }, 64, "Renders up to 64 ASAF objects for monitoring" },
    { "ASAF Channels Renderer", 'CRdr', 2, { 16, 1 }, 64, "Renders an ASAF channel bed for monitoring" },
    { "ASAF Scene Renderer",    'SRdr', 2, { 64, 1 }, 64, "Renders an ASAF ambisonic scene for monitoring" },
    { "ASAF Export",            'Expt', 1, { 12, 0 },  8, "Emits ASAF metadata for bouncing and converts bounces to ASAF / APAC" },
    { "ASAF Panner",            'Pnnr', 1, { 1, 0 },   1, "Controls the first 32 objects, the channel beds and scenes from one place" },
  };
  return d;
}

uint32_t paletteColor(int objectIndex)
{
  static const uint32_t k[10] = { 0xF09632, 0x40C8BE, 0xF0648C, 0xF0CD3C, 0x78DCAA, 0xAA78E6, 0x5ABEF0, 0xEB554B, 0x6EC85A, 0x6E78E6 };
  return k[(objectIndex < 0 ? -objectIndex : objectIndex) % 10];
}

static uint32_t fnv1a(const std::string &s)
{
  uint32_t h = 2166136261u;
  for (unsigned char c : s) { h ^= c; h *= 16777619u; }
  return h ? h : 1;
}

// Parameter metadata (ranges were found by probing; see shim/tools/probe.m) from Resources/params.json.
static std::vector<ParamDef> loadParamDefs(uint32_t subType)
{
  static NSDictionary *all; static dispatch_once_t once;
  dispatch_once(&once, ^{
    Dl_info info; dladdr((void *)&loadParamDefs, &info);
    NSString *path = [[[@(info.dli_fname) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:@"Resources/params.json"];
    NSData *d = [NSData dataWithContentsOfFile:path];
    all = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : @{};
  });
  char cc[5] = { (char)(subType >> 24), (char)(subType >> 16), (char)(subType >> 8), (char)subType, 0 };
  std::vector<ParamDef> out;
  for (NSDictionary *p in (NSArray *)all[@(cc)]) {
    ParamDef d;
    d.ident = [p[@"id"] UTF8String];
    d.min = [p[@"min"] doubleValue]; d.max = [p[@"max"] doubleValue]; d.def = [p[@"def"] doubleValue];
    d.stepped = [p[@"discrete"] boolValue];
    d.hash = fnv1a(d.ident);
    out.push_back(d);
  }
  if (subType == 'Expt') { // meters: read-only
    for (const char *m : { "loudness", "loudnessAverage", "loudnessPeak" }) {
      ParamDef d; d.ident = m; d.min = -50; d.max = 0; d.def = -50; d.readOnly = true; d.hash = fnv1a(d.ident);
      out.push_back(d);
    }
  }
  return out;
}

// ------------------------------------------------------------------ poking around inside the plug-in
//
// Same technique as shim/shim.m ("direct parameter access"): find the plug-in's JUCE parameter objects
// and drive them the way its own code does. Discovery reads memory defensively, and is only accepted if
// every expected parameter is found under its own name.

#define JUCE_FILTER_PROPERTY  0x1a45ffe9 // JUCE's AU wrapper returns { AudioProcessor*, JuceAU* }
#define APVTS_ADAPTERS_OFFSET 0x88       // AudioProcessorValueTreeState: adapter map end node
#define MAPNODE_KEY_OFFSET    0x20       // libc++ map node: key (const char *)
#define MAPNODE_VALUE_OFFSET  0x28       //                  value (ParameterAdapter *)
#define ADAPTER_PARAM_OFFSET  0x30       // ParameterAdapter: RangedAudioParameter &
#define VT_GETVALUE 2                    // juce::AudioProcessorParameter vtable slots
#define VT_SETVALUE 3

static bool safeRead(uintptr_t addr, void *out, size_t n)
{
  mach_vm_size_t got = 0;
  return addr >= 0x1000 && mach_vm_read_overwrite(mach_task_self(), addr, n, (mach_vm_address_t)out, &got) == KERN_SUCCESS && got == n;
}
static bool safeWord(uintptr_t addr, uintptr_t *out) { return safeRead(addr, out, sizeof *out); }
static bool safeCString(uintptr_t addr, char *buf, size_t cap)
{
  memset(buf, 0, cap);
  if (!safeRead(addr, buf, cap - 1))
    for (size_t i = 0; i < cap - 1; i++) { if (!safeRead(addr + i, buf + i, 1)) return false; if (!buf[i]) break; }
  buf[cap - 1] = 0;
  return true;
}

// Look up symbols (including local ones) in a loaded image; optionally require a specific build.
static bool imageSymbols(const struct mach_header_64 *mh, const uint8_t *expectUUID, const char *const *names, uintptr_t *out, int count)
{
  if (!mh || mh->magic != MH_MAGIC_64) return false;
  const struct load_command *lc = (const struct load_command *)(mh + 1);
  const struct symtab_command *symtab = nullptr; const struct segment_command_64 *text = nullptr, *linkedit = nullptr;
  bool uuidOK = expectUUID == nullptr;
  for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
    if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
    else if (lc->cmd == LC_UUID && expectUUID) uuidOK = !memcmp(((const struct uuid_command *)lc)->uuid, expectUUID, 16);
    else if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
      if (!strcmp(sg->segname, SEG_TEXT)) text = sg; else if (!strcmp(sg->segname, SEG_LINKEDIT)) linkedit = sg;
    }
  }
  if (!uuidOK || !symtab || !text || !linkedit) return false;
  const uintptr_t slide = (uintptr_t)mh - text->vmaddr, leBase = slide + linkedit->vmaddr - linkedit->fileoff;
  const struct nlist_64 *syms = (const struct nlist_64 *)(leBase + symtab->symoff);
  const char *strs = (const char *)(leBase + symtab->stroff);
  int found = 0;
  for (int k = 0; k < count; k++) out[k] = 0;
  for (uint32_t i = 0; i < symtab->nsyms && found < count; i++) {
    if ((syms[i].n_type & N_STAB) || (syms[i].n_type & N_TYPE) != N_SECT) continue;
    const char *nm = strs + syms[i].n_un.n_strx;
    for (int k = 0; k < count; k++)
      if (!out[k] && !strcmp(nm, names[k])) { out[k] = syms[i].n_value + slide; found++; break; }
  }
  return found == count;
}

// The Mach-O image a C++ object's class lives in (via its vtable).
static const struct mach_header_64 *imageOfObject(void *object)
{
  uintptr_t vt; Dl_info info;
  if (!object || !safeWord((uintptr_t)object, &vt) || !dladdr((void *)vt, &info)) return nullptr;
  return (const struct mach_header_64 *)info.dli_fbase;
}

static void walkAdapters(uintptr_t node, int depth, const std::map<std::string, int> &index, std::vector<void *> &params, int &found)
{
  if (!node || depth > 48) return;
  uintptr_t left, right, key, adapter, param, vt;
  if (!safeWord(node, &left) || !safeWord(node + 8, &right)) return;
  walkAdapters(left, depth + 1, index, params, found);
  char name[128];
  if (safeWord(node + MAPNODE_KEY_OFFSET, &key) && safeWord(node + MAPNODE_VALUE_OFFSET, &adapter) && safeCString(key, name, sizeof name) &&
      safeWord(adapter + ADAPTER_PARAM_OFFSET, &param) && safeWord(param, &vt) && vt) {
    auto it = index.find(name);
    if (it != index.end() && !params[it->second]) { params[it->second] = (void *)param; found++; }
  }
  walkAdapters(right, depth + 1, index, params, found);
}

bool Unit::resolveParameters()
{
  void *ptrs[2] = { nullptr, nullptr }; UInt32 sz = sizeof ptrs;
  if (AudioUnitGetProperty(m_au, JUCE_FILTER_PROPERTY, kAudioUnitScope_Global, 0, ptrs, &sz) != noErr || !ptrs[0]) return false;
  m_processor = ptrs[0];
  if (m_defs.empty()) return true;

  static const char *const names[] = {
    "__ZTVN4juce28AudioProcessorValueTreeStateE",
    "__ZNK4juce20RangedAudioParameter13convertTo0to1Ef",
    "__ZNK4juce20RangedAudioParameter15convertFrom0to1Ef",
    "__ZN4juce23AudioProcessorParameter34sendValueChangedMessageToListenersEf" };
  uintptr_t addr[4];
  if (!imageSymbols(imageOfObject(m_processor), nullptr, names, addr, 4)) return false;

  const uintptr_t processor = (uintptr_t)m_processor, vtable = addr[0] + 16;
  uintptr_t apvts = 0, w;
  const size_t size = malloc_size(m_processor);
  if (size < 64 || size > (64u << 20)) return false;
  for (size_t off = 0; off + 8 <= size && !apvts; off += 8)   // value tree state held as a member...
    if (safeWord(processor + off, &w) && w == vtable) apvts = processor + off;
  for (size_t off = 0; off + 8 <= size && !apvts; off += 8) { // ...or through a pointer
    uintptr_t inner;
    if (safeWord(processor + off, &w) && w && !(w & 7) && malloc_size((void *)w) >= 0x100 && safeWord(w, &inner) && inner == vtable) apvts = w;
  }
  if (!apvts) return false;

  std::map<std::string, int> index;
  for (int i = 0; i < (int)m_defs.size(); i++) index[m_defs[i].ident] = i;
  std::vector<void *> params(m_defs.size(), nullptr);
  uintptr_t root; int found = 0;
  if (!safeWord(apvts + APVTS_ADAPTERS_OFFSET, &root)) return false;
  walkAdapters(root, 0, index, params, found);
  if (found != (int)m_defs.size()) return false;

  m_params = std::move(params);
  m_to0to1 = (float (*)(void *, float))addr[1];
  m_from0to1 = (float (*)(void *, float))addr[2];
  m_sendChanged = (void (*)(void *, float))addr[3];
  return true;
}

double Unit::directGet(int i) const
{
  void *p = m_params[i];
  const float norm = ((float (*)(void *))(*(void ***)p)[VT_GETVALUE])(p);
  return m_from0to1(p, norm);
}

void Unit::directSet(int i, double v)
{
  void *p = m_params[i];
  const float norm = m_to0to1(p, (float)v);
  ((void (*)(void *, float))(*(void ***)p)[VT_SETVALUE])(p, norm);
  m_sendChanged(p, norm);
}

// juce::String is returned through a hidden pointer because it has a non-trivial destructor; mirror that
// here so the compiler uses the same calling convention. (Its only member is a pointer to UTF-8 text.)
namespace {
struct JuceStringResult {
  const char *text = nullptr;
  JuceStringResult() {}
  JuceStringResult(const JuceStringResult &o) : text(o.text) {}
  ~JuceStringResult() {} // deliberately does not release: we don't have JUCE's allocator bookkeeping
};
}
#define VT_GETTEXT 10 // juce::AudioProcessorParameter::getText(float normalisedValue, int maxLength) const

std::string Unit::pluginText(int i, double value) const
{
  if (i < 0 || i >= (int)m_params.size() || !m_params[i]) return "";
  void *p = m_params[i];
  uintptr_t fn = 0;
  if (!safeWord((uintptr_t)(*(void ***)p + VT_GETTEXT), &fn) || !fn) return "";
  const float norm = m_to0to1(p, (float)value);
  JuceStringResult s = ((JuceStringResult (*)(void *, float, int))fn)(p, norm, 256);
  char buf[256];
  if (!s.text || !safeCString((uintptr_t)s.text, buf, sizeof buf)) return "";
  return buf;
}

// What the renderers' "Channel Output Type" values mean. The plug-ins only show numbers for these; the
// names come from the layout table inside the renderer (Mono, Stereo, LCR, Quad, 5.0, ... 9.1.6) and
// were matched to values by rendering an object at known positions through each type and seeing which
// output channels responded. The list is ordered by channel count: 2,2,3,4,5,6,7,8,8,10,10,12,14,16.
static const char *const kChannelOutputTypes[15] = {
  "Binaural", "Stereo", "LCR", "Quad", "5.0", "5.1", "7.0", "5.1.2", "7.1", "5.1.4", "7.1.2", "7.1.4", "7.1.6", "9.1.6", "Custom Layout" };

const std::vector<std::string> &Unit::valueLabels(int i) const
{
  static const std::vector<std::string> none;
  static std::map<std::pair<uint32_t, std::string>, std::vector<std::string>> cache; // per unit type + parameter
  if (i < 0 || i >= (int)m_defs.size()) return none;
  const ParamDef &d = m_defs[i];
  const int count = (int)std::lround(d.max - d.min) + 1;
  if (!d.stepped || d.readOnly || count < 2 || count > 64) return none;
  const auto key = std::make_pair(m_desc.subType, d.ident);
  auto it = cache.find(key);
  if (it != cache.end()) return it->second;
  std::vector<std::string> labels;
  if (d.ident == "channelOutputType" && count == 15) labels.assign(kChannelOutputTypes, kChannelOutputTypes + 15);
  else
    for (int k = 0; k < count; k++) {
      std::string s = pluginText(i, d.min + k);
      if (s.empty()) { labels.clear(); break; }
      labels.push_back(s);
    }
  return cache.emplace(key, std::move(labels)).first->second;
}

std::string Unit::valueText(int i, double value) const
{
  if (i < 0 || i >= (int)m_defs.size()) return "";
  const ParamDef &d = m_defs[i];
  const std::vector<std::string> &labels = valueLabels(i);
  const long k = std::lround(value - d.min);
  if (!labels.empty() && k >= 0 && k < (long)labels.size()) return labels[(size_t)k];
  char buf[48];
  if (d.stepped) snprintf(buf, sizeof buf, "%ld", std::lround(value)); else snprintf(buf, sizeof buf, "%.2f", value);
  return buf;
}

// ------------------------------------------------------------------ lifetime

static std::vector<Unit *> &live() { static std::vector<Unit *> v; return v; }
const std::vector<Unit *> &liveUnits() { return live(); }

Unit::Unit(const UnitDesc &desc) : m_desc(desc) {}

Unit::~Unit()
{
  auto &l = live();
  l.erase(std::remove(l.begin(), l.end(), this), l.end());
  if (m_au) {
    if (m_initialized) AudioUnitUninitialize(m_au);
    AudioComponentInstanceDispose(m_au);
  }
}

bool Unit::open(std::string *err)
{
  // Apple's components are flagged "unsearchable": only an exact description finds them.
  AudioComponentDescription d = { kAudioUnitType_Effect, m_desc.subType, 'Appl', 0, 0 };
  AudioComponent c = AudioComponentFindNext(nullptr, &d);
  if (!c || AudioComponentInstanceNew(c, &m_au) != noErr || !m_au) {
    if (err) *err = std::string("Apple's ") + m_desc.name + " AudioUnit is not installed.";
    m_au = nullptr;
    return false;
  }
  m_defs = loadParamDefs(m_desc.subType);
  if (!resolveParameters()) {
    // Unknown build of the Apple unit: still usable as an effect, just without parameters.
    m_defs.clear(); m_params.clear();
  }
  const size_t n = m_defs.size();
  m_values.reset(new std::atomic<float>[n ? n : 1]);
  m_dirty.reset(new std::atomic<bool>[n ? n : 1]);
  m_toHost.reset(new std::atomic<uint8_t>[n ? n : 1]);
  for (size_t i = 0; i < n; i++) { m_values[i] = (float)m_defs[i].def; m_dirty[i] = false; m_toHost[i] = 0; }
  refreshFromPlugin(false);

  HostCallbackInfo cb = {};
  cb.hostUserData = this;
  cb.transportStateProc = &Unit::transportCallback;
  AudioUnitSetProperty(m_au, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &cb, sizeof cb);

  live().push_back(this);
  return true;
}

int Unit::paramIndex(const char *ident) const
{
  for (int i = 0; i < (int)m_defs.size(); i++) if (m_defs[i].ident == ident) return i;
  return -1;
}

int Unit::paramIndexForHash(uint32_t hash) const
{
  for (int i = 0; i < (int)m_defs.size(); i++) if (m_defs[i].hash == hash) return i;
  return -1;
}

// ------------------------------------------------------------------ parameters

void Unit::markToHost(int i, uint8_t bits)
{
  m_toHost[i].fetch_or(bits, std::memory_order_acq_rel);
  m_anyToHost.store(true, std::memory_order_release);
}

void Unit::setFromHost(int index, double v)
{
  if (index < 0 || index >= (int)m_defs.size() || m_defs[index].readOnly) return;
  const ParamDef &d = m_defs[index];
  v = std::min(d.max, std::max(d.min, v));
  if (d.stepped) v = std::round(v);
  m_values[index].store((float)v, std::memory_order_relaxed);
  m_dirty[index].store(true, std::memory_order_release);
  m_anyDirty.store(true, std::memory_order_release);
}

void Unit::setFromUI(int index, double v)
{
  if (index < 0 || index >= (int)m_defs.size() || m_defs[index].readOnly) return;
  const ParamDef &d = m_defs[index];
  v = std::min(d.max, std::max(d.min, v));
  if (d.stepped) v = std::round(v);
  m_values[index].store((float)v, std::memory_order_relaxed);
  m_dirty[index].store(false, std::memory_order_release);
  directSet(index, v);
  markToHost(index, 1);
}

void Unit::gesture(int index, bool begin)
{
  if (index >= 0 && index < (int)m_defs.size()) markToHost(index, begin ? 2 : 4);
}

void Unit::refreshFromPlugin(bool notifyHost)
{
  for (int i = 0; i < (int)m_defs.size(); i++) {
    if (m_dirty[i].load(std::memory_order_acquire)) continue;
    const ParamDef &d = m_defs[i];
    double v = directGet(i);
    if (d.stepped) v = std::round(v);
    const double old = m_values[i].load(std::memory_order_relaxed);
    const double tol = 1e-5 * std::max(1.0, d.max - d.min); // normalisation round-trip noise
    if (std::fabs(v - old) <= tol) continue;
    m_values[i].store((float)v, std::memory_order_relaxed);
    if (notifyHost && !d.readOnly) markToHost(i, 1);
  }
}

bool Unit::applyDirty()
{
  if (!m_anyDirty.exchange(false, std::memory_order_acq_rel)) return false;
  for (int i = 0; i < (int)m_defs.size(); i++)
    if (m_dirty[i].exchange(false, std::memory_order_acq_rel)) directSet(i, m_values[i].load(std::memory_order_relaxed));
  return true;
}

// This is what JUCE's own AudioUnit wrapper does when a host calls AudioUnitSetParameter, which hosts
// do from their audio thread: setValue() then sendValueChangedMessageToListeners().
void Unit::applyFromHost()
{
  if (!m_au || m_defs.empty()) return;
  if (applyDirty()) m_refreshSoon.store(true, std::memory_order_release);
}

void Unit::tick()
{
  if (!m_au || m_defs.empty()) return;
  m_tick++;
  const bool applied = applyDirty(); // values that arrived through flush(), outside process()
  if (m_refreshSoon.exchange(false, std::memory_order_acq_rel) || applied) {
    refreshFromPlugin(true);
  } else if (m_tick % 8 == 0) {
    refreshFromPlugin(true); // changes made by the plug-in itself, and meters
  }
}

// ------------------------------------------------------------------ state

bool Unit::saveState(std::vector<uint8_t> &out)
{
  tick();
  CFPropertyListRef pl = nullptr; UInt32 sz = sizeof pl;
  if (AudioUnitGetProperty(m_au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &pl, &sz) != noErr || !pl) return false;
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:CFBridgingRelease(pl) format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  if (!data) return false;
  out.assign((const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length);
  return true;
}

bool Unit::loadState(const uint8_t *bytes, size_t size)
{
  id pl = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:bytes length:size] options:0 format:nullptr error:nil];
  if (![pl isKindOfClass:[NSDictionary class]]) return false;
  CFPropertyListRef ref = (__bridge CFPropertyListRef)pl;
  if (AudioUnitSetProperty(m_au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &ref, sizeof ref) != noErr) return false;
  for (int i = 0; i < (int)m_defs.size(); i++) m_dirty[i].store(false, std::memory_order_release);
  refreshFromPlugin(true);
  return true;
}

// ------------------------------------------------------------------ audio

static AudioStreamBasicDescription floatFormat(double sr, int ch)
{
  AudioStreamBasicDescription d = {};
  d.mSampleRate = sr; d.mFormatID = kAudioFormatLinearPCM;
  d.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
  d.mBytesPerPacket = d.mBytesPerFrame = 4; d.mFramesPerPacket = 1; d.mChannelsPerFrame = (UInt32)ch; d.mBitsPerChannel = 32;
  return d;
}

bool Unit::activate(double sampleRate, uint32_t maxFrames, std::string *err)
{
  deactivate();
  OSStatus e = noErr;
  for (int b = 0; b < m_desc.numInputs && e == noErr; b++) {
    AudioStreamBasicDescription f = floatFormat(sampleRate, m_desc.inChannels[b]);
    e = AudioUnitSetProperty(m_au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, (UInt32)b, &f, sizeof f);
    AURenderCallbackStruct cb = { &Unit::inputCallback, this };
    AudioUnitSetProperty(m_au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, (UInt32)b, &cb, sizeof cb);
    m_scratch[b].assign((size_t)m_desc.inChannels[b], std::vector<float>(maxFrames, 0.f));
  }
  if (e == noErr) {
    AudioStreamBasicDescription f = floatFormat(sampleRate, m_desc.outChannels);
    e = AudioUnitSetProperty(m_au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f);
  }
  UInt32 mf = maxFrames;
  AudioUnitSetProperty(m_au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mf, sizeof mf);
  if (e == noErr) e = AudioUnitInitialize(m_au);
  if (e != noErr) {
    if (err) *err = std::string(m_desc.name) + " could not be initialised (" + std::to_string((int)e) + ").";
    return false;
  }
  m_initialized = true; m_maxFrames = maxFrames; m_sampleTime = 0;
  m_discard.assign(maxFrames, 0.f);
  Float64 lat = 0; UInt32 sz = sizeof lat;
  m_latency = AudioUnitGetProperty(m_au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &lat, &sz) == noErr ? (uint32_t)std::lround(lat * sampleRate) : 0;
  return true;
}

void Unit::deactivate()
{
  if (m_au && m_initialized) AudioUnitUninitialize(m_au);
  m_initialized = false;
}

OSStatus Unit::inputCallback(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32 bus, UInt32 frames, AudioBufferList *io)
{
  Unit *u = (Unit *)ref;
  if (bus > 1) return kAudioUnitErr_InvalidElement;
  auto &src = u->m_scratch[bus];
  for (UInt32 c = 0; c < io->mNumberBuffers; c++) {
    AudioBuffer &b = io->mBuffers[c];
    float *s = c < src.size() ? src[c].data() : u->m_discard.data();
    if (b.mData) memcpy(b.mData, s, frames * sizeof(float)); else b.mData = s;
    b.mDataByteSize = frames * sizeof(float);
  }
  return noErr;
}

OSStatus Unit::transportCallback(void *ref, Boolean *isPlaying, Boolean *changed, Float64 *sampleInTimeLine, Boolean *isCycling, Float64 *cycleStart, Float64 *cycleEnd)
{
  Unit *u = (Unit *)ref;
  if (isPlaying) *isPlaying = u->m_playing.load(std::memory_order_relaxed);
  if (changed) *changed = false;
  if (sampleInTimeLine) *sampleInTimeLine = u->m_sampleTime;
  if (isCycling) *isCycling = false;
  if (cycleStart) *cycleStart = 0;
  if (cycleEnd) *cycleEnd = 0;
  return noErr;
}

void Unit::process(const float *const *const *inputs, const int *inputChannelCounts, float *const *outputs, int outputChannelCount, uint32_t frames)
{
  uint32_t done = 0;
  while (done < frames) {
    const uint32_t n = std::min(frames - done, m_maxFrames ? m_maxFrames : frames);
    bool ok = m_initialized && n > 0;
    if (ok) {
      for (int b = 0; b < m_desc.numInputs; b++) {
        auto &dst = m_scratch[b];
        for (size_t c = 0; c < dst.size(); c++) {
          const float *src = (inputs && inputs[b] && (int)c < inputChannelCounts[b]) ? inputs[b][c] : nullptr;
          if (src) memcpy(dst[c].data(), src + done, n * sizeof(float)); else memset(dst[c].data(), 0, n * sizeof(float));
        }
      }
      const int nout = m_desc.outChannels;
      struct { AudioBufferList list; AudioBuffer more[63]; } abl;
      abl.list.mNumberBuffers = (UInt32)nout;
      for (int c = 0; c < nout; c++) {
        AudioBuffer &b = abl.list.mBuffers[c];
        b.mNumberChannels = 1; b.mDataByteSize = n * sizeof(float);
        b.mData = c < outputChannelCount && outputs[c] ? (void *)(outputs[c] + done) : nullptr;
      }
      AudioTimeStamp ts = {}; ts.mFlags = kAudioTimeStampSampleTimeValid; ts.mSampleTime = m_sampleTime;
      AudioUnitRenderActionFlags flags = 0;
      ok = AudioUnitRender(m_au, &flags, &ts, 0, n, &abl.list) == noErr;
      if (ok)
        for (int c = 0; c < nout && c < outputChannelCount; c++) {
          void *d = abl.list.mBuffers[c].mData;
          if (outputs[c] && d && d != (void *)(outputs[c] + done)) memcpy(outputs[c] + done, d, n * sizeof(float));
        }
      for (int c = nout; c < outputChannelCount; c++) if (outputs[c]) memset(outputs[c] + done, 0, n * sizeof(float));
    }
    if (!ok) for (int c = 0; c < outputChannelCount; c++) if (outputs[c]) memset(outputs[c] + done, 0, n * sizeof(float));
    m_sampleTime += n;
    done += n ? n : frames;
  }
}

// ------------------------------------------------------------------ ASAF Export: hidden Convert button

#if defined(__arm64__)
struct ExportBuild { uint8_t uuid[16]; uint32_t dialogOffset, convertOffset; };  // ExportProcessor -> BounceDialog*, BounceDialog -> convert juce::Button*
static const ExportBuild kExportBuilds[] = {
  { { 0xA0,0x4C,0x20,0xB9,0x84,0xC4,0x30,0x65,0xBB,0x8A,0xA0,0xB6,0x73,0x7D,0x3E,0x2E }, 0xe98, 0x450 },  // v2.1.8 arm64
  { { 0xEC,0x4B,0xAC,0xBF,0xF4,0x89,0x35,0x15,0x8F,0xD6,0x2B,0xA8,0xF7,0x8A,0x05,0x57 }, 0xd98, 0x450 },  // v2.1.13 arm64
};
#endif

int exportPressConvert()
{
#if defined(__arm64__)
  Unit *u = nullptr; int n = 0;
  for (Unit *x : live()) if (x->desc().subType == 'Expt') { u = x; n++; }
  if (n != 1) return 0;
  static const char *const names[] = { "__ZN12BounceDialog13buttonClickedEPN4juce6ButtonE", "__ZTV12BounceDialog", "__ZTV15ExportProcessor" };
  uintptr_t addr[3];
  uintptr_t *processor = (uintptr_t *)u->juceProcessor();
  const ExportBuild *build = nullptr;
  if (processor)
    for (const ExportBuild &b : kExportBuilds)
      if (imageSymbols(imageOfObject(processor), b.uuid, names, addr, 3)) { build = &b; break; }
  if (!build) return -2;
  if (processor[0] != addr[2] + 16) return -3;
  uintptr_t *dialog = *(uintptr_t **)((char *)processor + build->dialogOffset);
  if (!dialog || dialog[0] != addr[1] + 16) return -3;
  void *button = *(void **)((char *)dialog + build->convertOffset);
  if (!button) return -3;
  ((void (*)(void *, void *))addr[0])(dialog, button);
  return 1;
#else
  return -1;
#endif
}

} // namespace asaf

// ------------------------------------------------------------------ control API
//
// Same C interface as ASAFShim.component, so reaper_asaf can drive either. Main thread only.

using asaf::Unit;
#define ASAF_API extern "C" __attribute__((visibility("default")))

ASAF_API int ASAFShim_APIVersion(void) { return 3; }

ASAF_API int ASAFShim_Count(uint32_t subType)
{
  int n = 0;
  for (Unit *u : asaf::liveUnits()) if (u->desc().subType == subType) n++;
  return n;
}

ASAF_API int ASAFShim_SetParam(uint32_t subType, const char *paramID, float value, int momentary)
{
  int done = 0;
  const std::vector<Unit *> units = asaf::liveUnits(); // copy: setting a parameter can run plug-in code
  for (Unit *u : units) {
    if (u->desc().subType != subType) continue;
    const int i = u->paramIndex(paramID);
    if (i < 0) continue;
    u->setFromUI(i, value);
    u->tick();
    done++;
  }
  (void)momentary; // values are always read back from the plug-in, so triggers reset themselves
  return done;
}

ASAF_API int ASAFShim_GetParam(uint32_t subType, const char *paramID, float *out)
{
  for (Unit *u : asaf::liveUnits()) {
    if (u->desc().subType != subType) continue;
    const int i = u->paramIndex(paramID);
    if (i >= 0) { *out = (float)u->value(i); return 1; }
  }
  return 0;
}

ASAF_API int ASAFShim_IsDirect(uint32_t subType)
{
  for (Unit *u : asaf::liveUnits()) if (u->desc().subType == subType) return u->paramCount() > 0 ? 1 : 0;
  return -1;
}

ASAF_API int ASAFShim_ExportPressConvert(void) { return asaf::exportPressConvert(); }
