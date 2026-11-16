// ASAFShim — makes Apple's ASAF AudioUnits usable in hosts like REAPER.
//
// 1. The ASAF units are registered with kAudioComponentFlag_Unsearchable, so
//    hosts that enumerate AUs never see them. This bundle re-registers them
//    (manufacturer 'ASFs') and forwards to the real factory functions.
// 2. The units are headless: no editor and no published AU parameters. Their
//    controls live in a hidden JUCE parameter tree that is only reachable via
//    the saved state (kAudioUnitProperty_ClassInfo). The shim wraps the
//    plug-in interface and publishes those controls as ordinary AU parameters
//    (metadata in Resources/params.json), writing changes back via the state.
// 3. The units advertise a Cocoa UI that returns nil; the shim hides that
//    property so hosts fall back to their generic parameter UI.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <malloc/malloc.h>

#define NSLOT 0x30
static inline int slotFor(SInt16 sel) { return sel >= 0x100 ? 0x20 + (sel - 0x100) : sel; }

typedef struct { CFStringRef name; float min, max, def; bool discrete; } ParamDef;
typedef struct { int count; ParamDef *defs; void *index; /* NSDictionary id -> NSNumber */ } ParamTable;

typedef struct Shim {
    AudioComponentPlugInInterface iface; // must be first
    AudioComponentPlugInInterface *real;
    AudioComponentMethod table[NSLOT];
    AudioComponentInstance instance;
    OSType subType;
    const ParamTable *params;
    _Atomic float *values;
    _Atomic bool *dirty;
    _Atomic bool anyDirty;
    bool closed;
    CFTypeRef info;          // NSDictionary: last ClassInfo from the plug-in (template for writes)
    CFTypeRef blob;          // NSMutableData: shim's copy of jucePluginState
    CFAbsoluteTime nextFlush;
    // Direct access to the plug-in's JUCE parameter objects (see "direct parameter access").
    bool direct;
    void **dparam;                       // per parameter: juce::RangedAudioParameter*
    float (*convTo0to1)(void *, float);  // juce::RangedAudioParameter::convertTo0to1
    float (*convFrom0to1)(void *, float);
    void (*sendChanged)(void *, float);  // juce::AudioProcessorParameter::sendValueChangedMessageToListeners
    unsigned tick;
    pthread_mutex_t lock;
    dispatch_source_t timer;
} Shim;

typedef OSStatus (*GetPropInfoFn)(void *, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UInt32 *, Boolean *);
typedef OSStatus (*GetPropFn)(void *, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);
typedef OSStatus (*SetPropFn)(void *, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
typedef OSStatus (*GetParamFn)(void *, AudioUnitParameterID, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue *);
typedef OSStatus (*SetParamFn)(void *, AudioUnitParameterID, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue, UInt32);
typedef OSStatus (*SchedFn)(void *, const AudioUnitParameterEvent *, UInt32);
typedef long (*GenericFn)(void *, long, long, long, long, long, long, long);

#define REAL(s, sel, type) ((type)(s)->table[slotFor(sel)])

// ---------------------------------------------------------------- param metadata

static const ParamTable *paramTableFor(OSType subType)
{
    static NSDictionary *all; static NSMutableDictionary *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info; dladdr((void *)paramTableFor, &info);
        NSString *path = [[[@(info.dli_fname) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"Resources/params.json"];
        NSData *d = [NSData dataWithContentsOfFile:path];
        all = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : @{};
        cache = [NSMutableDictionary dictionary];
    });
    char cc[5] = { (char)(subType >> 24), (char)(subType >> 16), (char)(subType >> 8), (char)subType, 0 };
    NSString *key = @(cc);
    @synchronized (cache) {
        NSValue *v = cache[key];
        if (v) return v.pointerValue;
        NSArray *list = all[key];
        if (list.count == 0) return NULL;
        ParamTable *t = calloc(1, sizeof *t);
        t->count = (int)list.count;
        t->defs = calloc(list.count, sizeof(ParamDef));
        NSMutableDictionary *idx = [NSMutableDictionary dictionary];
        for (int i = 0; i < t->count; i++) {
            NSDictionary *p = list[i];
            t->defs[i] = (ParamDef){ (CFStringRef)CFBridgingRetain(p[@"id"]), [p[@"min"] floatValue], [p[@"max"] floatValue],
                                     [p[@"def"] floatValue], [p[@"discrete"] boolValue] };
            idx[p[@"id"]] = @(i);
        }
        t->index = (void *)CFBridgingRetain(idx);
        cache[key] = [NSValue valueWithPointer:t];
        return t;
    }
}

// ---------------------------------------------------------------- symbol lookup

#define JUCE_FILTER_PROPERTY 0x1a45ffe9 // JUCE's AU wrapper returns { AudioProcessor*, JuceAU* } for this

// Look up symbols (including local ones) in a loaded image's symbol table.
static bool imageSymbols(const struct mach_header_64 *mh, const uint8_t expectUUID[16],
                         const char *const *names, uintptr_t *outAddrs, int count)
{
    if (!mh || mh->magic != MH_MAGIC_64) return false;
    const struct load_command *lc = (const void *)(mh + 1);
    const struct symtab_command *symtab = NULL; const struct segment_command_64 *text = NULL, *linkedit = NULL;
    bool uuidOK = expectUUID == NULL;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        else if (lc->cmd == LC_UUID && expectUUID) uuidOK = !memcmp(((const struct uuid_command *)lc)->uuid, expectUUID, 16);
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const void *)lc;
            if (!strcmp(sg->segname, SEG_TEXT)) text = sg; else if (!strcmp(sg->segname, SEG_LINKEDIT)) linkedit = sg;
        }
    }
    if (!uuidOK || !symtab || !text || !linkedit) return false;
    uintptr_t slide = (uintptr_t)mh - text->vmaddr;
    uintptr_t leBase = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(leBase + symtab->symoff);
    const char *strs = (const char *)(leBase + symtab->stroff);
    int found = 0;
    for (int k = 0; k < count; k++) outAddrs[k] = 0;
    for (uint32_t i = 0; i < symtab->nsyms && found < count; i++) {
        if ((syms[i].n_type & N_STAB) || (syms[i].n_type & N_TYPE) != N_SECT) continue;
        const char *nm = strs + syms[i].n_un.n_strx;
        for (int k = 0; k < count; k++)
            if (!outAddrs[k] && !strcmp(nm, names[k])) { outAddrs[k] = syms[i].n_value + slide; found++; break; }
    }
    return found == count;
}

