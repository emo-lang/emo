#!/bin/sh
# The fb backend's gate (emo-desktop A7.1, A7.2, A8.1, A8.2, A8.3, A9.1,
# A10.3): the six packages under `fb/` — the core (`emo/ui_fb`, with the
# bitmap font and the pointer sprite as its second and third modules), the
# hosted canvas (`emo/ui_fb_canvas`), the first frame with the counter
# (`emo/ui_fb_frame`), the window shell's windows (`emo/ui_fb_win`), the
# first apps (`emo/ui_apps`, the counter, the file browser and the
# editor) and their goldens — type-checked, their tests run, their
# targets built, their bytes compared, the font's table checked against
# its drawing, and the metal's lowering pinned without a machine.
#
#   ./check.sh
#
# The core's own gate is `projects/emo-ui/check.sh`; this one stages that
# core into a registry beside the fb packages so each resolves the way an
# application does. The OCaml target needs the toolchain on PATH
# (`eval "$(opam env)"`), as every gate in the tree does; the riscv64
# probe needs the riscv64-elf binutils and says so and passes without
# them, the way the platform gates do.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

UI=$(cd ../../emo-ui && pwd)
SYSCALL_SRC="$PWD/../../../stdlib/registry/syscall/0.1.0"
RUNNER=$UI/wasm-runner.mjs
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

# build <dir> <file> <target> [profile-args...] — status in $rc, log in
# $OUT.log. The subshell keeps the `cd` from leaking; the `&&`/`||`
# keeps `set -e` from ending the run.
build() {
  d=$1
  f=$2
  t=$3
  shift 3
  ( cd "$d" && EMO_REGISTRY="$REG" "$EMO" build "$f" --target "$t" "$@" -o "$OUT" ) \
    >"$OUT.log" 2>&1
}

