#!/bin/sh
# Runs every probe and diffs its output against expected/, so a change
# in the runtime's behaviour shows up as a diff instead of a number
# somebody has to remember.
#
# probe3 ends in a fatal runtime error and exit 70 — that IS its result,
# so the exit code is part of the compared output.
#
# Usage: ./build.sh && ./run.sh

set -e
cd "$(dirname "$0")"

probes="probe1_render_churn probe2_region_clean probe3_region_escape"
fail=0

for p in $probes; do
  if [ ! -x "build/$p/$p" ]; then
    echo "run.sh: $p is not built — run ./build.sh first" >&2
    exit 1
  fi
  out="build/$p/actual.txt"
  "./build/$p/$p" >"$out" 2>&1 && rc=0 || rc=$?
  printf 'exit=%s\n' "$rc" >>"$out"
  if diff -u "expected/$p.txt" "$out"; then
    echo "ok   $p"
  else
    echo "FAIL $p" >&2
    fail=1
  fi
done

exit $fail