// ---------------------------------------------------------------- direct parameter access
//
// Writing a parameter by round-tripping the whole plug-in state is slow (33 ms per write for ASAF
// Panner). The parameters are ordinary juce::RangedAudioParameter objects inside the plug-in, held in
// its AudioProcessorValueTreeState, so when we can find them we set them directly, exactly the way the
// plug-in's own code does: setValue(convertTo0to1(v)) then sendValueChangedMessageToListeners().
//
// Finding them relies on JUCE/libc++ object layout, so discovery reads memory defensively and direct
// mode is only enabled if every parameter in params.json turns up under its own name; otherwise the
// shim keeps using the state path.

#define APVTS_ADAPTERS_OFFSET 0x88 // AudioProcessorValueTreeState: std::map<StringRef, unique_ptr<ParameterAdapter>> end node
#define MAPNODE_KEY_OFFSET    0x20 // libc++ map node: key (StringRef == const char *)
#define MAPNODE_VALUE_OFFSET  0x28 //                  value (ParameterAdapter *)
#define ADAPTER_PARAM_OFFSET  0x30 // ParameterAdapter: RangedAudioParameter &
#define VT_GETVALUE 2              // juce::AudioProcessorParameter vtable slots
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
    if (!safeRead(addr, buf, cap - 1)) { // may straddle an unmapped page: fall back to byte reads
        for (size_t i = 0; i < cap - 1; i++) { if (!safeRead(addr + i, buf + i, 1)) return false; if (!buf[i]) break; }
    }
    buf[cap - 1] = 0;
    return true;
}

static void walkAdapters(Shim *s, uintptr_t node, int depth, int *found)
{
    if (!node || depth > 48) return;
    uintptr_t left, right, key, adapter, param, vt;
    if (!safeWord(node, &left) || !safeWord(node + 8, &right)) return;
    walkAdapters(s, left, depth + 1, found);
    char name[128];
    if (safeWord(node + MAPNODE_KEY_OFFSET, &key) && safeWord(node + MAPNODE_VALUE_OFFSET, &adapter) &&
        safeCString(key, name, sizeof name) && safeWord(adapter + ADAPTER_PARAM_OFFSET, &param) && safeWord(param, &vt) && vt) {
        NSString *ns = [NSString stringWithUTF8String:name];
        NSNumber *n = ns ? ((__bridge NSDictionary *)s->params->index)[ns] : nil;
        if (n && !s->dparam[n.intValue]) { s->dparam[n.intValue] = (void *)param; (*found)++; }
    }
    walkAdapters(s, right, depth + 1, found);
}

static bool resolveDirect(Shim *s)
{
    if (!s->params || getenv("ASAFSHIM_NO_DIRECT")) return false;
    GetPropFn getProp = REAL(s, kAudioUnitGetPropertySelect, GetPropFn);
    Dl_info info;
    if (!getProp || !dladdr((void *)getProp, &info) || !info.dli_fbase) return false;
    static const char *const names[] = {
        "__ZTVN4juce28AudioProcessorValueTreeStateE",
        "__ZNK4juce20RangedAudioParameter13convertTo0to1Ef",
        "__ZNK4juce20RangedAudioParameter15convertFrom0to1Ef",
        "__ZN4juce23AudioProcessorParameter34sendValueChangedMessageToListenersEf" };
    uintptr_t addr[4];
    if (!imageSymbols(info.dli_fbase, NULL, names, addr, 4)) return false;

    void *ptrs[2] = { NULL, NULL }; UInt32 sz = sizeof ptrs;
    if (getProp(s->real, JUCE_FILTER_PROPERTY, kAudioUnitScope_Global, 0, ptrs, &sz) != noErr || !ptrs[0]) return false;
    uintptr_t processor = (uintptr_t)ptrs[0], vtable = addr[0] + 16, apvts = 0, w;
    size_t size = malloc_size((void *)processor);
    if (size < 64 || size > (64u << 20)) return false;
    // The value tree state is either a member of the processor or owned through a pointer.
    for (size_t off = 0; off + 8 <= size && !apvts; off += 8)
        if (safeWord(processor + off, &w) && w == vtable) apvts = processor + off;
    for (size_t off = 0; off + 8 <= size && !apvts; off += 8) {
        uintptr_t inner;
        if (safeWord(processor + off, &w) && w && !(w & 7) && malloc_size((void *)w) >= 0x100 && safeWord(w, &inner) && inner == vtable) apvts = w;
    }
    if (!apvts) return false;

    uintptr_t root; int found = 0;
    if (!safeWord(apvts + APVTS_ADAPTERS_OFFSET, &root)) return false;
    @autoreleasepool { walkAdapters(s, root, 0, &found); }
    if (found != s->params->count) { memset(s->dparam, 0, sizeof(void *) * s->params->count); return false; }

    s->convTo0to1 = (float (*)(void *, float))addr[1];
    s->convFrom0to1 = (float (*)(void *, float))addr[2];
    s->sendChanged = (void (*)(void *, float))addr[3];
    return true;
}

