#!/usr/bin/env python3
"""Reads the object metadata back out of an ASAF export, so it can be checked against what was set.

  asaf_inspect.py FILE [--expect] [--packets]

FILE is either an ASAF BWF (after conversion) or a bounce file (before conversion: object audio
channels followed by ASAF Export's metadata channels). For both it reports where each object is over
time, which is what "the export has object metadata" comes down to.

  --expect    check the file against the scenario built by export_test.mm / reaper_export_test.lua
              and exit non-zero if it differs
  --packets   also print one line per metadata packet

What the file contains, as far as this needs it (worked out from files made by ASAF Export 2.1.8; not
a published format):

  * ASAF Export emits one metadata packet per 1024-sample block.
  * In a bounce file the packet is carried in the last channel, at the start of the block, as 16-bit
    words (sample value * 32768): 0xAAAA 0xAAAA 0xAAAA, then the packet bytes in little-endian pairs.
    Anything that changes those sample values (gain, pan law, dither, resampling) or moves them off
    the block boundary destroys the metadata.
  * In an ASAF BWF the packets are in the 'AIAM' chunk and 'AIAD' lists their offsets.
  * A packet holds an 'apsd' (session) and an 'apdd' (per-block) section. 'apdd' has one 346-bit
    record per object: a 7-bit object number, and azimuth, elevation and distance as big-endian
    floats 86, 118 and 150 bits in.
"""
import array, cmath, math, struct, sys

RECORD_BITS, AZ, EL, DIST = 346, 86, 118, 150
SYNC = 0xAAAA
BLOCK = 1024


def read_chunks(path):
    """-> (form, {id: (offset, size)}), reading only the chunk headers."""
    out = {}
    with open(path, "rb") as f:
        hdr = f.read(12)
        if len(hdr) < 12 or hdr[8:12] != b"WAVE":
            sys.exit(f"{path}: not a WAVE file")
        data64 = None
        while True:
            h = f.read(8)
            if len(h) < 8:
                break
            cid, size = h[:4], struct.unpack("<I", h[4:])[0]
            pos = f.tell()
            if cid == b"ds64":
                data64 = struct.unpack("<Q", f.read(16)[8:16])[0]
            if cid == b"data" and size == 0xFFFFFFFF and data64 is not None:
                size = data64
            out.setdefault(cid, (pos, size))
            f.seek(pos + size + (size & 1))
    return hdr[:4].decode(), out


def chunk(path, chunks, cid):
    if cid not in chunks:
        return None
    pos, size = chunks[cid]
    with open(path, "rb") as f:
        f.seek(pos)
        return f.read(size)


def bits_of(b):
    return "".join(format(x, "08b") for x in b)


def decode_packet(p):
    """-> list of (object number, azimuth, elevation, distance), or None if the layout isn't recognised."""
    i = p.find(b"apdd")
    if i < 0 or i + 8 > len(p):
        return None
    length = struct.unpack(">H", p[i + 4:i + 6])[0]
    body = bits_of(p[i + 8:i + 6 + length])
    n = (len(body) + 7) // RECORD_BITS  # the last record's tail is not stored in full
    if n < 1 or (n * RECORD_BITS + 7) // 8 != length - 2 and n * RECORD_BITS // 8 != length - 2:
        return None
    objs = []
    for j in range(n):
        r = body[j * RECORD_BITS:(j + 1) * RECORD_BITS]
        f = lambda o: round(struct.unpack(">f", int(r[o:o + 32], 2).to_bytes(4, "big"))[0], 4)
        objs.append((int(r[:7], 2), f(AZ) + 0.0, f(EL) + 0.0, f(DIST)))
    return objs


class Report:
    def __init__(self):
        self.failures = 0

    def check(self, ok, what):
        print(("  PASS  " if ok else "  FAIL  ") + what)
        if not ok:
            self.failures += 1
        return ok