# --- the registry: the core and the fb packages, staged from source -----
#
# The directory is named for the sources' content, so a run can never
# serve a module a package no longer has. A dependency's modules are
# what a consumer reaches, so each package is staged without its test;
# the goldens and the probe are consumers and are built in place.
sum=$(cat "$UI/package.emo" "$UI/ui.emo" "$UI/debug.emo" package.emo ui_fb.emo font.emo pointer.emo \
  canvas/package.emo canvas/ui_fb_canvas.emo frame/package.emo frame/ui_fb_frame.emo \
  frame/counter.emo win/package.emo win/ui_fb_win.emo \
  desktop/package.emo desktop/emo_desktop.emo \
  apps/package.emo apps/ui_apps.emo apps/counter.emo apps/files.emo apps/editor.emo \
  winbuf/package.emo winbuf/ui_fb_winbuf.emo \
  apps/counter/package.emo apps/counter/main.emo \
  apps/files/package.emo apps/files/main.emo \
  apps/editor/package.emo apps/editor/main.emo \
  "$SYSCALL_SRC/package.emo" "$SYSCALL_SRC/syscall.emo" \
  "$UI/corpus/package.emo" "$UI/corpus/main.emo" | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_fb/0.1.0" \
  "$REG/emo/ui_fb_canvas/0.1.0" "$REG/emo/ui_fb_frame/0.1.0" "$REG/emo/ui_fb_win/0.1.0" \
  "$REG/emo/ui_corpus/0.1.0" "$REG/emo_desktop/0.1.0" "$REG/emo/ui_apps/0.1.0" \
  "$REG/emo/ui_fb_winbuf/0.1.0" "$REG/syscall/0.1.0"
cp "$UI/package.emo" "$UI/ui.emo" "$UI/debug.emo" "$REG/emo/ui/0.1.0/"
cp package.emo ui_fb.emo font.emo pointer.emo "$REG/emo/ui_fb/0.1.0/"
cp canvas/package.emo canvas/ui_fb_canvas.emo "$REG/emo/ui_fb_canvas/0.1.0/"
cp frame/package.emo frame/ui_fb_frame.emo frame/counter.emo "$REG/emo/ui_fb_frame/0.1.0/"
cp desktop/package.emo desktop/emo_desktop.emo "$REG/emo_desktop/0.1.0/"
cp "$UI/corpus/package.emo" "$UI/corpus/main.emo" "$REG/emo/ui_corpus/0.1.0/"
cp win/package.emo win/ui_fb_win.emo "$REG/emo/ui_fb_win/0.1.0/"
cp apps/package.emo apps/ui_apps.emo apps/counter.emo apps/files.emo apps/editor.emo \
  "$REG/emo/ui_apps/0.1.0/"
cp winbuf/package.emo winbuf/ui_fb_winbuf.emo "$REG/emo/ui_fb_winbuf/0.1.0/"
cp "$SYSCALL_SRC/package.emo" "$SYSCALL_SRC/syscall.emo" "$REG/syscall/0.1.0/"

# --- the font's table is its drawing ------------------------------------
#
# `glyphs/glyphs.txt` is where the glyphs are drawn and `glyphs/gen.py` writes
# them into `font.emo`'s table; a table that no longer matches the drawing
# is refused here. The generator is Python 3's standard library, the same
# interpreter `run.sh` folds a screendump with; without it the check says
# so and passes, the way the platform gates do.

if command -v python3 >/dev/null 2>&1; then
  python3 glyphs/gen.py --check >"$OUT.log" 2>&1 && rc=0 || rc=$?
  expect 0 "the glyph table in font.emo is the drawing in glyphs/glyphs.txt" "$rc"
else
  printf 'skip the glyph table check: no python3 on PATH\n'
fi

# --- the packages type-check, and their tests run -----------------------
#
# `emo check <main module>` checks the whole package, its test included.
# A test raises on a failed assertion, so its exit status is the result
# and the `ok` lines are the count of what ran. The core's test is the
# arithmetic that needs no surface; the canvas's is everything that does.

EMO_REGISTRY="$REG" "$EMO" check ui_fb.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the core and its test type-check" "$rc"
EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the core's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 39 "all thirty-nine core assertions pass" "$n"

( cd canvas && EMO_REGISTRY="$REG" "$EMO" check ui_fb_canvas.emo ) >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the canvas and its test type-check" "$rc"
( cd canvas && EMO_REGISTRY="$REG" "$EMO" run test.emo ) >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the canvas's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 35 "all thirty-five canvas assertions pass" "$n"

( cd frame && EMO_REGISTRY="$REG" "$EMO" check ui_fb_frame.emo ) >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the first frame type-checks" "$rc"

( cd win && EMO_REGISTRY="$REG" "$EMO" check ui_fb_win.emo ) >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the window shell's windows type-check" "$rc"

( cd apps && EMO_REGISTRY="$REG" "$EMO" check counter.emo ) >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the counter app type-checks" "$rc"
( cd apps && EMO_REGISTRY="$REG" "$EMO" check files.emo ) >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the file browser app type-checks" "$rc"
( cd apps && EMO_REGISTRY="$REG" "$EMO" check editor.emo ) >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the editor app type-checks" "$rc"

# --- which targets compile the packages ---------------------------------
#
# Nothing in the four directories needs a capability a hosted runtime
# lacks, and the canvas directory — a `Surface` implementor beside its
# test — builds on all five. The core, the frame and the windows carry
# interfaces and no implementor of their own, and `beam` and `wasm` lower
# an interface call only against the classes in the program that
# implement it (`CHECK.md`), so a directory build of any refuses there
# while every consumer that brings a surface compiles: their `beam` and
# `wasm` claims are pinned by the goldens below, their other three here.
# The core, the frame and the windows declare `riscv64` too, and the
# probe after this is what pins that: a directory build cannot, because
# the canvas each test drives is a `Bytes`, which the riscv64 emitter does
# not lower — so the canvas does not declare the metal, and the metal's
# registry never carries a test. The loop itself lowers for the metal
# since A8.3 (its def values did not before), and the probe runs it.

for t in ocaml c typescript wasm beam; do
  build canvas ui_fb_canvas.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  expect builds "canvas --target $t" "$got"
done
for t in ocaml c typescript; do
  build . ui_fb.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  expect builds "core --target $t" "$got"
  build frame ui_fb_frame.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  expect builds "frame --target $t" "$got"
  build win ui_fb_win.emo "$t" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then got=builds; else got=fails; fi
  expect builds "windows --target $t" "$got"
done

# --- the metal's lowering, pinned without a machine ---------------------
#
# `probe/metal/` is a riscv64 user program that reaches the core, the
# frame, the windows and the core's own dependency, and runs the counter
# through the Elm loop against a counting surface (A8.3) and paints a
# window through it (A9.1): built, never run here —
# `run.sh` in `projects/emo-os` runs the real passes on the real carve.
# The build needs the riscv64-elf binutils the compiler links with.

if command -v riscv64-elf-ld >/dev/null 2>&1 || \
   command -v riscv64-unknown-elf-ld >/dev/null 2>&1; then
  build probe/metal main.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the core, the frame and the windows lower for a riscv64 user program" "$rc"
  build apps counter.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the counter app lowers for a riscv64 user program" "$rc"
  build apps files.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the file browser app lowers for a riscv64 user program" "$rc"
  build apps editor.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the editor app lowers for a riscv64 user program" "$rc"
  build apps/counter main.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the counter's program lowers for a riscv64 user image" "$rc"
  build apps/files main.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the file browser's program lowers for a riscv64 user image" "$rc"
  build apps/editor main.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the editor's program lowers for a riscv64 user image" "$rc"
  build winbuf ui_fb_winbuf.emo riscv64 --profile user && rc=0 || rc=$?
  expect 0 "the window buffer's metal side lowers for a riscv64 user image" "$rc"
else
  printf 'skip the metal probe: no riscv64-elf binutils on PATH\n'
fi

# --- the goldens: the same bytes from every target ----------------------
#
# Each golden is a consumer of the packages — a package of its own, with
# the fb packages as dependencies — so it is built the way an application
# is: through the registry, out of `require`-d code. `expected.txt` is
# the interpreter's own output, and every target has to produce those
# bytes exactly.
#
# `golden/` is the 48x32 scripted screen, whose input is a script rather
# than a device so the bytes are fixed; it writes its frame with
# `printf`, which `wasm`'s runtime does not have, so it declares the
# other four and the refusal is pinned. `frame/golden/` is the counter
# through the Elm loop at the display's baseline mode (A8.3) — one
# `frame <digest>` line per presented frame, the four lines `run.sh`
# asserts on the metal, the first the first frame's — and runs on all
# five. `win/golden/` is the window shell's two windows painted through
# the session the metal's shell pass runs (A9.1) — one line per present,
# the nine lines `run.sh` asserts and folds the display's windows to —
# and runs on all five.

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
    wasm)       node "$RUNNER" "$2/wasm/out.wasm" >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
    beam)       erl -noshell -pa "$2/beam" \
                  -eval 'out:main(), erlang:halt(0).' >"$2/$1.txt" 2>&1 && rc=0 || rc=$? ;;
  esac
}

