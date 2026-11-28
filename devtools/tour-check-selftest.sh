#!/bin/sh
# tour-check-selftest — the checker must reject what the grammar forbids.
#
# Builds throwaway fixtures and asserts the exit code of each rejection:
# parse errors (2) for an unlabeled fence, a duplicate id, a require
# without deps, and a stray output block; block failures (1) for wrong
# stdout and for a program that does not compile.
#
#   devtools/tour-check-selftest.sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="$ROOT/devtools/tour-check.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/emo-tour-selftest.XXXXXX") || exit 3
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

pass=0
fail=0

expect() {
  name=$1
  want=$2
  file=$3
  "$CHECK" "$file" >"$TMP/$name.log" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s (exit %s, wanted %s)\n' "$name" "$got" "$want"
    sed 's/^/  /' "$TMP/$name.log"
    fail=$((fail + 1))
  fi
}

printf '# bad\n\n```emo id=a\nprintln(1)\n```\n' >"$TMP/unlabeled.md"
printf '# bad\n\n```emo run id=a\nprintln(1)\n```\n\n```emo run id=a\nprintln(2)\n```\n' >"$TMP/duplicate.md"
printf '# bad\n\n```emo run id=a deps=json\nrequire "yaml"\n```\n' >"$TMP/deps.md"
printf '# bad\n\n```output\nx\n```\n' >"$TMP/stray-output.md"
printf '# bad\n\n```emo run id=a\nprintln(1)\n```\n\n```output\n2\n```\n' >"$TMP/wrong-output.md"
printf '# bad\n\n```emo run id=a\nprintln(nope)\n```\n' >"$TMP/compile.md"

expect unlabeled 2 "$TMP/unlabeled.md"
expect duplicate 2 "$TMP/duplicate.md"
expect deps 2 "$TMP/deps.md"
expect stray-output 2 "$TMP/stray-output.md"
expect wrong-output 1 "$TMP/wrong-output.md"
expect compile 1 "$TMP/compile.md"

printf '%d checks, %d ok, %d failed\n' "$((pass + fail))" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