def tone_level(samples, nch, ch, hz, rate, start, count):
    s = 0j
    w = -2j * math.pi * hz / rate
    for i in range(start, start + count):
        s += samples[i * nch + ch] * cmath.exp(w * i)
    return 20 * math.log10(2 * abs(s) / count + 1e-9)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = {a for a in sys.argv[1:] if a.startswith("--")}
    if len(args) != 1 or opts - {"--expect", "--packets"}:
        sys.exit(__doc__)
    path = args[0]
    rep = Report()
    form, chunks = read_chunks(path)
    fmt = chunk(path, chunks, b"fmt ")
    tag, nch, rate, _, _, bps = struct.unpack("<HHIIHH", fmt[:16])
    if tag == 0xFFFE and len(fmt) >= 26:
        tag = struct.unpack("<H", fmt[24:26])[0]
    data_pos, data_size = chunks[b"data"]
    frames = data_size // (nch * bps // 8)
    is_asaf = b"AIAM" in chunks
    print(f"{path}")
    print(f"  {form}, {nch} channels, {rate} Hz, {bps}-bit {'float' if tag == 3 else 'PCM'}, {frames} frames ({frames / rate:.3f} s)")
    print("  chunks: " + " ".join(f"{k.decode('latin1').strip()}({v[1]})" for k, v in chunks.items()))

    if tag != 3 or bps != 32:
        sys.exit("  only 32-bit float files are understood")
    with open(path, "rb") as f:
        f.seek(data_pos)
        samples = array.array("f")
        samples.frombytes(f.read(frames * nch * 4))

    packets = []  # (frame the packet applies to, bytes)
    if is_asaf:
        print("\nASAF BWF (converted)")
        chna = chunk(path, chunks, b"chna")
        if chna:
            ntracks = struct.unpack("<H", chna[:2])[0]
            ids = [chna[4 + 40 * k:4 + 40 * (k + 1)] for k in range(ntracks)]
            print(f"  chna: {ntracks} tracks: " + ", ".join(i[2:14].decode("latin1") for i in ids[:6]) + (" ..." if ntracks > 6 else ""))
        aiad, aiam = chunk(path, chunks, b"AIAD"), chunk(path, chunks, b"AIAM")
        if not aiad:
            rep.check(False, "has an AIAD (packet index) chunk")
        else:
            count, block = struct.unpack("<II", aiad[:8])
            offs = list(struct.unpack(f"<{count}Q", aiad[8:8 + 8 * count])) + [len(aiam)]
            packets = [(k * block, aiam[offs[k]:offs[k + 1]]) for k in range(count)]
            print(f"  AIAD: {count} packets, one per {block} frames; AIAM: {len(aiam)} bytes")
        n_audio = nch
    else:
        print("\nBounce file (not converted)")
        carrier = nch - 1
        peaks = []
        for c in range(max(0, nch - 8), nch):
            peaks.append(max((abs(samples[i * nch + c]) for i in range(0, frames)), default=0))
        print("  last 8 channels, peak: " + " ".join(f"{p:.3f}" for p in peaks))
        others = [nch - 8 + k + 1 for k, p in enumerate(peaks[:-1]) if p > 0]
        if peaks[-1] == 0 and others:
            print(f"  NOTE the last channel is silent but channel(s) {others} are not: metadata is on the wrong channel")
            carrier = others[-1] - 1
        rep.check(peaks[-1] > 0, f"the last channel ({nch}) carries data (ASAF Export was armed, playing, and is routed there)")
        # sync words: three samples of 0xAAAA; look for them anywhere so misalignment shows up
        sync_v = struct.unpack("<h", struct.pack("<H", SYNC))[0] / 32768.0
        col = samples[carrier::nch]
        syncs = [i for i in range(len(col) - 3) if col[i] == sync_v and col[i + 1] == sync_v and col[i + 2] == sync_v and (i == 0 or col[i - 1] != sync_v)]
        if not syncs and peaks[-1] > 0:
            # same shape but scaled? three equal samples at the start of the data
            first = next((i for i, v in enumerate(col) if v != 0), None)
            if first is not None and first + 2 < len(col) and col[first] == col[first + 1] == col[first + 2]:
                g = col[first] / sync_v
                print(f"  NOTE the data starts with three equal samples of {col[first]:.6f} at frame {first}: the metadata has been "
                      f"scaled by {g:.6f} ({20 * math.log10(abs(g)):+.2f} dB{', inverted' if g < 0 else ''}) on its way to the file")
            else:
                print(f"  NOTE first non-zero sample is at frame {first}; no sync pattern found")
        rep.check(bool(syncs), f"metadata packets found ({len(syncs)}; a {frames}-frame render should have {frames // BLOCK})")
        if syncs:
            off = sorted({s % BLOCK for s in syncs})
            gaps = sorted({b - a for a, b in zip(syncs, syncs[1:])})
            rep.check(off == [0], f"packets start on {BLOCK}-frame block boundaries (offsets within the block: {off[:8]})")
            rep.check(gaps in ([BLOCK], []), f"one packet every {BLOCK} frames (spacings seen: {gaps[:8]})")
            rep.check(len(syncs) >= frames // BLOCK, f"every full block has a packet ({len(syncs)} of {frames // BLOCK})")
        for s in syncs:
            words = [int(round(v * 32768)) & 0xFFFF for v in col[s + 3:s + BLOCK]]
            if len(words) < 2 or words[0] != 0xFFFF:
                continue
            length = words[1]
            raw = b"".join(struct.pack("<H", w) for w in words[:(length + 1) // 2])[:length]
            packets.append((s, raw))
        n_audio = nch - 8

    # ---- object metadata over time
    print("\nObject metadata")
    decoded = [(t, decode_packet(p)) for t, p in packets]
    bad = sum(1 for _, d in decoded if d is None)
    good = [(t, d) for t, d in decoded if d is not None]
    rep.check(bool(good) and bad == 0, f"packets decode ({len(good)} of {len(packets)})")
    counts = sorted({len(d) for _, d in good})
    if good:
        rep.check(counts == [n_audio], f"each packet describes {n_audio} objects, one per audio channel (found: {counts})")
        numbers = sorted({tuple(o[0] for o in d) for _, d in good})
        rep.check(numbers == [tuple(range(len(numbers[0])))], f"object numbers are 0..n-1 in order (found: {[list(x) for x in numbers[:3]]})")
    tracks = {}
    for t, d in good:
        for k, (num, az, el, dist) in enumerate(d):
            tracks.setdefault(k, []).append((t, az, el, dist))
    for k in sorted(tracks):
        tr = tracks[k]
        az = [x[1] for x in tr]; el = [x[2] for x in tr]; di = [x[3] for x in tr]
        moving = max(az) - min(az) > 0.01 or max(el) - min(el) > 0.01 or max(di) - min(di) > 0.001
        if not moving:
            print(f"  object {k + 1}: static   azimuth {az[0]:+8.2f}  elevation {el[0]:+7.2f}  distance {di[0]:.3f}")
        else:
            changes = sum(1 for a, b in zip(tr, tr[1:]) if a[1:] != b[1:])
            print(f"  object {k + 1}: moving   azimuth {az[0]:+8.2f} -> {az[-1]:+8.2f}  elevation {el[0]:+7.2f} -> {el[-1]:+7.2f}  "
                  f"distance {di[0]:.3f} -> {di[-1]:.3f}   (changes in {changes} of {len(tr) - 1} blocks)")
            step = max(1, len(tr) // 8)
            print("            azimuth at " + "  ".join(f"{tr[i][0] / rate:.2f}s {tr[i][1]:+.1f}" for i in range(0, len(tr), step)))
    if "--packets" in opts:
        for t, d in decoded:
            print(f"  {t:8d} " + ("?" if d is None else "  ".join(f"{o[0]}:{o[1]:+.1f}/{o[2]:+.1f}/{o[3]:.2f}" for o in d)))

    # ---- the test scenario
    if "--expect" in opts:
        print("\nExpected scenario")
        seconds = 4.0
        rep.check(rate == 48000, "48 kHz")
        rep.check(abs(frames - seconds * rate) <= BLOCK, f"{seconds:g} s long ({frames} frames)")
        rep.check(n_audio >= 4, f"at least 4 object channels ({n_audio})")
        start, count = min(rate // 2, max(0, frames - 8192)), min(8192, frames)
        for k in range(min(n_audio, 4)):
            lv = [tone_level(samples, nch, c, 220.0 * (k + 1), rate, start, count) for c in range(n_audio)]
            best = max(range(n_audio), key=lambda c: lv[c])
            rep.check(best == k and abs(lv[k] + 12.04) < 0.5, f"channel {k + 1} carries object {k + 1}'s {220 * (k + 1)} Hz tone at -12 dB (loudest on channel {best + 1}, {lv[best]:.1f} dB)")
        want = {0: (90, 0, 1), 1: (-90, 0, 1), 2: (0, 45, 2)}
        for k, (az, el, dist) in want.items():
            tr = tracks.get(k)
            ok = bool(tr) and all(abs(x[1] - az) < 0.01 and abs(x[2] - el) < 0.01 and abs(x[3] - dist) < 0.001 for x in tr)
            got = "" if not tr else f" (file: {tr[0][1]:+.2f}/{tr[0][2]:+.2f}/{tr[0][3]:.3f} at the start, {tr[-1][1]:+.2f}/{tr[-1][2]:+.2f}/{tr[-1][3]:.3f} at the end)"
            rep.check(ok, f"object {k + 1} stays at azimuth {az:+d}, elevation {el:+d}, distance {dist}{got}")
        tr = tracks.get(3)
        if not tr:
            rep.check(False, "object 4's azimuth automation (-90 -> +90) is in the metadata")
        else:
            # allow the automation to arrive a few blocks late, but it must track the ramp
            total = seconds * rate
            best_lag, best_err = 0, 1e9
            for lag in range(0, 9):
                err = max(abs(x[1] - max(-90.0, -90 + 180 * (x[0] - lag * BLOCK) / total)) for x in tr)
                if err < best_err:
                    best_lag, best_err = lag, err
            rep.check(best_err < 1.5, f"object 4's azimuth follows the automation -90 -> +90 (worst error {best_err:.2f} deg at a lag of {best_lag} block(s); "
                                      f"file goes {tr[0][1]:+.1f} -> {tr[-1][1]:+.1f})")
            steps = sum(1 for a, b in zip(tr, tr[1:]) if a[1] != b[1])
            rep.check(steps >= 0.9 * (len(tr) - 1), f"and it is updated every block ({steps} of {len(tr) - 1} blocks)")

    print(f"\n{'OK' if not rep.failures else str(rep.failures) + ' CHECK(S) FAILED'}")
    return 1 if rep.failures else 0


if __name__ == "__main__":
    sys.exit(main())
