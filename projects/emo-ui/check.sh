#!/bin/sh
# The package's gate: what type-checks, what runs, and which hosted
# targets can compile the loop today.
#
#   ./check.sh
#
# Every expectation is stated before it is compared, so a change that
# moves one shows up as a FAIL here rather than as a silently stale
# paragraph in README.md. The one live gap is the loop's own shape: the
# application's `update` and `view` arrive as `Block` values, and a bare
# def name is the only expression that produces one — which the `c`
# target refuses (`Global`) and the `wasm` target refuses once the
# function takes more than one parameter. `probe/` holds that gap as a
# minimal pair, and the pin here is what keeps the paragraph honest.
# `CHECK.md` records the finding.
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

# build <dir> <file> <target> — status in $rc, log in $OUT.log. The
# subshell keeps the `cd` from leaking; the `&&`/`||` keeps `set -e` from
# ending the run.
build() {
  ( cd "$1" && "$EMO" build "$2" --target "$3" -o "$OUT" ) >"$OUT.log" 2>&1
}

# --- the package type-checks, and its test runs ---------------------------
#
# `emo check ui.emo` checks the whole package, `test.emo` included. The
# test raises on a failed assertion, so its exit status is the result and
# the `ok` lines are the count of what ran.

"$EMO" check ui.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the core and its test type-check" "$rc"

"$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the loop's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 14 "all fourteen assertions pass" "$n"

# --- which targets can compile the package -------------------------------
#
# The package is `ui.emo` plus `test.emo`, and the test is what calls
# `ui.run` with two bare defs. So the two refusals below are the loop's
# shape, not the core's: `probe/` splits them apart.

for t in ocaml c typescript wasm beam; do
  build . ui.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  case $t in
    c | wasm) want=fails ;;
    *)        want=builds ;;
  esac
  expect "$want" "package --target $t" "$got"
done

# --- and each refusal names its cause ------------------------------------
#
# The line is the whole diagnostic the target prints, so a drift in the
# message fails here.

why() {
  build "$1" "$2" "$3" && rc=0 || rc=$?
  got=$(grep -o -m1 "$4" "$OUT.log" || true)
  expect "$5" "$1 --target $3 says why" "$got"
}

why . ui.emo c "does not support this expression form (Global)" \
  "does not support this expression form (Global)"
why . ui.emo wasm "only one-parameter closures are supported" \
  "only one-parameter closures are supported"

# --- the gap as a minimal pair -------------------------------------------
#
# `def_shape` is the landed shape in miniature — two defs handed over as
# `Block` values — so it reaches both refusals. `handler_shape` is the
# same loop with those two functions behind an interface, and every
# target compiles it. Neither is a package of the core: each has its own
# `package.emo`, so the walk leaves them out of `ui`'s package.

run_of() {
  ( cd "$1" && "$EMO" run "$2" ) >"$OUT.run" 2>&1 && rc=0 || rc=$?
  expect "$3" "$1 -- emo run prints what the test expects" "$(cat "$OUT.run")"
  expect 0 "$1 -- emo run exits 0" "$rc"
}

run_of probe/def_shape main.emo "count 1"

for t in ocaml c typescript wasm beam; do
  build probe/def_shape main.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  case $t in
    c | wasm) want=fails ;;
    *)        want=builds ;;
  esac
  expect "$want" "def_shape --target $t" "$got"
done

run_of probe/handler_shape main.emo "count 1"

for t in ocaml c typescript wasm beam; do
  build probe/handler_shape main.emo "$t" && rc=0 || rc=$?
  expect 0 "handler_shape --target $t builds" "$rc"
done

# A build is not a result: the two targets that can run it have to print
# what the interpreter prints, so a miscompiled loop cannot pass here.
for t in ocaml c; do
  build probe/handler_shape main.emo "$t" && rc=0 || rc=$?
  got=$("$OUT" 2>&1 || true)
  expect "count 1" "handler_shape --target $t prints what emo run prints" "$got"
done

exit $fail
