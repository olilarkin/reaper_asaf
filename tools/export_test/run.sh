#!/bin/bash
# Export test: does an export carry the object metadata that was set?
#
#   tools/export_test/run.sh            harness only (no DAW)
#   tools/export_test/run.sh --reaper   harness, then the same scenario rendered by REAPER
#   tools/export_test/run.sh --matrix   harness under other host behaviours (block size, transport, ...)
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

FAILED=()
# check <label> <file>: inspect a file against the scenario, keeping the full report next to it
check() {
  if [ ! -f "$2" ]; then echo "  FAIL  $1: $2 was not written"; FAILED+=("$1"); return; fi
  if $INSPECT "$2" --expect > "${2%.wav}.report.txt" 2>&1; then echo "  ok    $1"
  else echo "  FAIL  $1"; grep -E "^  (FAIL|NOTE)" "${2%.wav}.report.txt" | head -6 | sed 's/^/        /'; FAILED+=("$1"); fi
}
# converted <label> <file>: as check, for the file that should have become an ASAF BWF
converted() {
  if [ -f "$2" ] && ! grep -q AIAM "$2"; then echo "  FAIL  $1: not converted (still a bounce file)"; FAILED+=("$1"); else check "$1" "$2"; fi
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
harness harness

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
    "$REAPER" -newinst -nosplash "$HERE/reaper_export_test.lua" > "$OUT/reaper_stderr.log" 2>&1 &
  PID=$!
  for _ in $(seq 120); do kill -0 $PID 2>/dev/null || break; sleep 1; done
  if kill -0 $PID 2>/dev/null; then echo "  REAPER did not finish within 2 minutes (a dialog may be open); see $OUT/reaper_export_test.log"; FAILED+=("reaper: run"); fi
  if grep -q "PROBLEM" "$OUT/reaper_export_test.log" 2>/dev/null; then grep "PROBLEM" "$OUT/reaper_export_test.log" | sed 's/^/        /'; FAILED+=("reaper: script"); fi
  grep "reaper_asaf: " "$OUT/reaper_stderr.log" | grep -E "not converted|convert ok|block size|finish:" | sed 's/^.*reaper_asaf: /        sink: /'
  check "reaper: bounce" "$OUT/reaper_export.bounce.wav"
  converted "reaper: ASAF BWF" "$OUT/reaper_export.wav"
fi

echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "ALL OK   (reports: $OUT/*.report.txt)"; exit 0; fi
echo "${#FAILED[@]} FAILED   (reports: $OUT/*.report.txt)"; exit 1