static float directGet(Shim *s, int i)
{
    void *p = s->dparam[i];
    float norm = ((float (*)(void *))(*(void ***)p)[VT_GETVALUE])(p);
    return s->convFrom0to1(p, norm);
}

static void directSet(Shim *s, int i, float value)
{
    void *p = s->dparam[i];
    float norm = s->convTo0to1(p, value);
    ((void (*)(void *, float))(*(void ***)p)[VT_SETVALUE])(p, norm);
    s->sendChanged(p, norm);
}

static void notifyParam(Shim *s, int i);

// Pull the plug-in's current values into the cache. Main thread; caller holds s->lock (or is in Open).
static void directRefresh(Shim *s, bool notify)
{
    for (int i = 0; i < s->params->count; i++) {
        if (atomic_load(&s->dirty[i])) continue;
        const ParamDef *d = &s->params->defs[i];
        float v = directGet(s, i);
        if (d->discrete) v = __builtin_roundf(v);
        float old = atomic_load(&s->values[i]);
        float tol = 1e-5f * (d->max - d->min > 1 ? d->max - d->min : 1); // ignore normalisation round-trip noise
        if (__builtin_fabsf(v - old) <= tol) continue;
        atomic_store(&s->values[i], v);
        if (notify) notifyParam(s, i);
    }
}

// ---------------------------------------------------------------- state <-> params
//
// The plug-ins only accept a *complete* state (a partial one resets everything else to defaults), and
// asking a big unit for its state is slow (ASAF Panner: ~60 ms to get, ~33 ms to set, 460 KB of XML).
// So the shim keeps its own copy of the state, patches changed values into it at byte level, and
// pushes it back. Small units are then read back to pick up clamping and linked parameters.

#define READBACK_MAX_BYTES 65536

static NSDictionary *copyRealClassInfo(Shim *s)
{
    CFPropertyListRef pl = NULL; UInt32 sz = sizeof pl;
    if (REAL(s, kAudioUnitGetPropertySelect, GetPropFn)(s->real, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &pl, &sz) || !pl)
        return nil;
    return (NSDictionary *)CFBridgingRelease(pl);
}

// JUCE wraps the XML as: 'VC2!' + uint32 length + utf8 + NUL
static NSData *xmlBytes(NSData *blob)
{
    if (blob.length < 9) return nil;
    uint32_t len; [blob getBytes:&len range:NSMakeRange(4, 4)];
    if (len > blob.length - 8) return nil;
    return [blob subdataWithRange:NSMakeRange(8, len)];
}

static void notifyParam(Shim *s, int i)
{
    if (!s->instance) return;
    AudioUnitEvent ev = { .mEventType = kAudioUnitEvent_ParameterValueChange };
    ev.mArgument.mParameter = (AudioUnitParameter){ s->instance, (AudioUnitParameterID)i, kAudioUnitScope_Global, 0 };
    AUEventListenerNotify(NULL, NULL, &ev);
}

// Re-read the plug-in's state into the shim's copy and the value cache. Caller holds s->lock (or is in Open).
static void reloadFromPlugin(Shim *s, bool notify)
{
    if (s->direct) { directRefresh(s, notify); return; }
    NSDictionary *info = copyRealClassInfo(s);
    NSData *blob = info[@"jucePluginState"];
    NSData *xml = blob ? xmlBytes(blob) : nil;
    if (!xml) return;
    if (s->info) CFRelease(s->info);
    if (s->blob) CFRelease(s->blob);
    s->info = CFBridgingRetain(info);
    s->blob = CFBridgingRetain([blob mutableCopy]);

    // Scan `<PARAM id="NAME" value="V"` pairs without building a DOM (the Panner has ~9000 of them).
    NSDictionary *idx = (__bridge NSDictionary *)s->params->index;
    const char *p = xml.bytes, *end = p + xml.length;
    static const char kId[] = "<PARAM id=\"", kVal[] = "\" value=\"";
    while (p < end && (p = memmem(p, end - p, kId, sizeof kId - 1))) {
        p += sizeof kId - 1;
        const char *q = memchr(p, '"', end - p);
        if (!q || (size_t)(end - q) < sizeof kVal || memcmp(q, kVal, sizeof kVal - 1)) continue;
        NSString *name = [[NSString alloc] initWithBytesNoCopy:(void *)p length:q - p encoding:NSUTF8StringEncoding freeWhenDone:NO];
        NSNumber *n = name ? idx[name] : nil;
        const char *v = q + sizeof kVal - 1;
        p = v;
        if (!n) continue;
        int i = n.intValue;
        if (atomic_load(&s->dirty[i])) continue;
        float val = strtof(v, NULL); // value text is followed by '"', so strtof stops there
        float old = atomic_exchange(&s->values[i], val);
        if (notify && old != val) notifyParam(s, i);
    }
}

