#!/bin/bash
# Makes an ASAF BWF and an APAC .mp4 to listen to: a synthesised voice (macOS `say`) names each
# location in turn, each phrase being an object at that location; the last one moves while it speaks.
#
#   tools/export_test/speech_demo.sh [voice [name [harness options...]]]
#                                    -> tools/export_test/out/<name>.{wav,mp4}  (name: spoken_locations)
#
# Harness options change how the objects are rendered on playback, e.g.
#   speech_demo.sh Phonon spoken_reverb --set Reverb=1 --set "Reverb Mix=50"
#   speech_demo.sh Phonon spoken_cathedral --set Reverb=1 --session "Reverb Preset=8"
# (--set: a parameter on every ASAF Object; --session: a session parameter, through an ASAF Panner.)
#
# Uses the DAW-less harness (asaf_clap/tools/export_test.mm) and the installed ASAF.clap.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${ASAF_TEST_OUT:-$HERE/out}
CLAP=${ASAF_CLAP:-$HOME/Library/Audio/Plug-Ins/CLAP/ASAF.clap}
VOICE=${1:-}
NAME=${2:-spoken_locations}
EXTRA=("${@:3}")
WORK="$OUT/speech"
mkdir -p "$WORK"
clang++ -std=c++17 -fobjc-arc -O1 -I"$ROOT/modules/clap/include" -framework Foundation \
  -o "$OUT/export_test" "$ROOT/asaf_clap/tools/export_test.mm" "$ROOT/reaper_asaf/asaf_core.mm"

# azimuth,elevation,distance | phrase     (azimuth is positive to the listener's left)
PHRASES=(
  "0,0,1|Front"
  "45,0,1|Front left"
  "90,0,1|Left"
  "135,0,1|Back left"
  "180,0,1|Behind"
  "-135,0,1|Back right"
  "-90,0,1|Right"
  "-45,0,1|Front right"
  "0,90,1|Above"
  "0,-60,1|Below"
  "-90,0,1|Moving, from the right, across the front, all the way round to the left"
)
N=${#PHRASES[@]}
for i in $(seq 0 $((N - 1))); do
  # no -r: a speaking rate other than the voice's own makes some voices sound time-stretched
  say ${VOICE:+-v "$VOICE"} -o "$WORK/say$i.wav" --data-format=LEF32@48000 "${PHRASES[$i]#*|}"
done

# One full-length file per object, silent except for its own phrase; phrases follow one another.
python3 - "$WORK" "$N" > "$WORK/layout.txt" <<'PY'
import array, struct, sys
work, n = sys.argv[1], int(sys.argv[2])
RATE, GAP, LEAD = 48000, int(0.6 * 48000), int(0.5 * 48000)
def read(path):
    d = open(path, "rb").read(); o = 12
    while o + 8 <= len(d):
        cid, sz = d[o:o + 4], struct.unpack("<I", d[o + 4:o + 8])[0]
        if cid == b"data":
            a = array.array("f"); a.frombytes(d[o + 8:o + 8 + sz // 4 * 4]); return a
        o += 8 + sz + (sz & 1)
    sys.exit(path + ": no audio")
# Some voices start each clip with a small thump, and a clip can end on a non-zero sample; both click
# when the clip is dropped into silence. Mute the first 6 ms and fade 15 ms in and out.
def declick(a):
    import math
    mute, fade = int(0.006 * RATE), int(0.015 * RATE)
    end = len(a)
    while end > 0 and a[end - 1] == 0.0: end -= 1
    for k in range(min(mute, end)): a[k] = 0.0
    for k in range(min(fade, max(0, end - mute))):
        g = 0.5 - 0.5 * math.cos(math.pi * k / fade)
        a[mute + k] *= g
        a[end - 1 - k] *= g
    return a
clips = [declick(read(f"{work}/say{i}.wav")) for i in range(n)]
starts, t = [], LEAD
for c in clips:
    starts.append(t); t += len(c) + GAP
total = t
for i, c in enumerate(clips):
    a = array.array("f", bytes(4 * total)); a[starts[i]:starts[i] + len(c)] = c
    with open(f"{work}/object{i}.wav", "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + 4 * total) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 1, RATE, RATE * 4, 4, 32) + b"data" + struct.pack("<I", 4 * total))
        f.write(a.tobytes())
print(total / RATE, starts[-1] / RATE, (starts[-1] + len(clips[-1])) / RATE)
PY
read -r SECONDS_TOTAL SWEEP0 SWEEP1 < "$WORK/layout.txt"

ARGS=()
for i in $(seq 0 $((N - 1))); do ARGS+=(--pos "${PHRASES[$i]%%|*}" --audio "$WORK/object$i.wav"); done
"$OUT/export_test" "$CLAP" "$OUT/$NAME.wav" "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} --seconds "$SECONDS_TOTAL" --sweep "$N,$SWEEP0,$SWEEP1" --apac | grep -E "parameter|convert|APAC"
rm -f "$OUT/$NAME.bounce.wav"
# asaf_inspect.py only knows the packet layout of objects with default settings
if [ ${#EXTRA[@]} -eq 0 ]; then python3 "$HERE/asaf_inspect.py" "$OUT/$NAME.wav" | sed -n '/^Object metadata/,$p'; fi
