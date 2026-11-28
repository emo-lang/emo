#!/bin/sh
# The `ui_browser` package's gate: the style mapping's arithmetic, the
# backend's type check, and the convergence corpus running in a stub
# page.
#
#   ./check.sh
#
# The core's own gate is `../check.sh`; this one stages that core into a
# registry beside `ui_browser` so the package and its consumer resolve
# the way an application does.
#
# The browser target's bundling step strips the bundle's types with
# Node's own `module.stripTypeScriptTypes` (Node >= 22.13). Where Node is
# missing or too old there is no browser bundle to check, so the gate
# says so and stops.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac
STAGE=$(cd ../../.. && pwd)/scripts/stage-registry.sh

have_node() {
  command -v node >/dev/null 2>&1 &&
    node -e 'require("node:module").stripTypeScriptTypes' >/dev/null 2>&1
}

if ! have_node; then
  printf 'skip the browser backend: Node >= 22.13 is missing\n'
  exit 0
fi

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

# --- the registry: the core, the corpus and this package ---------------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has.

sum=$(cat "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" | cksum | awk '{print $1}')
csum=$(cat "$UP/corpus/package.emo" "$UP/corpus/main.emo" | cksum | awk '{print $1}')
msum=$(cat package.emo ui_browser.emo css.emo | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$csum-$msum
"$STAGE" "$REG"

# --- the style mapping type-checks, and its test runs -------------------
#
# `css.emo` is pure Emo, so the interpreter runs the test: the `dom_*`
# calls in `ui_browser.emo` are the browser host's, and the interpreter
# has no page.

EMO_REGISTRY="$REG" "$EMO" check test.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the style mapping and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the style mapping's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 27 "all twenty-seven assertions pass" "$n"

# --- the backend --------------------------------------------------------
#
# The checker types the `dom_*` family in every frame, so the backend
# type-checks anywhere; only the browser emitter gives the calls a host.

EMO_REGISTRY="$REG" "$EMO" check ui_browser.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the backend type-checks" "$rc"

# Every other emitter refuses the DOM family by name, so a page bundle
# cannot be produced for a host that has no `document`. (The `c` target
# drops the module's unreachable functions before lowering, so its
# refusal is not observable from a package that has no `main`; its
# manifest excludes the target as a dependency instead.)
why . ui_browser.emo typescript \
  "runtime implementation is not available on the typescript target; build for the browser target"
why . ui_browser.emo wasm "is not available on the wasm target"
why . ui_browser.emo beam "the runtime implementation"

# --- the convergence corpus ---------------------------------------------
#
# `corpus/` is the browser entry of the convergence corpus (T48.12): a
# package of its own, with the shared application `emo/ui_corpus` and
# this backend as dependencies, so only the entry module names the
# platform. The shared `update` prints each state transition, so
# `expected.txt` is the loop's bytes — the same file every other
# backend's entry is pinned to.
#
# `page.mjs` is the stub page: it installs `document` and `window`,
# imports the bundle, and steps the script — a tag clicked, `tag=text`
# typed into the field carrying the tag, `tag^key` pressed on it. The
# alarm is a hung run's failure, not a wait forever.

C=$PWD/corpus
COUT=$PWD/.emo-build/check/corpus
mkdir -p "$COUT"

( cd "$C" && EMO_REGISTRY="$REG" "$EMO" build main.emo --target browser -o \
    "$COUT/out" ) >"$OUT.log" 2>&1 && rc=0 || rc=$?
expect 0 "the corpus builds for browser" "$rc"

perl -e 'alarm 30; exec @ARGV' node page.mjs "$COUT/out.js" "0,0,1,3=hi,3^10,2" \
  >"$COUT/run.txt" 2>"$COUT/run.err" && rc=0 || rc=$?
expect 0 "the corpus's page run exits 0" "$rc"
expect_same_file "$C/expected.txt" "$COUT/run.txt" \
  "and prints the file it is pinned to"

# --- the backend's own golden: the page read back ------------------------
#
# `retained/` drives the backend by hand — one `mount`, then a `patch` a
# frame — and reads the page back through `dom_child`, marking each
# element `=` when the frame before already had it and `+` when the frame
# made it. That is the reconciliation seen from the page: a continued node
# keeps its element, a reorder moves, and a node below a replaced one is
# new. There is no script to click; the program steps its own frames.

R=$PWD/retained
ROUT=$PWD/.emo-build/check/retained
mkdir -p "$ROUT"

( cd "$R" && EMO_REGISTRY="$REG" "$EMO" build main.emo --target browser -o \
    "$ROUT/out" ) >"$OUT.log" 2>&1 && rc=0 || rc=$?
expect 0 "the retained frames build for browser" "$rc"
# A failed build leaves the last run's bundle where the page would read
# it, so the run is not attempted and its file emptied: nothing of a run
# before's can pass for this one's.
: >"$ROUT/run.txt"
if [ "$rc" = 0 ]; then
  perl -e 'alarm 30; exec @ARGV' node page.mjs "$ROUT/out.js" \
    >"$ROUT/run.txt" 2>"$ROUT/run.err" && rc=0 || rc=$?
else
  rc=99
fi
expect 0 "the retained frames' page run exits 0" "$rc"
expect_same_file "$R/expected.txt" "$ROUT/run.txt" \
  "and prints the file it is pinned to"

# The dependency's manifest is reached before any emitter, so the
# corpus's refusal is `ui_browser`'s target list, not the DOM family.
why "$C" main.emo typescript "does not declare the \`typescript\` target" \
  "the corpus --target typescript says why"

exit $fail