// Write pending parameter edits into the plug-in via its state. Caller holds s->lock.
static void flushLocked(Shim *s)
{
    if (s->closed || !s->params) return;
    if (s->direct) {
        if (!atomic_exchange(&s->anyDirty, false)) return;
        for (int i = 0; i < s->params->count; i++)
            if (atomic_exchange(&s->dirty[i], false)) directSet(s, i, atomic_load(&s->values[i]));
        directRefresh(s, true); // clamping, and parameters the plug-in changed in response
        return;
    }
    if (!s->blob || !atomic_exchange(&s->anyDirty, false)) return;
    @autoreleasepool {
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        NSMutableData *blob = (__bridge NSMutableData *)s->blob;
        bool changed = false;
        for (int i = 0; i < s->params->count; i++) {
            if (!atomic_exchange(&s->dirty[i], false)) continue;
            char needle[160];
            char name[100]; CFStringGetCString(s->params->defs[i].name, name, sizeof name, kCFStringEncodingUTF8);
            int nlen = snprintf(needle, sizeof needle, "<PARAM id=\"%s\" value=\"", name);
            char *base = blob.mutableBytes;
            char *hit = memmem(base + 8, blob.length - 8, needle, nlen);
            if (!hit) continue;
            char *v = hit + nlen, *q = memchr(v, '"', base + blob.length - v);
            if (!q) continue;
            char text[32]; int tlen = snprintf(text, sizeof text, "%.9g", atomic_load(&s->values[i]));
            [blob replaceBytesInRange:NSMakeRange(v - base, q - v) withBytes:text length:tlen];
            changed = true;
        }
        if (!changed) return;
        uint32_t len = (uint32_t)(blob.length - 9);
        [blob replaceBytesInRange:NSMakeRange(4, 4) withBytes:&len];

        NSMutableDictionary *info = [(__bridge NSDictionary *)s->info mutableCopy];
        info[@"jucePluginState"] = blob;
        CFPropertyListRef pl = (__bridge CFPropertyListRef)info;
        REAL(s, kAudioUnitSetPropertySelect, SetPropFn)(s->real, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &pl, sizeof pl);

        // Small units: read back, since the plug-in clamps values and may update linked params.
        if (blob.length <= READBACK_MAX_BYTES) reloadFromPlugin(s, true);

        // Keep the main thread at <= ~20% duty: wait 4x the cost of this flush before the next one.
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        s->nextFlush = now + 4 * (now - t0);
    }
}

// ---------------------------------------------------------------- wrapped methods

static bool isParamReq(Shim *s, AudioUnitScope scope) { return s->params && scope == kAudioUnitScope_Global; }

static OSStatus shimGetPropertyInfo(void *self, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                                    UInt32 *outSize, Boolean *outWritable)
{
    Shim *s = self;
    if (prop == kAudioUnitProperty_CocoaUI) return kAudioUnitErr_InvalidProperty;
    if (isParamReq(s, scope)) {
        if (prop == kAudioUnitProperty_ParameterList) {
            if (outSize) *outSize = (UInt32)(s->params->count * sizeof(AudioUnitParameterID));
            if (outWritable) *outWritable = false;
            return noErr;
        }
        if (prop == kAudioUnitProperty_ParameterInfo) {
            if (elem >= (UInt32)s->params->count) return kAudioUnitErr_InvalidParameter;
            if (outSize) *outSize = sizeof(AudioUnitParameterInfo);
            if (outWritable) *outWritable = false;
            return noErr;
        }
    }
    return REAL(s, kAudioUnitGetPropertyInfoSelect, GetPropInfoFn)(s->real, prop, scope, elem, outSize, outWritable);
}

