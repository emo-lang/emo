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
expect 17 "all seventeen assertions pass" "$n"

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

# Only stdout is the program's bytes. The first run of a dependency-carrying
# package also writes a missing `package.lock` and says so on stderr; that
# notice must not join the output a target is compared against.
run_of() {
  ( cd "$1" && "$EMO" run "$2" ) >"$OUT.run" 2>"$OUT.err" && rc=0 || rc=$?
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

# --- the divergence the golden is written around, and a fixed one --------
#
# Both were found while building the golden and both were silent: nothing
# refused, nothing failed, and the program still computed the same values —
# only the order of its side effects, or the bytes it printed, differed by
# target. Operand order is fixed now — pinned below — while the enum's
# display form remains open. `CHECK.md` records both; these pins are what
# keep its paragraphs from going stale.

# A side effect in an operand position lands in the order the target
# evaluates operands in. Every target, `ocaml` included, now evaluates
# left to right and prints the interpreter's line.
run_of probe/eval_order main.emo "12 = 3"

build probe/eval_order main.emo ocaml && rc=0 || rc=$?
expect 0 "eval_order --target ocaml builds" "$rc"
got=$("$OUT" 2>&1 || true)
expect "12 = 3" "eval_order -- ocaml evaluates operands left to right" "$got"

# An enum's display form: bare on the interpreter, module-qualified on
# `typescript`, and `beam` has no conversion for the kind and raises.
run_of probe/enum_print main.emo "red (ok, 12.5)"

build probe/enum_print main.emo typescript && rc=0 || rc=$?
got=$(node "$OUT.ts" 2>&1 || true)
expect "main.Color.red (R.ok, 12.5)" "enum_print -- typescript qualifies the tag" "$got"

build probe/enum_print main.emo beam && rc=0 || rc=$?
( cd "$(dirname "$OUT")" && ERL_CRASH_DUMP=/dev/null erl -noshell -pa . \
    -eval 'out:main(), erlang:halt(0).' ) >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 1 "enum_print -- beam raises rather than printing" "$rc"
got=$(grep -o -m1 "emo_no_to_str" "$OUT.run" || true)
expect "emo_no_to_str" "enum_print -- and names the conversion it lacks" "$got"

# --- the golden: one screen, the same bytes from every target ------------
#
# `golden/` is a consumer of the core — a package of its own, with
# `emo/ui` as a dependency — so it is built the way an application
# is: through a registry, out of `require`-d code. It is also the only
# build here that can reach every target, because the core's own package
# lowers `test.emo`, and `test.emo` hands the loop two bare defs.
#
# The registry is staged from the sources under test into a directory
# named for their content, so a run can never serve a module the package
# no longer has: `emo build` verifies the copy it materializes against
# the digest it fetched, and a stale file left in a fixed directory would
# be inside that digest on both sides.
#
# `expected.txt` is the interpreter's own output. Every target below has
# to produce those bytes exactly, so a backend that renders a tree
# differently — a float that prints short, an enum that prints qualified,
# a field order that drifts — fails here rather than in a screenshot.

sum=$(cat package.emo ui.emo debug.emo | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum
mkdir -p "$REG/emo/ui/0.1.0"
cp package.emo ui.emo debug.emo "$REG/emo/ui/0.1.0/"

G=$PWD/.emo-build/check/golden
mkdir -p "$G"

# golden_build <target> <outdir> — status in $rc, log in $OUT.log.
golden_build() {
  ( cd golden && EMO_REGISTRY="$REG" "$EMO" build main.emo --target "$1" -o \
      "$2/out" ) >"$OUT.log" 2>&1
}

# run_golden <target> — the target's bytes land in $G/<target>.txt, status
# in $rc. Each hosted target runs its artifact its own way.
run_golden() {
  case $1 in
    ocaml)      "$G/ocaml/out" >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    c)          "$G/c/out" >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    typescript) node "$G/typescript/out.ts" >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    beam)       erl -noshell -pa "$G/beam" \
                  -eval 'out:main(), erlang:halt(0).' >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
  esac
}

# expect_same_file <want> <got> <description>
expect_same_file() {
  if cmp -s "$1" "$2"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s and %s differ\n' "$3" "$1" "$2" >&2
    diff "$1" "$2" >&2 || true
    fail=1
  fi
}

( cd golden && EMO_REGISTRY="$REG" "$EMO" run main.emo ) >"$G/interp.txt" \
  2>"$G/interp.err" && rc=0 || rc=$?
expect 0 "the golden runs on the interpreter" "$rc"
expect_same_file golden/expected.txt "$G/interp.txt" \
  "and prints the file it is pinned to"

for t in ocaml c typescript beam; do
  mkdir -p "$G/$t"
  golden_build "$t" "$G/$t" && rc=0 || rc=$?
  expect 0 "the golden builds for $t" "$rc"
  run_golden "$t"
  expect 0 "the golden exits 0 on $t" "$rc"
  expect_same_file golden/expected.txt "$G/$t.txt" \
    "the golden's bytes on $t are the interpreter's"
done

# wasm is the one target that cannot lower the core at all: `App.deliver`
# calls a `Block` value with two arguments (`view_fn.read()(registry,
# next)`), and wasm's closures take one parameter. `probe/` pins the same
# refusal on its own; here it is pinned as what the golden inherits.
golden_build wasm "$G/wasm" && rc=0 || rc=$?
got=$(grep -o -m1 "only one-parameter closures are supported" "$OUT.log" || true)
expect "only one-parameter closures are supported" "the golden --target wasm says why" \
  "$got"

# --- the terminal backend's package gate --------------------------------
#
# `tui/` is a package of its own — it carries a platform the core does
# not — and has its own gate (T48.4). Run it here too, so the project
# keeps one entry point.
EMO="$EMO" ./tui/check.sh || fail=1

exit $fail
