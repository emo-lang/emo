#!/bin/sh
# The convergence corpus's gate (T48.12): one portable application, run
# unchanged on every backend. This package is the application module —
# `emo/ui_corpus` — and the entries under it are the debug, SSR and
# terminal backends' thin entry modules; the macOS, GTK 4 and browser
# entries live in those packages and are driven by their own gates.
#
#   ./check.sh
#
# The core's own gate is `../check.sh`; this one stages the core, the
# corpus application and the three backends into a registry so each entry
# resolves the way an application does.
#
# The debug and SSR entries must be byte-identical on all five hosted
# targets, `c` and `ocaml` included; the terminal entry has four targets
# (`wasm` has no `printf`) and its refusal is pinned instead.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

UP=$(cd .. && pwd)
RUNNER=$UP/wasm-runner.mjs
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

expect_same_file() {
  if cmp -s "$1" "$2"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s and %s differ\n' "$3" "$1" "$2" >&2
    diff "$1" "$2" >&2 || true
    fail=1
  fi
}

# --- the registry: the core, the corpus and its backends ----------------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has. The core's `test.emo` is left
# out: a dependency's modules are what a consumer reaches, and the core's
# test is the core package's own business.

sum=$(cat "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" | cksum | awk '{print $1}')
csum=$(cat package.emo main.emo | cksum | awk '{print $1}')
ssum=$(cat "$UP/ssr/package.emo" "$UP/ssr/ui_ssr.emo" | cksum | awk '{print $1}')
tsum=$(cat "$UP/tui/package.emo" "$UP/tui/ui_tui.emo" | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$csum-$ssum-$tsum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_corpus/0.1.0" \
  "$REG/emo/ui_ssr/0.1.0" "$REG/emo/ui_tui/0.1.0"
cp "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" "$REG/emo/ui/0.1.0/"
cp package.emo main.emo "$REG/emo/ui_corpus/0.1.0/"
cp "$UP/ssr/package.emo" "$UP/ssr/ui_ssr.emo" "$REG/emo/ui_ssr/0.1.0/"
cp "$UP/tui/package.emo" "$UP/tui/ui_tui.emo" "$REG/emo/ui_tui/0.1.0/"

# --- the corpus application type-checks ---------------------------------
#
# The shared module names no host, so the interpreter checks it against
# the portable core alone.

EMO_REGISTRY="$REG" "$EMO" check main.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the shared application type-checks" "$rc"

# --- one entry, one backend, every host its package declares ------------
#
# Each entry is a package of its own; `expected.txt` is the interpreter's
# own output, and every target below has to produce those bytes exactly.
# Only stdout is the program's bytes.

entry_build() {
  mkdir -p "$3"
  ( cd "$1" && EMO_REGISTRY="$REG" "$EMO" build main.emo --target "$2" -o \
      "$3/out" ) >"$OUT.log" 2>&1
}

run_target() {
  case $1 in
    ocaml)      "$2/ocaml/out" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    c)          "$2/c/out" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    typescript) node "$2/typescript/out.ts" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    wasm)       node "$RUNNER" "$2/wasm/out.wasm" >"$2/$1.txt" \
                  2>&1 && rc=0 || rc=$? ;;
    beam)       erl -noshell -pa "$2/beam" \
                  -eval 'out:main(), erlang:halt(0).' >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
  esac
}

check_entry() {
  dir=$1
  want=$2
  root=$3
  what=$4
  shift 4
  mkdir -p "$root"
  ( cd "$dir" && EMO_REGISTRY="$REG" "$EMO" run main.emo ) >"$root/interp.txt" \
    2>"$root/interp.err" && rc=0 || rc=$?
  expect 0 "the $what runs on the interpreter" "$rc"
  expect_same_file "$want" "$root/interp.txt" \
    "and prints the file it is pinned to"
  for t in "$@"; do
    entry_build "$dir" "$t" "$root/$t" && rc=0 || rc=$?
    expect 0 "the $what builds for $t" "$rc"
    run_target "$t" "$root"
    expect 0 "the $what exits 0 on $t" "$rc"
    expect_same_file "$want" "$root/$t.txt" \
      "the $what's bytes on $t are the interpreter's"
  done
}

check_entry debug debug/expected.txt "$PWD/.emo-build/check/debug" \
  "debug entry" ocaml c typescript wasm beam
check_entry ssr ssr/expected.txt "$PWD/.emo-build/check/ssr" \
  "SSR entry" ocaml c typescript wasm beam
check_entry tui tui/expected.txt "$PWD/.emo-build/check/tui" \
  "terminal entry" ocaml c typescript beam

# The terminal backend declares four targets: `wasm` has no `printf`, so
# resolution refuses before any emitter runs.
entry_build tui wasm "$PWD/.emo-build/check/tui/wasm" && rc=0 || rc=$?
got=$(grep -o -m1 "does not declare the \`wasm\` target" "$OUT.log" \
  | head -1 || true)
expect "does not declare the \`wasm\` target" \
  "the terminal entry --target wasm says why" "$got"

exit $fail