static OSStatus shimGetProperty(void *self, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                                void *out, UInt32 *ioSize)
{
    Shim *s = self;
    if (prop == kAudioUnitProperty_CocoaUI) return kAudioUnitErr_InvalidProperty;
    if (isParamReq(s, scope)) {
        if (prop == kAudioUnitProperty_ParameterList) {
            UInt32 n = (UInt32)s->params->count;
            if (!out || !ioSize) return kAudio_ParamError;
            if (*ioSize / sizeof(AudioUnitParameterID) < n) n = *ioSize / sizeof(AudioUnitParameterID);
            for (UInt32 i = 0; i < n; i++) ((AudioUnitParameterID *)out)[i] = i;
            *ioSize = n * sizeof(AudioUnitParameterID);
            return noErr;
        }
        if (prop == kAudioUnitProperty_ParameterInfo) {
            if (elem >= (UInt32)s->params->count) return kAudioUnitErr_InvalidParameter;
            if (!out || !ioSize || *ioSize < sizeof(AudioUnitParameterInfo)) return kAudio_ParamError;
            const ParamDef *d = &s->params->defs[elem];
            AudioUnitParameterInfo pi = { 0 };
            CFStringGetCString(d->name, pi.name, sizeof pi.name, kCFStringEncodingUTF8);
            pi.cfNameString = d->name;
            pi.minValue = d->min; pi.maxValue = d->max; pi.defaultValue = d->def;
            pi.unit = !d->discrete ? kAudioUnitParameterUnit_Generic
                    : (d->max - d->min <= 1 ? kAudioUnitParameterUnit_Boolean : kAudioUnitParameterUnit_Indexed);
            pi.flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_HasCFNameString
                     | (d->discrete ? 0 : kAudioUnitParameterFlag_IsHighResolution);
            memcpy(out, &pi, sizeof pi); *ioSize = sizeof pi;
            return noErr;
        }
        if (prop == kAudioUnitProperty_ClassInfo) { // make sure saved state includes pending edits
            pthread_mutex_lock(&s->lock); flushLocked(s); pthread_mutex_unlock(&s->lock);
        }
    }
    return REAL(s, kAudioUnitGetPropertySelect, GetPropFn)(s->real, prop, scope, elem, out, ioSize);
}

static OSStatus shimSetProperty(void *self, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                                const void *data, UInt32 size)
{
    Shim *s = self;
    OSStatus err = REAL(s, kAudioUnitSetPropertySelect, SetPropFn)(s->real, prop, scope, elem, data, size);
    if (err == noErr && s->params && (prop == kAudioUnitProperty_ClassInfo || prop == kAudioUnitProperty_PresentPreset)) {
        pthread_mutex_lock(&s->lock);
        @autoreleasepool {
            for (int i = 0; i < s->params->count; i++) atomic_store(&s->dirty[i], false);
            atomic_store(&s->anyDirty, false);
            reloadFromPlugin(s, true);
        }
        pthread_mutex_unlock(&s->lock);
    }
    return err;
}

static OSStatus shimGetParameter(void *self, AudioUnitParameterID pid, AudioUnitScope scope, AudioUnitElement elem,
                                 AudioUnitParameterValue *out)
{
    Shim *s = self;
    if (isParamReq(s, scope)) {
        if (pid >= (UInt32)s->params->count || !out) return kAudioUnitErr_InvalidParameter;
        *out = atomic_load(&s->values[pid]);
        return noErr;
    }
    return REAL(s, kAudioUnitGetParameterSelect, GetParamFn)(s->real, pid, scope, elem, out);
}

// Realtime-safe: just stores the value; the main-queue timer applies it.
static OSStatus shimSetParameter(void *self, AudioUnitParameterID pid, AudioUnitScope scope, AudioUnitElement elem,
                                 AudioUnitParameterValue value, UInt32 offset)
{
    Shim *s = self;
    if (isParamReq(s, scope)) {
        if (pid >= (UInt32)s->params->count) return kAudioUnitErr_InvalidParameter;
        const ParamDef *d = &s->params->defs[pid];
        if (value < d->min) value = d->min;
        if (value > d->max) value = d->max;
        if (d->discrete) value = __builtin_roundf(value);
        if (atomic_exchange(&s->values[pid], value) != value) {
            atomic_store(&s->dirty[pid], true);
            atomic_store(&s->anyDirty, true);
        }
        return noErr;
    }
    return REAL(s, kAudioUnitSetParameterSelect, SetParamFn)(s->real, pid, scope, elem, value, offset);
}

static OSStatus shimScheduleParameters(void *self, const AudioUnitParameterEvent *events, UInt32 n)
{
    Shim *s = self;
    if (!s->params) return REAL(s, kAudioUnitScheduleParametersSelect, SchedFn)(s->real, events, n);
    for (UInt32 i = 0; i < n; i++) {
        const AudioUnitParameterEvent *e = &events[i];
        AudioUnitParameterValue v = e->eventType == kParameterEvent_Immediate ? e->eventValues.immediate.value
                                                                             : e->eventValues.ramp.endValue;
        shimSetParameter(self, e->parameter, e->scope, e->element, v, 0);
    }
    return noErr;
}

// Everything else: swap in the real `self` and forward. (None of these take float arguments.)
#define TRAMP(n) static long tramp##n(void *self, long a, long b, long c, long d, long e, long f, long g) \
    { Shim *s = self; return ((GenericFn)s->table[n])(s->real, a, b, c, d, e, f, g); }
