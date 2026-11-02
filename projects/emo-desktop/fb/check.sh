#!/bin/sh
# The `ui_fb` package's gate (emo-desktop A7.1): what type-checks, what
# runs, which hosted targets can compile the framebuffer backend, and the
# scripted-input golden's bytes.
#
#   ./check.sh
#
# The core's own gate is `projects/emo-ui/check.sh`; this one stages that
# core into a registry beside `ui_fb` so the package and its consumer
# resolve the way an application does. The OCaml target needs the
# toolchain on PATH (`eval "$(opam env)"`), as every gate in the tree does.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

UI=$(cd ../../emo-ui && pwd)
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
# serve a module the package no longer has. A dependency's modules are
# what a consumer reaches, so the core is staged as `ui.emo` alone: the
# fb backend never names `ui.debug`, which is a host backend of its own
# with the core's own gate behind it. This package's `test.emo` is left
# out for the same reason.
sum=$(cat "$UI/package.emo" "$UI/ui.emo" | cksum | awk '{print $1}')
fsum=$(cat package.emo ui_fb.emo canvas.emo | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$fsum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_fb/0.1.0"
cp "$UI/package.emo" "$UI/ui.emo" "$REG/emo/ui/0.1.0/"
cp package.emo ui_fb.emo canvas.emo "$REG/emo/ui_fb/0.1.0/"

# --- the package type-checks, and its test runs -------------------------
#
# `emo check ui_fb.emo` checks the whole package, `canvas.emo` and
# `test.emo` included. The test raises on a failed assertion, so its exit
# status is the result and the `ok` lines are the count of what ran.

EMO_REGISTRY="$REG" "$EMO" check ui_fb.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the backend and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the pixel arithmetic's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 36 "all thirty-six assertions pass" "$n"

# --- which targets can compile the package ------------------------------
#
# The core is pure Emo against the `Surface` interface and the canvas is
# a `Bytes`, so nothing here needs a capability any hosted runtime lacks:
# all five compile it, `wasm` included. The metal is not a hosted target;
# the carve surface that lets the core dual-run there is A7.2's.

for t in ocaml c typescript wasm beam; do
  build . ui_fb.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  expect builds "package --target $t" "$got"
done

# --- the golden: one application, the same bytes from every target ------
#
# `golden/` is a consumer of both packages — a package of its own, with
# `emo/ui` and `emo/ui_fb` as dependencies — so it is built the way an
# application is: through the registry, out of `require`-d code. Its
# input is a script rather than a device, so the bytes are fixed.
#
# `expected.txt` is the interpreter's own output. Every target below has
# to produce those bytes exactly, so a box model that places a child
# differently — or a channel that lands in the wrong byte — fails here.
# The golden writes its frame with `printf`, which `wasm`'s runtime does
# not have, so it declares the other four and the refusal is pinned.

expect_same_file() {
  if cmp -s "$1" "$2"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s and %s differ\n' "$3" "$1" "$2" >&2
    diff "$1" "$2" >&2 || true
    fail=1
  fi
}

golden_build() {
  mkdir -p "$3"
  ( cd "$1" && EMO_REGISTRY="$REG" "$EMO" build main.emo --target "$2" -o \
      "$3/out" ) >"$OUT.log" 2>&1
}

run_target() {
  case $1 in
    ocaml)      "$2/ocaml/out" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    c)          "$2/c/out" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    typescript) node "$2/typescript/out.ts" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    beam)       erl -noshell -pa "$2/beam" \
                  -eval 'out:main(), erlang:halt(0).' >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
  esac
}

check_golden() {
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
  for t in ocaml c typescript beam; do
    golden_build "$dir" "$t" "$root/$t" && rc=0 || rc=$?
    expect 0 "the $what builds for $t" "$rc"
    run_target "$t" "$root"
    expect 0 "the $what exits 0 on $t" "$rc"
    expect_same_file "$want" "$root/$t.txt" \
      "the $what's bytes on $t are the interpreter's"
  done
  golden_build "$dir" wasm "$root/wasm" && rc=0 || rc=$?
  got=$(grep -o -m1 "builtin \`printf\` is not available on the wasm target" \
    "$OUT.log" | head -1 || true)
  expect "builtin \`printf\` is not available on the wasm target" \
    "the $what --target wasm says why" "$got"
}

check_golden golden golden/expected.txt "$PWD/.emo-build/check/golden" "golden"

exit $fail
