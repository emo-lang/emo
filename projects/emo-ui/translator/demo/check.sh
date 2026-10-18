#!/bin/sh
# The translator's gate, in two diffs:
#
# 1. Regenerate screens.emo from screens.emoui and compare with the
#    committed generated file — a stale file or a translator change
#    shows up as a diff, never as a silently different tree.
# 2. Run show.emo — which asserts tree equality between the .emoui and
#    the A spelling on four models — and compare its output with
#    expected_show.txt.
#
# Absolute paths are stripped before comparing, so the goldens do not
# carry whoever ran this last.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-$(cd ../../../../_build/default/src/emo_cli && pwd)/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac
HERE=$PWD

mkdir -p .emo-build

# 1. the regenerated file matches the committed one
(cd .. && "$EMO" run translate.emo) < screens.emoui \
  > .emo-build/screens.regenerated.emo
if diff -u screens.emo .emo-build/screens.regenerated.emo; then
  echo "ok   regenerate: screens.emo is what the translator writes"
else
  echo "FAIL regenerate: screens.emo is stale or the translator changed" >&2
  exit 1
fi

# 2. the renders match, and the four assertions inside show.emo held
run_show() {
  out=".emo-build/show.actual.txt"
  "$EMO" run show.emo >"$out" 2>&1 && rc=0 || rc=$?
  printf 'exit=%s\n' "$rc" >>"$out"
  sed "s|$HERE/||g" "$out" >"$out.norm"
  if diff -u expected_show.txt "$out.norm"; then
    echo "ok   show: the .emoui trees render as the golden says"
  else
    echo "FAIL show: output differs from expected_show.txt" >&2
    exit 1
  fi
}
run_show
