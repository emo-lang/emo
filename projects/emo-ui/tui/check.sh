#!/bin/sh
# The `ui_tui` package's gate: what type-checks, what runs, which hosted
# targets can compile the terminal backend, and the scripted-input
# golden's bytes.
#
#   ./check.sh
#
# The core's own gate is `../check.sh`; this one stages that core into a
# registry beside `ui_tui` so the package and its consumer resolve the
# way an application does.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

UP=$(cd .. && pwd)
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
  ( cd "$1" && EMO_REGISTRY="$REG" "$EMO" build "$2" --target "$3" -o "$OUT" ) \
    >"$OUT.log" 2>&1
}

# --- the registry: the core and this package, staged from source --------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has. The core's `test.emo` is left
# out: a dependency's modules are what a consumer reaches, and the core's
# test is the core package's own business.
sum=$(cat "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" | cksum | awk '{print $1}')
tsum=$(cat package.emo ui_tui.emo | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$tsum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_tui/0.1.0"
cp "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" "$REG/emo/ui/0.1.0/"
cp package.emo ui_tui.emo "$REG/emo/ui_tui/0.1.0/"

# --- the package type-checks, and its test runs -------------------------
#
# `emo check ui_tui.emo` checks the whole package, `test.emo` included.
# The test raises on a failed assertion, so its exit status is the result
# and the `ok` lines are the count of what ran.

EMO_REGISTRY="$REG" "$EMO" check ui_tui.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the backend and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the box model's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 13 "all thirteen assertions pass" "$n"

# --- which targets can compile the package ------------------------------
#
# `printf` is the one capability the terminal backend needs and `wasm`'s
# runtime does not have, so `wasm` is the target this package leaves out
# of its manifest and every other hosted target compiles it.

for t in ocaml c typescript beam wasm; do
  build . ui_tui.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  case $t in
    wasm) want=fails ;;
    *)    want=builds ;;
  esac
  expect "$want" "package --target $t" "$got"
done

why() {
  build "$1" "$2" "$3" && rc=0 || rc=$?
  got=$(grep -o -m1 "$4" "$OUT.log" || true)
  expect "$5" "$1 --target $3 says why" "$got"
}

why . ui_tui.emo wasm "builtin \`printf\` is not available on the wasm target" \
  "builtin \`printf\` is not available on the wasm target"

# --- the golden: one screen, the same bytes from every target -----------
#
# `golden/` is a consumer of both packages — a package of its own, with
# `emo/ui` and `emo/ui_tui` as dependencies — so it is built the way an
# application is: through the registry, out of `require`-d code. Its
# input is a script rather than a terminal, so the bytes are fixed.
#
# `expected.txt` is the interpreter's own output. Every target below has
# to produce those bytes exactly, so a box model that places a child
# differently — or an ANSI sequence that drifts — fails here.

G=$PWD/.emo-build/check/golden
mkdir -p "$G"

golden_build() {
  ( cd golden && EMO_REGISTRY="$REG" "$EMO" build main.emo --target "$1" -o \
      "$2/out" ) >"$OUT.log" 2>&1
}

run_golden() {
  case $1 in
    ocaml)      "$G/ocaml/out" >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    typescript) node "$G/typescript/out.ts" >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    beam)       erl -noshell -pa "$G/beam" \
                  -eval 'out:main(), erlang:halt(0).' >"$G/$1.txt" 2>&1 && rc=0 || rc=$? ;;
  esac
}

expect_same_file() {
  if cmp -s "$1" "$2"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s and %s differ\n' "$3" "$1" "$2" >&2
    diff "$1" "$2" >&2 || true
    fail=1
  fi
}

( cd golden && EMO_REGISTRY="$REG" "$EMO" run main.emo ) >"$G/interp.txt" 2>&1 \
  && rc=0 || rc=$?
expect 0 "the golden runs on the interpreter" "$rc"
expect_same_file golden/expected.txt "$G/interp.txt" \
  "and prints the file it is pinned to"

for t in ocaml typescript beam; do
  mkdir -p "$G/$t"
  golden_build "$t" "$G/$t" && rc=0 || rc=$?
  expect 0 "the golden builds for $t" "$rc"
  run_golden "$t"
  expect 0 "the golden exits 0 on $t" "$rc"
  expect_same_file golden/expected.txt "$G/$t.txt" \
    "the golden's bytes on $t are the interpreter's"
done

# `c` refuses the loop's shape, not the backend: `ui.run` takes the
# application's `view` and `update` as `Block` values, and a bare def name
# is the only expression that yields one (`CHECK.md`, the Elm loop's
# shape). The TUI backend itself compiles there.
golden_build c "$G/c" && rc=0 || rc=$?
got=$(grep -o -m1 "does not support this expression form (Global)" "$OUT.log" || true)
expect "does not support this expression form (Global)" \
  "the golden --target c says why" "$got"

# `wasm` is refused at resolution: the backend declares the four targets
# that can write stdout and `wasm` is not one of them.
golden_build wasm "$G/wasm" && rc=0 || rc=$?
got=$(grep -o -m1 "no build for target \`wasm\`" "$OUT.log" | head -1 || true)
expect "no build for target \`wasm\`" "the golden --target wasm says why" "$got"

exit $fail
