#!/usr/bin/env python3
"""Step 1 of converting a REAPER project that pans with ambiX encoders to ASAF objects.

Reads the project, takes every ambix_encoder's settings and automation out of it, and writes
  * a copy of the project with the encoders removed and the routing prepared for objects, and
  * a Lua table describing the objects to create (read by convert.lua, which runs inside REAPER).

    prepare.py <input.RPP> <output.RPP> <objects.lua>

The original project is never modified.

ambiX encoder parameters (normalised 0..1), from its saved state:
  0 azimuth    (v - 0.5) * 360 degrees
  1 elevation  (v - 0.5) * 360 degrees  (so it can go "over the top", beyond +/-90)
  2 size       (unused in this project)
  3 width      v * 360 degrees          (stereo encoder only: angle between the two inputs)
  then azimuth set / set-relative / move, elevation set / set-relative / move, speed
A non-centred "azimuth move" makes the source rotate continuously; the rate used here,
(move - 0.5) * 2 * speed * 360 degrees per second, is an approximation of the plug-in's behaviour.
"""
import base64, re, sys

AZ_SIGN = +1        # +1: ambiX azimuth is positive to the left, like ASAF. Set to -1 to mirror left/right.
MOVE_DEAD_ZONE = 0.03

def main(src, dst, lua):
    lines = open(src, errors='surrogateescape').read().split('\n')
    out = []
    objects = []
    master_vol = 1.0
    folder_vols = []          # volumes of the folders we are currently inside
    track_no = 0
    i = 0
    n = len(lines)

    def block_end(start):
        """Index of the line closing the block that opens at `start`."""
        depth = 0
        j = start
        while j < n:
            s = lines[j].strip()
            if s.startswith('<'): depth += 1
            elif s == '>':
                depth -= 1
                if depth == 0: return j
            j += 1
        raise SystemExit('unterminated block at line %d' % start)

    while i < n:
        line = lines[i]
        s = line.strip()
        if s.startswith('MASTER_NCH '):
            out.append(re.sub(r'MASTER_NCH \d+', 'MASTER_NCH 2', line)); i += 1; continue
        if s.startswith('MASTER_VOLUME '):
            parts = s.split()
            master_vol = float(parts[1])
            out.append(line.replace(parts[1], '1', 1)); i += 1; continue
        if s.startswith('<TRACK') and line.startswith('  <TRACK'):
            end = block_end(i)
            track_no += 1
            tr, obj = convert_track(lines[i:end + 1], track_no)
            vol = float(re.search(r'^\s+VOLPAN (\S+)', '\n'.join(tr), re.M).group(1))
            isbus = re.search(r'^\s+ISBUS (\d+) (-?\d+)', '\n'.join(tr), re.M)
            if obj:
                gain = master_vol
                for v in folder_vols: gain *= v
                obj['gain'] = gain
                objects.append(obj)
            if isbus.group(1) == '1': folder_vols.append(vol)
            elif isbus.group(1) == '2':
                for _ in range(-int(isbus.group(2))):
                    if folder_vols: folder_vols.pop()
            out.extend(tr)
            i = end + 1
            continue
        out.append(line); i += 1

    open(dst, 'w', errors='surrogateescape').write('\n'.join(out))
    write_lua(lua, objects)
    stereo = sum(1 for o in objects if o['stereo'])
    print('%d tracks; %d encoders (%d stereo, %d mono) -> %d objects' % (track_no, len(objects), stereo, len(objects) - stereo, stereo * 2 + len(objects) - stereo))
    print('azimuth automation on %d tracks, width automation on %d, continuous rotation on %d, reverb bypassed on %d' % (
        sum(1 for o in objects if o['azPts']), sum(1 for o in objects if o['wPts']), sum(1 for o in objects if o['rot']), sum(1 for o in objects if o['reverb'])))

