#!/bin/bash
# Export test: does an export carry the object metadata that was set?
#
#   tools/export_test/run.sh            harness only (no DAW)
#   tools/export_test/run.sh --reaper   harness, then the same scenario rendered by REAPER
#   tools/export_test/run.sh --matrix   harness under other host behaviours (block size, transport, ...)
#   tools/export_test/run.sh --scene FILE   also export an ambisonic scene, alone and ahead of the objects.
#                                       FILE: ACN/SN3D audio with (order+1)^2 channels that afconvert can
#                                       read (e.g. a 16-channel third-order .m4a or .wav); 4 s of it are used
#   tools/export_test/run.sh --template N   export a project made from the installed N-object template
#                                       (64, 128, 192 or 256) with "Export project"; N + 64 audio channels
#
# Uses the installed ASAF.clap (override: ASAF_CLAP=<path>) and, for --reaper, the installed
# reaper_asaf.dylib, so run asaf_clap/build.sh and reaper_asaf/build.sh first. --reaper starts a new
# REAPER instance, which quits when the render is done (about 15 s).
#
# Output goes to tools/export_test/out (override: ASAF_TEST_OUT=<dir>). See README.md.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${ASAF_TEST_OUT:-$HERE/out}
CLAP=${ASAF_CLAP:-$HOME/Library/Audio/Plug-Ins/CLAP/ASAF.clap}
REAPER=${REAPER:-/Applications/REAPER.app/Contents/MacOS/REAPER}
INSPECT="python3 $HERE/asaf_inspect.py"
mkdir -p "$OUT"
[ -d "$CLAP" ] || { echo "No ASAF.clap at $CLAP: run asaf_clap/build.sh"; exit 2; }

clang++ -std=c++17 -fobjc-arc -O1 -I"$ROOT/modules/clap/include" -framework Foundation \
  -o "$OUT/export_test" "$ROOT/asaf_clap/tools/export_test.mm" "$ROOT/reaper_asaf/asaf_core.mm" || exit 2

SCENE=; TEMPLATE=
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  [ "${ARGS[i]}" = --scene ] && SCENE=${ARGS[i+1]:-}
  [ "${ARGS[i]}" = --template ] && TEMPLATE=${ARGS[i+1]:-}