# check_golden <dir> <expected> <outroot> <what> <targets...>
check_golden() {
  dir=$1
  want=$2
  root=$3
  what=$4
  shift 4
  mkdir -p "$root"
  # Only stdout is the program's bytes; a first run may say on stderr that
  # it wrote a missing `package.lock`.
  ( cd "$dir" && EMO_REGISTRY="$REG" "$EMO" run main.emo ) >"$root/interp.txt" \
    2>"$root/interp.err" && rc=0 || rc=$?
  expect 0 "the $what runs on the interpreter" "$rc"
  expect_same_file "$want" "$root/interp.txt" \
    "and prints the file it is pinned to"
  for t in "$@"; do
    golden_build "$dir" "$t" "$root/$t" && rc=0 || rc=$?
    expect 0 "the $what builds for $t" "$rc"
    run_target "$t" "$root"
    expect 0 "the $what exits 0 on $t" "$rc"
    expect_same_file "$want" "$root/$t.txt" \
      "the $what's bytes on $t are the interpreter's"
  done
}

check_golden golden golden/expected.txt "$PWD/.emo-build/check/golden" "golden" \
  ocaml c typescript beam
golden_build golden wasm "$PWD/.emo-build/check/golden/wasm" && rc=0 || rc=$?
got=$(grep -o -m1 "builtin \`printf\` is not available on the wasm target" \
  "$OUT.log" | head -1 || true)
expect "builtin \`printf\` is not available on the wasm target" \
  "the golden --target wasm says why" "$got"

check_golden frame/golden frame/golden/expected.txt \
  "$PWD/.emo-build/check/frame" "first frame" ocaml c typescript wasm beam

check_golden win/golden win/golden/expected.txt \
  "$PWD/.emo-build/check/win" "window shell's twin" ocaml c typescript wasm beam

# The convergence corpus (emo-desktop A10.1): the shared application
# the other backend families run, required whole from `emo/ui_corpus`
# and run through the Elm loop on the pixel surface — the whole node
# vocabulary (the counter, the form, the scrolled list, the image, the
# spacer) laid out and painted, the state transitions `update` says
# interleaved with the frames' digests. The sixth backend family runs
# what the other five run, the loop unchanged.
check_golden corpus corpus/expected.txt \
  "$PWD/.emo-build/check/corpus" "convergence corpus's twin" ocaml c typescript wasm beam

# The dock (emo-desktop A10.2): the desktop shell's strip in its three
# states, the press policy's probes beside — the desk era's screendump
# folds the strip's rectangle to these digests.
check_golden desktop/golden desktop/golden/expected.txt \
  "$PWD/.emo-build/check/desktop" "dock" ocaml c typescript wasm beam

# The first apps (emo-desktop A10.3): the counter, the file browser and
# the editor, each a corpus package under `emo/ui_apps`, run through the
# Elm loop at the app window's own size — the sessions the metal's
# passes run byte for byte, the frames' digests and the transitions
# `update` says one line each, `app <name> 0` closing each block. The
# lines `run.sh` asserts on the metal and folds the display's window
# rectangles to.
check_golden apps/golden apps/golden/expected.txt \
  "$PWD/.emo-build/check/apps" "first apps" ocaml c typescript wasm beam

exit $fail
