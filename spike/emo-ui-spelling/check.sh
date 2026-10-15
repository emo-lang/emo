#!/bin/sh
# The checking results: what the A spelling catches, what it does not, and
# which hosted targets can compile the core at all.
#
#   ./check.sh
#
# Every line states its expectation first and is compared against it, so a
# compiler change that fixes one of these shows up as a FAIL here rather
# than as a silently stale paragraph in the README.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

mkdir -p .emo-build/check
OUT=$PWD/.emo-build/check/out
fail=0

# expect <want> <description> <got>
expect() {
  if [ "$1" = "$3" ]; then
    printf 'ok   %s\n' "$2"
  else
    printf 'FAIL %s: expected [%s], got [%s]\n' "$2" "$1" "$3" >&2
    fail=1
  fi
}

# build <dir> <target> — status in $rc, log in $OUT.log. The subshell keeps
# the `cd` from leaking; the `&&`/`||` keeps `set -e` from ending the run.
build() {
  ( cd "$1" && "$EMO" build main.emo --target "$2" -o "$OUT" ) >"$OUT.log" 2>&1
}

# --- the core and both spellings type-check -------------------------------

"$EMO" check main.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the core, both spellings and the debug backend type-check" "$rc"

"$EMO" check naive_crash.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the each_from idiom type-checks (which is the problem)" "$rc"

# --- what the A spelling catches, and what it does not --------------------
#
# The package holds two files with the same mistake — a String in a child
# slot. homogeneous.emo is diagnosed; mixed.emo is not, and draws no line
# of its own. So the package yields exactly one diagnostic, and it names
# homogeneous.emo. (A package is checked whole: `emo check <file>` loads
# every file beside it, not just the ones that file reaches — which is why
# an unreferenced broken file is caught.)

got=$(cd mismatch && "$EMO" check homogeneous.emo 2>&1 || true)
n=$(printf '%s' "$got" | grep -c 'mismatch/homogeneous.emo' || true)
codes=$(printf '%s\n' "$got" | grep -o 'error\[E[0-9]*\]' | sort -u | tr '\n' ' ')
expect 1 "a homogeneous child literal is diagnosed (and only it)" "$n"
expect "error[E4004] " "the code is E4004" "$codes"

n=$(printf '%s' "$got" | grep -c 'mismatch/mixed.emo' || true)
expect 0 "the same mistake beside a real node draws nothing" "$n"

# --- which targets can compile the core -----------------------------------

for t in ocaml c typescript wasm beam; do
  build . "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  case $t in
    typescript) want=builds ;;
    *)          want=fails ;;
  esac
  expect "$want" "core --target $t" "$got"
done

# --- and each failure names one cause -------------------------------------
#
# Three of the four are isolated in codegen/, where the other targets build
# the same file; the fourth is wasm and beam refusing Map, which only
# measure.emo uses.

why() {
  build "$1" "$2" && rc=0 || rc=$?
  got=$(grep -o -m1 "$3" "$OUT.log" || true)
  expect "$4" "$1 --target $2 says why" "$got"
}

why codegen/field_table       c     "redefinition of '[a-z_]*Holder__fields'" \
  "redefinition of 'main__Holder__fields'"
why codegen/native_string_add ocaml "string but an expression was expected of type" \
  "string but an expression was expected of type"
why .                         wasm  "the wasm target does not support Map yet" \
  "the wasm target does not support Map yet"
why .                         beam  "the beam target does not support Map yet" \
  "the beam target does not support Map yet"

# Isolated, neither defect travels: the c fixture builds on the four
# targets c is not broken on, and the ocaml one on the four ocaml is not.

for t in ocaml typescript wasm beam; do
  build codegen/field_table "$t" && rc=0 || rc=$?
  expect 0 "codegen/field_table --target $t builds" "$rc"
done

for t in c typescript wasm beam; do
  build codegen/native_string_add "$t" && rc=0 || rc=$?
  expect 0 "codegen/native_string_add --target $t builds" "$rc"
done

exit $fail