#define T16(n) TRAMP(n##0) TRAMP(n##1) TRAMP(n##2) TRAMP(n##3) TRAMP(n##4) TRAMP(n##5) TRAMP(n##6) TRAMP(n##7) \
               TRAMP(n##8) TRAMP(n##9) TRAMP(n##a) TRAMP(n##b) TRAMP(n##c) TRAMP(n##d) TRAMP(n##e) TRAMP(n##f)
T16(0x0) T16(0x1) T16(0x2)
#define R16(n) tramp##n##0, tramp##n##1, tramp##n##2, tramp##n##3, tramp##n##4, tramp##n##5, tramp##n##6, tramp##n##7, \
               tramp##n##8, tramp##n##9, tramp##n##a, tramp##n##b, tramp##n##c, tramp##n##d, tramp##n##e, tramp##n##f
static const GenericFn kTramps[NSLOT] = { R16(0x0), R16(0x1), R16(0x2) };

// Lookup has no `self`. All nine units use the same AUSDK dispatch table, so record which selectors
// the real plug-ins implement (filled in by forward()) and only vend trampolines for those.
static _Atomic bool gSupported[NSLOT];

static AudioComponentMethod shimLookup(SInt16 sel)
{
    int slot = slotFor(sel);
    if (slot < 0 || slot >= NSLOT || !atomic_load(&gSupported[slot])) return NULL;
    switch (sel) {
        case kAudioUnitGetPropertyInfoSelect:    return (AudioComponentMethod)shimGetPropertyInfo;
        case kAudioUnitGetPropertySelect:        return (AudioComponentMethod)shimGetProperty;
        case kAudioUnitSetPropertySelect:        return (AudioComponentMethod)shimSetProperty;
        case kAudioUnitGetParameterSelect:       return (AudioComponentMethod)shimGetParameter;
        case kAudioUnitSetParameterSelect:       return (AudioComponentMethod)shimSetParameter;
        case kAudioUnitScheduleParametersSelect: return (AudioComponentMethod)shimScheduleParameters;
    }
    return (AudioComponentMethod)kTramps[slot];
}

static void registerLive(Shim *s, bool add);

static void shimFree(Shim *s)
{
    if (s->info) CFRelease(s->info);
    if (s->blob) CFRelease(s->blob);
    pthread_mutex_destroy(&s->lock); free(s->values); free(s->dirty); free(s->dparam); free(s);
}

static OSStatus shimOpen(void *self, AudioComponentInstance instance)
{
    Shim *s = self;
    OSStatus err = s->real->Open(s->real, instance);
    if (err) return err;
    s->instance = instance;
    registerLive(s, true);
    if (s->params) {
        @autoreleasepool {
            for (int i = 0; i < s->params->count; i++) atomic_store(&s->values[i], s->params->defs[i].def);
            s->direct = resolveDirect(s);
            reloadFromPlugin(s, false);
        }
        s->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(s->timer, dispatch_time(DISPATCH_TIME_NOW, 0), 15 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(s->timer, ^{
            s->tick++;
            if (atomic_load(&s->anyDirty)) {
                if (CFAbsoluteTimeGetCurrent() < s->nextFlush) return;
                pthread_mutex_lock(&s->lock); flushLocked(s); pthread_mutex_unlock(&s->lock);
            } else if (s->direct && s->tick % 16 == 0) { // ~4x a second: notice changes made by the plug-in itself
                pthread_mutex_lock(&s->lock); if (!s->closed) directRefresh(s, true); pthread_mutex_unlock(&s->lock);
            }
        });
        dispatch_source_set_cancel_handler(s->timer, ^{ // runs on the main queue after any in-flight flush
            shimFree(s);
        });
        dispatch_resume(s->timer);
    }
    return noErr;
}

static OSStatus shimClose(void *self)
{
    Shim *s = self;
    registerLive(s, false);
    pthread_mutex_lock(&s->lock);
    s->closed = true;
    AudioComponentPlugInInterface *real = s->real;
    pthread_mutex_unlock(&s->lock);
    OSStatus err = real->Close(real);
    if (s->timer) dispatch_source_cancel(s->timer); // frees s
    else { shimFree(s); }
    return err;
}

// ---------------------------------------------------------------- control API
//
// For in-process clients (the reaper_asaf extension): find live shim instances by AU subtype and set a
// hidden parameter *synchronously*. Clients dlopen() this binary by path and dlsym() these functions.
// Main thread only.

#define MAX_LIVE 1024
static Shim *gLive[MAX_LIVE];
static pthread_mutex_t gLiveLock = PTHREAD_MUTEX_INITIALIZER;

static void registerLive(Shim *s, bool add)
{
    pthread_mutex_lock(&gLiveLock);
    for (int i = 0; i < MAX_LIVE; i++) {
        if (add && !gLive[i]) { gLive[i] = s; break; }
        if (!add && gLive[i] == s) { gLive[i] = NULL; break; }
    }
    pthread_mutex_unlock(&gLiveLock);
}

static int paramIndex(Shim *s, const char *paramID)
{
    if (!s->params) return -1;
    NSNumber *n = ((__bridge NSDictionary *)s->params->index)[@(paramID)];
    return n ? n.intValue : -1;
}

__attribute__((visibility("default")))
int ASAFShim_APIVersion(void) { return 3; }

// Number of live instances of the given unit (e.g. 'Expt', 'Objt').
__attribute__((visibility("default")))
int ASAFShim_Count(OSType subType)
{
    int n = 0;
    pthread_mutex_lock(&gLiveLock);
    for (int i = 0; i < MAX_LIVE; i++) if (gLive[i] && gLive[i]->subType == subType) n++;
    pthread_mutex_unlock(&gLiveLock);
    return n;
}

// Set a parameter on every live instance of a unit and apply it before returning.
// If `momentary`, the parameter is a trigger: after it has been applied the shim's copy is put back to 0
// so that later writes of other parameters can't fire it again. Returns the number of instances updated.
__attribute__((visibility("default")))
int ASAFShim_SetParam(OSType subType, const char *paramID, float value, int momentary)
{
    Shim *targets[MAX_LIVE]; int n = 0;
    pthread_mutex_lock(&gLiveLock);
    for (int i = 0; i < MAX_LIVE; i++) if (gLive[i] && gLive[i]->subType == subType) targets[n++] = gLive[i];
    pthread_mutex_unlock(&gLiveLock);
    int done = 0;
    for (int k = 0; k < n; k++) {
        Shim *s = targets[k];
        int i = paramIndex(s, paramID);
        if (i < 0) continue;
        pthread_mutex_lock(&s->lock);
        if (!s->closed) {
            atomic_store(&s->values[i], value);
            atomic_store(&s->dirty[i], true);
            atomic_store(&s->anyDirty, true);
            flushLocked(s);
            if (momentary && !s->direct) {
                @autoreleasepool {
                    reloadFromPlugin(s, true);                 // pick up whatever the plug-in reset it to
                    if (atomic_load(&s->values[i]) != 0) {      // plug-in left it set: clear our copy without re-sending
                        atomic_store(&s->values[i], 0);
                        NSMutableData *blob = (__bridge NSMutableData *)s->blob;
                        char needle[160]; int nlen = snprintf(needle, sizeof needle, "<PARAM id=\"%s\" value=\"", paramID);
                        char *base = blob.mutableBytes, *hit = memmem(base + 8, blob.length - 8, needle, nlen);
                        char *q = hit ? memchr(hit + nlen, '"', base + blob.length - (hit + nlen)) : NULL;
                        if (q) {
                            [blob replaceBytesInRange:NSMakeRange(hit + nlen - base, q - (hit + nlen)) withBytes:"0" length:1];
                            uint32_t len = (uint32_t)(blob.length - 9);
                            [blob replaceBytesInRange:NSMakeRange(4, 4) withBytes:&len];
                        }
                    }
                }
            }
            done++;
        }
        pthread_mutex_unlock(&s->lock);
    }
    return done;
}

// Read the shim's current value of a parameter from the first live instance. Returns 1 on success.
__attribute__((visibility("default")))
int ASAFShim_GetParam(OSType subType, const char *paramID, float *outValue)
{
    int ok = 0;
    pthread_mutex_lock(&gLiveLock);
    for (int i = 0; i < MAX_LIVE && !ok; i++) {
        Shim *s = gLive[i];
        if (!s || s->subType != subType) continue;
        int p = paramIndex(s, paramID);
        if (p >= 0) { *outValue = atomic_load(&s->values[p]); ok = 1; }
    }
    pthread_mutex_unlock(&gLiveLock);
    return ok;
}

// 1 if the first live instance of a unit is using direct parameter access, 0 if it fell back to the
// (slow) state path, -1 if there is no instance.
__attribute__((visibility("default")))
int ASAFShim_IsDirect(OSType subType)
{
    int r = -1;
    pthread_mutex_lock(&gLiveLock);
    for (int i = 0; i < MAX_LIVE && r < 0; i++) if (gLive[i] && gLive[i]->subType == subType) r = gLive[i]->direct ? 1 : 0;
    pthread_mutex_unlock(&gLiveLock);
    return r;
}

// ---------------------------------------------------------------- ASAF Export: hidden Convert button
//
// The headless ASAF Export AU can write an ASAF BWF from a parameter (createAIAFile), but its APAC
// (.mp4) encoder is only reachable from the Convert button of a dialog that is never shown. The dialog
// object still exists inside the plug-in, so we call its button handler directly.
//
// This depends on the internal layout of each build, so it is refused unless the loaded binary
// is one of the builds listed below (matched by Mach-O UUID) and the objects we find have the expected vtables.

#if defined(__arm64__)
typedef struct { uint8_t uuid[16]; uint32_t dialogOffset, convertOffset; } ExportBuild;  // ExportProcessor -> BounceDialog*, BounceDialog -> convert juce::Button*
static const ExportBuild kExportBuilds[] = {
  { { 0xA0,0x4C,0x20,0xB9,0x84,0xC4,0x30,0x65,0xBB,0x8A,0xA0,0xB6,0x73,0x7D,0x3E,0x2E }, 0xe98, 0x450 },  // v2.1.8 arm64
  { { 0xEC,0x4B,0xAC,0xBF,0xF4,0x89,0x35,0x15,0x8F,0xD6,0x2B,0xA8,0xF7,0x8A,0x05,0x57 }, 0xd98, 0x450 },  // v2.1.13 arm64
};

#endif

// Press ASAF Export's hidden Convert button: converts the bounce file named by the plug-in's state to an
// ASAF BWF and, if its createAPACFile parameter is on, then encodes an APAC .mp4 next to it. The work
// continues on a plug-in thread after this returns. Main thread only.
// Returns 1 if started; 0 if there isn't exactly one ASAF Export; <0 if unsupported:
//   -1 not this CPU architecture, -2 not the supported ASAF Export build, -3 unexpected plug-in internals.
__attribute__((visibility("default")))
int ASAFShim_ExportPressConvert(void)
{
#if defined(__arm64__)
    Shim *s = NULL; int n = 0;
    pthread_mutex_lock(&gLiveLock);
    for (int i = 0; i < MAX_LIVE; i++) if (gLive[i] && gLive[i]->subType == 'Expt') { s = gLive[i]; n++; }
    pthread_mutex_unlock(&gLiveLock);
    if (n != 1) return 0;

    GetPropFn getProp = REAL(s, kAudioUnitGetPropertySelect, GetPropFn);
    Dl_info info;
    if (!getProp || !dladdr((void *)getProp, &info) || !info.dli_fbase) return -2;
    static const char *const names[] = { "__ZN12BounceDialog13buttonClickedEPN4juce6ButtonE", "__ZTV12BounceDialog", "__ZTV15ExportProcessor" };
    uintptr_t addr[3];
    const ExportBuild *build = NULL;
    for (size_t i = 0; i < sizeof kExportBuilds / sizeof kExportBuilds[0] && !build; i++)
        if (imageSymbols(info.dli_fbase, kExportBuilds[i].uuid, names, addr, 3)) build = &kExportBuilds[i];
    if (!build) return -2;

    void *ptrs[2] = { NULL, NULL }; UInt32 sz = sizeof ptrs;
    if (getProp(s->real, JUCE_FILTER_PROPERTY, kAudioUnitScope_Global, 0, ptrs, &sz) != noErr || !ptrs[0]) return -3;
    uintptr_t *processor = ptrs[0];
    if (processor[0] != addr[2] + 16) return -3;                                   // really an ExportProcessor
    uintptr_t *dialog = *(uintptr_t **)((char *)processor + build->dialogOffset);
    if (!dialog || dialog[0] != addr[1] + 16) return -3;                           // really a BounceDialog
    void *button = *(void **)((char *)dialog + build->convertOffset);
    if (!button) return -3;

    ((void (*)(void *, void *))addr[0])(dialog, button);
    return 1;
#else
    return -1;
#endif
}

// ---------------------------------------------------------------- factories

typedef AudioComponentPlugInInterface *(*Factory)(const AudioComponentDescription *);

static AudioComponentPlugInInterface *forward(const char *bundleName, const char *factoryName, OSType subType)
{
    char path[1024];
    snprintf(path, sizeof path, "/Library/Audio/Plug-Ins/Components/%s.component/Contents/MacOS/%s", bundleName, bundleName);
    void *h = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!h) { NSLog(@"ASAFShim: dlopen failed: %s", dlerror()); return NULL; }
    Factory f = (Factory)dlsym(h, factoryName);
    if (!f) { NSLog(@"ASAFShim: missing %s in %s", factoryName, path); return NULL; }
    AudioComponentDescription desc = { kAudioUnitType_Effect, subType, 'Appl', 0, 0 };
    AudioComponentPlugInInterface *real = f(&desc);
    if (!real) return NULL;

    Shim *s = calloc(1, sizeof *s);
    s->iface.Open = shimOpen; s->iface.Close = shimClose; s->iface.Lookup = shimLookup;
    s->real = real;
    pthread_mutex_init(&s->lock, NULL);
    for (SInt16 sel = 1; sel < 0x110; sel = (sel == 0x1f ? 0x100 : sel + 1)) {
        int slot = slotFor(sel);
        if (slot < NSLOT && (s->table[slot] = real->Lookup(sel))) atomic_store(&gSupported[slot], true);
    }
    s->subType = subType;
    s->params = paramTableFor(subType);
    if (s->params) {
        s->values = calloc(s->params->count, sizeof *s->values);
        s->dirty = calloc(s->params->count, sizeof *s->dirty);
        s->dparam = calloc(s->params->count, sizeof *s->dparam);
    }
    return &s->iface;
}

#define SHIM(fn, bundle, sub) \
    __attribute__((visibility("default"))) \
    AudioComponentPlugInInterface *fn##Shim(const AudioComponentDescription *d) { (void)d; return forward(bundle, #fn, sub); }

SHIM(AppleChannelsRendererAUFactory, "ASAF Channels Renderer", 'CRdr')
SHIM(AppleChannelsAUFactory,         "ASAF Channels",          'Chan')
SHIM(AppleExportAUFactory,           "ASAF Export",            'Expt')
SHIM(AppleObjectRendererAUFactory,   "ASAF Object Renderer",   'ORdr')
SHIM(AppleObjectToSceneAUFactory,    "ASAF Object to Scene",   'Ob2S')
SHIM(AppleObjectAUFactory,           "ASAF Object",            'Objt')
SHIM(ApplePannerAUFactory,           "ASAF Panner",            'Pnnr')
SHIM(AppleSceneRendererAUFactory,    "ASAF Scene Renderer",    'SRdr')
SHIM(AppleSceneAUFactory,            "ASAF Scene",             'Scen')