done
EXTRA=()   # extra asaf_inspect.py options for the checks that follow
FAILED=()
# check <label> <file>: inspect a file against the scenario, keeping the full report next to it
check() {
  if [ ! -f "$2" ]; then echo "  FAIL  $1: $2 was not written"; FAILED+=("$1"); return; fi
  if $INSPECT "$2" ${EXTRA[@]+"${EXTRA[@]}"} > "${2%.wav}.report.txt" 2>&1; then echo "  ok    $1"
  else echo "  FAIL  $1"; grep -E "^  (FAIL|NOTE)" "${2%.wav}.report.txt" | head -6 | sed 's/^/        /'; FAILED+=("$1"); fi
}
# converted <label> <file>: as check, for the file that should have become an ASAF BWF
converted() {
  if [ -f "$2" ] && ! grep -q AIAM "$2"; then echo "  FAIL  $1: not converted (still a bounce file)"; FAILED+=("$1"); else check "$1" "$2"; fi
}
# wait_reaper <pid> <log> <seconds> <label>: wait for a test instance of REAPER to finish and quit. The
# script logs DONE when its work is over; if REAPER is still there 20 s later it is sitting at a
# "save project?" prompt (late parameter changes from the plug-ins mark the project modified), so end it.
wait_reaper() {
  local pid=$1 log=$2 limit=$3 label=$4 done_at=
  for ((t = 0; t < limit; t++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    if [ -z "$done_at" ] && grep -q "^DONE" "$log" 2>/dev/null; then done_at=$t; fi
    if [ -n "$done_at" ] && [ $((t - done_at)) -ge 20 ]; then kill "$pid" 2>/dev/null; sleep 2; return 0; fi
    sleep 1
  done
  echo "  REAPER did not finish within $limit s (a dialog may be open); see $log"; kill "$pid" 2>/dev/null; FAILED+=("$label: run")
}
# harness <name> [export_test options]: run the harness, check its bounce and its ASAF BWF
harness() {
  local name=$1; shift
  rm -f "$OUT/$name.wav" "$OUT/$name.bounce.wav"
  "$OUT/export_test" "$CLAP" "$OUT/$name.wav" "$@" > "$OUT/$name.log" 2>&1
  check "$name: bounce" "$OUT/$name.bounce.wav"
  converted "$name: ASAF BWF" "$OUT/$name.wav"
}

echo "Harness (ASAF.clap hosted like REAPER's offline render)"
EXTRA=(--expect)
harness harness

if [ -n "$SCENE" ]; then
  # 4 s of the scene as a 48 kHz float WAV, which is what the harness and the inspector read
  SCENEWAV="$OUT/scene_source.wav"
  afconvert -f WAVE -d LEF32@48000 "$SCENE" "$OUT/scene_full.wav" || { echo "could not decode $SCENE"; exit 2; }
  python3 - "$OUT/scene_full.wav" "$SCENEWAV" <<'PY' || exit 2
import struct, sys
f = open(sys.argv[1], "rb"); f.read(12); ch = 0
while True:
    h = f.read(8)
    if len(h) < 8: sys.exit("no audio in the decoded scene")
    cid, size = h[:4], struct.unpack("<I", h[4:])[0]
    if cid == b"fmt ": ch = struct.unpack("<H", f.read(size)[2:4])[0]
    elif cid == b"data": data = f.read(48000 * 4 * ch * 4); break
    else: f.seek(size + (size & 1), 1)
order = round(ch ** 0.5) - 1
if (order + 1) ** 2 != ch or order > 7: sys.exit(f"the scene file has {ch} channels, not (order+1)^2")
open(sys.argv[2], "wb").write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, ch, 48000, 48000 * ch * 4, ch * 4, 32) + b"data" + struct.pack("<I", len(data)) + data)
PY
  rm -f "$OUT/scene_full.wav"
  echo "Harness with an ambisonic scene"
  EXTRA=("--scene=$SCENEWAV")
  harness harness_scene --objects 0 --scene "$SCENEWAV"
  EXTRA=(--expect "--scene=$SCENEWAV")
  harness harness_scene_objects --scene "$SCENEWAV"
  EXTRA=(--expect)
fi

if [[ " $* " == *" --matrix "* ]]; then
  echo "Harness under other host behaviours (informational: failures show what ASAF Export depends on)"
  KEEP=("${FAILED[@]+"${FAILED[@]}"}")
  harness harness_realtime --mode realtime
  harness harness_blocked --mode blocked
  harness harness_nosettle --settle 0
  harness harness_block512 --block 512
  harness harness_block2048 --block 2048
  harness harness_stopped --stopped
  harness harness_notransport --no-transport
  harness harness_5objects --objects 5
  FAILED=("${KEEP[@]+"${KEEP[@]}"}")
fi

