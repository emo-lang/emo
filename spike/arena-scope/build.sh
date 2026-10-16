#!/bin/sh
# Builds the arena-scope probes.
#
# Each probe is compiled against a runtime that is the compiler's OWN
# emo_c_runtime.{c,h} with runtime/probe_arena.{c,h} appended. The
# probes need arena_bytes/mark/reset, which the shipped runtime does not
# declare; the append adds them without touching a single existing line,
# so the probes measure the shipped runtime rather than a modified one.
# Nothing under src/ changes, and the emitted runtime on disk is never
# rewritten — the concatenation lands in build/.
#
# The first `emo build` pass is expected to FAIL at link: the emitted
# main.c calls emo_arena_*, and the runtime `emo build` compiles it with
# is the stock one. It still writes .emo-build/main.c before it invokes
# cc, which is all this script needs to borrow — hence `|| true`, and
# hence the check that main.c actually landed and is not stale. Pass 1's
# log stays in build/<probe>/stock-pass.log as the evidence.
#
# Usage: ./build.sh [probe ...]     (default: every probe)

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
# this directory is the project root (its package.emo is the manifest),
# so the compiler path must be absolute before it travels
case "$EMO" in
  /*) ;;
  *) EMO="$PWD/$EMO" ;;
esac

default="probe1_render_churn probe2_region_clean probe3_region_escape"
probes=${*:-$default}

for p in $probes; do
  d=build/$p
  mkdir -p "$d"

  # The link is meant to fail here; `|| true` is not papering over a bug.
  # `emo build` runs from this directory — the package root — and writes
  # .emo-build/ here, so the binary goes to build/<probe>/ by path.
  "$EMO" build "$p.emo" -o "$d/$p" >"$d/stock-pass.log" 2>&1 || true

  main=".emo-build/main.c"
  if [ ! -f "$main" ] || [ "$main" -ot "$p.emo" ]; then
    echo "build.sh: $p: no fresh main.c emitted (see $d/stock-pass.log)" >&2
    exit 1
  fi

  # main.c's `#include "emo_c_runtime.h"` resolves against main.c's own
  # directory first, so the copy of main.c and the appended runtime pair
  # must sit together — and away from .emo-build's stock header.
  cp "$main" "$d/main.c"
  cat .emo-build/emo_c_runtime.h runtime/probe_arena.h >"$d/emo_c_runtime.h"
  cat .emo-build/emo_c_runtime.c runtime/probe_arena.c >"$d/emo_c_runtime.c"

  # the flags `emo build` uses for the c target, so the probe binary
  # differs from a stock one in nothing but the appended probes
  cc -O2 -ffp-contract=off -std=c11 -Wall -Wno-deprecated-declarations \
    -I "$d" "$d/main.c" "$d/emo_c_runtime.c" -lm -o "$d/$p"

  echo "built $d/$p"
done