def convert_track(tr, track_no):
    """Returns (new lines, object description or None)."""
    name = ''
    obj = None
    out = []
    i = 0
    n = len(tr)
    in_chain = False
    pending_bypass = None   # index in `out` of the BYPASS line belonging to the next FX
    while i < n:
        line = tr[i]; s = line.strip()
        if s.startswith('NAME ') and not in_chain and not name:
            name = s[5:].strip('"')
        if s.startswith('<FXCHAIN'): in_chain = True
        if in_chain and s.startswith('BYPASS '):
            pending_bypass = len(out); out.append(line); i += 1; continue
        if in_chain and s.startswith('<VST') and 'ambix_encoder' in s:
            stereo = '_i2_' in s
            # state: base64 lines up to the closing '>'
            j = i + 1; raw = b''
            while tr[j].strip() != '>':
                try: raw += base64.b64decode(tr[j].strip())
                except Exception: pass
                j += 1
            m = re.search(rb'<MYPLUGINSETTINGS([^>]*)>', raw)
            vals = {int(k): float(v) for k, v in re.findall(rb' (\d+)="([^"]*)"', m.group(1))} if m else {}
            # skip the rest of this FX: everything up to and including its WAK line, collecting envelopes
            envs = {}
            j += 1
            while not tr[j].strip().startswith('WAK '):
                t = tr[j].strip()
                if t.startswith('<PARMENV'):
                    pid = t.split()[1].split(':')[0]
                    k = j + 1; pts = []; active = True
                    while tr[k].strip() != '>':
                        u = tr[k].strip().split()
                        if u[0] == 'PT': pts.append((float(u[1]), float(u[2])))
                        if u[0] == 'ACT': active = u[1] == '1'
                        k += 1
                    if active and len(pts) > 1 and pid.isdigit(): envs[int(pid)] = pts
                    j = k
                j += 1
            i = j + 1
            if pending_bypass is not None: del out[pending_bypass:]   # drop the encoder's BYPASS line too
            pending_bypass = None
            obj = describe(track_no, name, stereo, vals, envs)
            continue
        if in_chain and s.startswith('<VST') and 'O3A Reverb' in s and obj is not None:
            # An ambisonic reverb after the encoder has nothing ambisonic to work on any more: bypass it.
            if pending_bypass is not None: out[pending_bypass] = re.sub(r'BYPASS \d', 'BYPASS 1', out[pending_bypass])
            obj['reverb'] = True
        if in_chain and s.startswith('LASTSEL '):
            line = re.sub(r'LASTSEL \d+', 'LASTSEL 0', line)
        if in_chain and s == '>' and line.startswith('    >'): in_chain = False
        if not in_chain and s.startswith('NCHAN '):
            line = re.sub(r'NCHAN \d+', 'NCHAN 2', line)
        out.append(line); i += 1
    if obj:
        # Objects are routed individually to the object busses, not summed into the parent folder.
        out = [re.sub(r'MAINSEND \d', 'MAINSEND 0', l) if l.strip().startswith('MAINSEND ') else l for l in out]
    return out, obj

def describe(track_no, name, stereo, v, envs):
    width_idx = 3 if stereo else None
    move_idx = 6 if stereo else 5
    speed_idx = 10 if stereo else 9
    az = (v.get(0, 0.5) - 0.5) * 360 * AZ_SIGN
    el = (v.get(1, 0.5) - 0.5) * 360
    offset = 0.0
    if el > 90: el, offset = 180 - el, 180.0          # over the top: same place as the opposite azimuth
    elif el < -90: el, offset = -180 - el, 180.0
    move = v.get(move_idx, 0.5) - 0.5
    rot = move * 2 * v.get(speed_idx, 0.25) * 360 * AZ_SIGN if abs(move) > MOVE_DEAD_ZONE else 0.0
    az_pts = [(t, (x - 0.5) * 360 * AZ_SIGN) for t, x in envs.get(0, [])]
    w_pts = [(t, x * 360) for t, x in envs.get(width_idx, [])] if stereo else []
    if az_pts: rot = 0.0    # the automation says where it is
    return dict(track=track_no, name=name, stereo=stereo, az=az + offset, el=el, w=v.get(3, 0.125) * 360 if stereo else 0.0,
                azOffset=offset, azPts=az_pts, wPts=w_pts, rot=rot, gain=1.0, reverb=False)

def write_lua(path, objects):
    def pts(p): return '{' + ','.join('{%.9g,%.6f}' % (t, x) for t, x in p) + '}'
    with open(path, 'w') as f:
        f.write('-- Generated by prepare.py: one entry per ambiX encoder that was in the project.\nreturn {\n')
        for o in objects:
            f.write('  {track=%d, name=%s, stereo=%s, az=%.4f, el=%.4f, w=%.4f, azOffset=%.1f, rot=%.5f, gain=%.6f, reverb=%s, azPts=%s, wPts=%s},\n' % (
                o['track'], lua_str(o['name']), 'true' if o['stereo'] else 'false', o['az'], o['el'], o['w'], o['azOffset'], o['rot'], o['gain'],
                'true' if o['reverb'] else 'false', pts(o['azPts']), pts(o['wPts'])))
        f.write('}\n')

def lua_str(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

if __name__ == '__main__':
    if len(sys.argv) != 4: raise SystemExit(__doc__)
    main(*sys.argv[1:])
