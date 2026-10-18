#!/bin/sh
# The `ui_ssr` package's gate: what type-checks, what runs, which hosted
# targets compile the renderer, and the golden's bytes on every one.
#
#   ./check.sh
#
# The core's own gate is `../check.sh`; this one stages that core into a
# registry beside `ui_ssr` so the package and its consumers resolve the
# way an application does.
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
ssum=$(cat package.emo ui_ssr.emo | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$ssum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_ssr/0.1.0"
cp "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" "$REG/emo/ui/0.1.0/"
cp package.emo ui_ssr.emo "$REG/emo/ui_ssr/0.1.0/"

# --- the package type-checks, and its test runs -------------------------
#
# `emo check ui_ssr.emo` checks the whole package, `test.emo` included.
# The test raises on a failed assertion, so its exit status is the result
# and the `ok` lines are the count of what ran.

EMO_REGISTRY="$REG" "$EMO" check ui_ssr.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the renderer and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the renderer's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 12 "all twelve assertions pass" "$n"

# --- which targets can compile the package ------------------------------
#
# The renderer names no host, so every target can lower it — the
# package's own test included: it hands `ui.run` two bare defs, and every
# target has def-as-value since `c` grew it (T48.8).

for t in ocaml c typescript wasm beam; do
  build . ui_ssr.emo "$t" && rc=0 || rc=$?
  expect 0 "package --target $t builds" "$rc"
done

# --- the golden: one page, the same bytes from every target -------------
#
# `golden/` is a consumer of both packages — a package of its own, with
# `emo/ui` and `emo/ui_ssr` as dependencies — so it is built the way an
# application is: through the registry, out of `require`-d code. It calls
# the entry points directly rather than handing `ui.run` two defs, so
# every hosted target lowers it; `wasm`'s artifact runs under the host
# boundary in `../wasm-runner.mjs`.
#
# `expected.txt` is the interpreter's own output. Every target below has
# to produce those bytes exactly, so a renderer that orders classes
# differently, escapes one character another way, or rounds a float
# differently fails here rather than in a browser.

expect_same_file() {
  if cmp -s "$1" "$2"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s and %s differ\n' "$3" "$1" "$2" >&2
    diff "$1" "$2" >&2 || true
    fail=1
  fi
}

corpus_build() {
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

check_corpus() {
  dir=$1
  want=$2
  root=$3
  what=$4
  mkdir -p "$root"
  # Only stdout is the program's bytes; a first run may say on stderr that
  # it wrote a missing `package.lock`.
  ( cd "$dir" && EMO_REGISTRY="$REG" "$EMO" run main.emo ) >"$root/interp.txt" \
    2>"$root/interp.err" && rc=0 || rc=$?
  expect 0 "the $what runs on the interpreter" "$rc"
  expect_same_file "$want" "$root/interp.txt" \
    "and prints the file it is pinned to"
  for t in ocaml c typescript wasm beam; do
    corpus_build "$dir" "$t" "$root/$t" && rc=0 || rc=$?
    expect 0 "the $what builds for $t" "$rc"
    run_target "$t" "$root"
    expect 0 "the $what exits 0 on $t" "$rc"
    expect_same_file "$want" "$root/$t.txt" \
      "the $what's bytes on $t are the interpreter's"
  done
}

# `golden/` is the byte-for-byte page; `examples/ssr_page/` is the usage
# demo, a package of its own with the same two deps, so the same registry
# serves it. It is not part of the compiler's example suites — it needs
# EmoUI's registry, which those suites do not carry — so this gate is
# where it is checked.
check_corpus golden golden/expected.txt "$PWD/.emo-build/check/golden" "golden"
EX=$PWD/../../../examples/ssr_page
check_corpus "$EX" "$EX/expected.txt" "$PWD/.emo-build/check/example" "example"

exit $fail
