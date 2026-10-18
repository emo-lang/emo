#!/bin/sh
# The `ui_macos` package's gate: the box model's arithmetic, the AppKit
# shim's build, and the convergence corpus running under the self-driving
# script.
#
#   ./check.sh
#
# The core's own gate is `../check.sh`; this one stages that core into a
# registry beside `ui_macos` so the package and its consumer resolve the
# way an application does.
#
# The window run needs a logged-in macOS session. On any other host the
# gate says so and stops: the shim links against AppKit, which does not
# exist elsewhere, so there is nothing to check.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

case $(uname -s) in
  Darwin) ;;
  *)
    printf 'skip the macOS backend: not a Darwin host\n'
    exit 0
    ;;
esac

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

why() {
  build "$1" "$2" "$3" && rc=0 || rc=$?
  got=$(grep -o -m1 "$4" "$OUT.log" || true)
  expect "$4" "$1 --target $3 says why" "$got"
}

# build <dir> <file> <target> — status in $rc, log in $OUT.log. The
# subshell keeps the `cd` from leaking; the `&&`/`||` keeps `set -e` from
# ending the run.
build() {
  ( cd "$1" && EMO_REGISTRY="$REG" "$EMO" build "$2" --target "$3" -o "$OUT" ) \
    >"$OUT.log" 2>&1
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

# --- the registry: the core and this package, staged from source --------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has. `shim.m` is part of the
# digest too: the c target keys native sources by content.
sum=$(cat "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" | cksum | awk '{print $1}')
msum=$(cat package.emo ui_macos.emo box.emo shim.m | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$msum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_macos/0.1.0"
cp "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" "$REG/emo/ui/0.1.0/"
cp package.emo ui_macos.emo box.emo shim.m "$REG/emo/ui_macos/0.1.0/"

# --- the box model type-checks, and its test runs ------------------------
#
# `box.emo` is pure Emo, so the interpreter runs the test: the foreign
# defs in `ui_macos.emo` would be refused at load (E3009), which is why
# the layout lives in a module of its own.

EMO_REGISTRY="$REG" "$EMO" check test.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the box model and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the box model's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 20 "all twenty assertions pass" "$n"

# --- the shim and the package -------------------------------------------
#
# `ui_macos.emo` compiles only where its verbs exist: the c target, with
# the manifest's AppKit framework. Every other target refuses at the
# foreign return before any emitter runs.

EMO_REGISTRY="$REG" "$EMO" check ui_macos.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the backend and the shim type-check" "$rc"

# A package is not a program: the shim's symbols are linked by whoever
# consumes the package, which is the corpus build below, so what the
# targets below pin is the refusal, not a standalone binary.

for t in ocaml typescript beam wasm; do
  why . ui_macos.emo "$t" \
    "foreign return must be Float64, String, or Bool on this target"
done

# --- the convergence corpus ---------------------------------------------
#
# `corpus/` is a consumer of both packages — a package of its own, with
# `emo/ui` and `emo/ui_macos` as dependencies — so the application is
# written against the portable core and only the entry module names the
# backend. It uses every primitive, and its `update` prints each state
# transition, so `expected.txt` is the loop's bytes: the same file any
# other backend's corpus entry prints.
#
# `EMO_GUI_AUTOTEST` makes the shim click the tags in the script and
# then terminate, so the run needs no one at the keyboard and no
# screenshot. The alarm is a hung run's failure, not a wait forever.

C=$PWD/corpus
COUT=$PWD/.emo-build/check/corpus
mkdir -p "$COUT"
( cd "$C" && EMO_REGISTRY="$REG" "$EMO" build main.emo --target c -o \
    "$COUT/out" ) >"$OUT.log" 2>&1 && rc=0 || rc=$?
expect 0 "the corpus builds for c" "$rc"

EMO_GUI_AUTOTEST=1 perl -e 'alarm 30; exec @ARGV' "$COUT/out" \
  >"$COUT/run.txt" 2>&1 && rc=0 || rc=$?
expect 0 "the corpus's window run exits 0" "$rc"
expect_same_file "$C/expected.txt" "$COUT/run.txt" \
  "and prints the file it is pinned to"

# The dependency's manifest is reached before any emitter, so the
# corpus's refusal is `ui_macos`'s target list, not the FFI.
why "$C" main.emo ocaml "does not declare the \`ocaml\` target" \
  "the corpus --target ocaml says why"

exit $fail
