#!/bin/sh
# Runs the two programs whose result is their output, and diffs each
# against expected/, so a change in the core or in either spelling shows
# up as a diff instead of a number somebody has to remember.
#
# naive_crash.emo ends in E3007 and exit 70 — that IS its result, so the
# exit code is part of the compared output. It is the each_from bug's
# real symptom: the nested array is not an instance, so the backend's
# first `is()` raises before any render branch is reached.
#
# Absolute paths are stripped before comparing, so the goldens do not
# carry whoever ran this last.
#
# Usage: ./run.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
HERE=$PWD

run() {
  name=$1
  shift
  out=".emo-build/$name.actual.txt"
  "$@" >"$out" 2>&1 && rc=0 || rc=$?
  printf 'exit=%s\n' "$rc" >>"$out"
  sed "s|$HERE/||g" "$out" >"$out.norm"
  if diff -u "expected_$name.txt" "$out.norm"; then
    echo "ok   $name"
  else
    echo "FAIL $name" >&2
    fail=1
  fi
}

fail=0
run main "$EMO" run main.emo
run naive_crash "$EMO" run naive_crash.emo
exit $fail