if [[ " $* " == *" --reaper "* ]]; then
  echo "REAPER"
  if pgrep -xq REAPER; then echo "  REAPER is already running: quit it first, or run reaper_export_test.lua from its action list"; exit 2; fi
  rm -f "$OUT"/reaper_export*.wav "$OUT/reaper_export_test.log"
  ASAF_TEST_PERFFLAGS=${ASAF_TEST_PERFFLAGS:-} ASAF_TEST_OUT="$OUT" ASAF_TEST_QUIT=1 ASAF_KEEP_BOUNCE=1 ASAF_NO_DIALOGS=1 ASAF_DEBUG=1 ASAF_CLAP_DEBUG=${ASAF_CLAP_DEBUG:-} \
    "$REAPER" -newinst -nosplash -new "$HERE/reaper_export_test.lua" > "$OUT/reaper_stderr.log" 2>&1 &
  wait_reaper $! "$OUT/reaper_export_test.log" 120 reaper
  if grep -q "PROBLEM" "$OUT/reaper_export_test.log" 2>/dev/null; then grep "PROBLEM" "$OUT/reaper_export_test.log" | sed 's/^/        /'; FAILED+=("reaper: script"); fi
  grep "reaper_asaf: " "$OUT/reaper_stderr.log" | grep -E "not converted|convert ok|block size|finish:" | sed 's/^.*reaper_asaf: /        sink: /'
  check "reaper: bounce" "$OUT/reaper_export.bounce.wav"
  converted "reaper: ASAF BWF" "$OUT/reaper_export.wav"
  if [ -n "$SCENE" ]; then
    echo "REAPER with an ambisonic scene"
    rm -f "$OUT"/reaper_scene*.wav "$OUT/reaper_scene_test.log"
    ASAF_TEST_SCENE="$SCENEWAV" ASAF_TEST_OUT="$OUT" ASAF_TEST_QUIT=1 ASAF_KEEP_BOUNCE=1 ASAF_NO_DIALOGS=1 ASAF_DEBUG=1 \
      "$REAPER" -newinst -nosplash -new "$HERE/reaper_export_test.lua" > "$OUT/reaper_scene_stderr.log" 2>&1 &
    wait_reaper $! "$OUT/reaper_scene_test.log" 120 "reaper scene"
    if grep -q "PROBLEM" "$OUT/reaper_scene_test.log" 2>/dev/null; then grep "PROBLEM" "$OUT/reaper_scene_test.log" | sed 's/^/        /'; FAILED+=("reaper scene: script"); fi
    grep "reaper_asaf: " "$OUT/reaper_scene_stderr.log" | grep -E "not converted|convert ok|block size|finish:" | sed 's/^.*reaper_asaf: /        sink: /'
    EXTRA=(--expect "--scene=$SCENEWAV")
    check "reaper scene: bounce" "$OUT/reaper_scene.bounce.wav"
    converted "reaper scene: ASAF BWF" "$OUT/reaper_scene.wav"
  fi
fi

if [ -n "$TEMPLATE" ]; then
  echo "REAPER, project from the $TEMPLATE-object template, Export project"
  if pgrep -xq REAPER; then echo "  REAPER is already running: quit it first"; exit 2; fi
  # the template's scene is 7th order: a 64-channel file with a tone on each of the first four channels
  SCENE7="$OUT/scene7_tones.wav"
  python3 - "$SCENE7" <<'PY'
import array, math, struct, sys
n, ch = 48000 * 4, 64
a = array.array("f", bytes(n * ch * 4))
for c in range(4):
    hz = 1000.0 + 250 * c
    for i in range(n): a[i * ch + c] = 0.1 * math.sin(2 * math.pi * hz * i / 48000)
d = a.tobytes()
open(sys.argv[1], "wb").write(b"RIFF" + struct.pack("<I", 36 + len(d)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, ch, 48000, 48000 * ch * 4, ch * 4, 32) + b"data" + struct.pack("<I", len(d)) + d)
PY
  rm -f "$OUT"/reaper_template*.wav "$OUT/reaper_template_test.log"
  ASAF_TEST_TEMPLATE="$TEMPLATE" ASAF_TEST_SCENE="$SCENE7" ASAF_TEST_OUT="$OUT" ASAF_TEST_QUIT=1 ASAF_KEEP_BOUNCE=1 ASAF_NO_DIALOGS=1 ASAF_DEBUG=1 \
    "$REAPER" -newinst -nosplash -new "$HERE/reaper_export_test.lua" > "$OUT/reaper_template_stderr.log" 2>&1 &
  wait_reaper $! "$OUT/reaper_template_test.log" 300 template
  if grep -q "PROBLEM" "$OUT/reaper_template_test.log" 2>/dev/null; then grep "PROBLEM" "$OUT/reaper_template_test.log" | sed 's/^/        /'; FAILED+=("template: script"); fi
  grep "reaper_asaf: " "$OUT/reaper_template_stderr.log" | grep -E "not exported|not converted|export:|block size" | sed 's/^.*reaper_asaf: /        /'
  EXTRA=(--expect "--scene=$SCENE7")
  converted "template: ASAF BWF" "$OUT/reaper_template.wav"
fi

echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "ALL OK   (reports: $OUT/*.report.txt)"; exit 0; fi
echo "${#FAILED[@]} FAILED   (reports: $OUT/*.report.txt)"; exit 1
