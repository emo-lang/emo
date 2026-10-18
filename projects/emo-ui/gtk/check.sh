#!/bin/sh
# The `ui_gtk` package's gate: the box model's arithmetic, the GTK 4
# shim's build, and the convergence corpus running under the
# self-driving script.
#
#   ./check.sh
#
# The core's own gate is `../check.sh`; this one stages that core into a
# registry beside `ui_gtk` so the package and its consumer resolve the
# way an application does.
#
# GTK 4 is a Linux toolkit. On a host where `pkg-config gtk4` answers,
# the gate builds and runs natively (under Xvfb when there is no
# display); elsewhere it compiles and runs the same generated C in the
# `emo-ui-gtk-build` container, which is how a macOS host checks the
# backend. With neither, the gate says so and stops: there is nothing to
# check.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

IMAGE=${EMO_GTK_IMAGE:-emo-ui-gtk-build}

have_gtk() { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists gtk4 2>/dev/null; }
have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

MODE=none
if have_gtk; then
  MODE=native
elif have_docker; then
  MODE=docker
else
  printf 'skip the GTK 4 backend: no pkg-config gtk4 and no Docker\n'
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

# --- the registry: the core and this package, staged from source --------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has. `shim.c` is part of the
# digest too: the c target keys native sources by content.
sum=$(cat "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" | cksum | awk '{print $1}')
msum=$(cat package.emo ui_gtk.emo box.emo shim.c | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$msum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_gtk/0.1.0"
cp "$UP/package.emo" "$UP/ui.emo" "$UP/debug.emo" "$REG/emo/ui/0.1.0/"
cp package.emo ui_gtk.emo box.emo shim.c "$REG/emo/ui_gtk/0.1.0/"

# --- the box model type-checks, and its test runs ------------------------
#
# `box.emo` is pure Emo, so the interpreter runs the test: the foreign
# defs in `ui_gtk.emo` would be refused at load (E3009), which is why
# the layout lives in a module of its own.

EMO_REGISTRY="$REG" "$EMO" check test.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the box model and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the box model's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 20 "all twenty assertions pass" "$n"

# --- the shim and the package -------------------------------------------
#
# `ui_gtk.emo` compiles only where its verbs exist: the c target, with
# the manifest's pkg-config module. Every other target refuses at the
# foreign return before any emitter runs.

EMO_REGISTRY="$REG" "$EMO" check ui_gtk.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the backend and the shim type-check" "$rc"

# A package is not a program: the shim's symbols are linked by whoever
# consumes the package, which is the corpus build below, so what the
# targets below pin is the refusal, not a standalone binary.

for t in ocaml typescript beam wasm; do
  why . ui_gtk.emo "$t" \
    "foreign return must be Float64, String, or Bool on this target"
done

# --- the convergence corpus ---------------------------------------------
#
# `corpus/` is a consumer of both packages — a package of its own, with
# `emo/ui` and `emo/ui_gtk` as dependencies — so the application is
# written against the portable core and only the entry module names the
# backend. It uses every primitive, and its `update` prints each state
# transition, so `expected.txt` is the loop's bytes: the same file any
# other backend's corpus entry prints.
#
# `EMO_GUI_AUTOTEST` makes the shim click the tags in the script and then
# quit, so the run needs no one at the keyboard and no screenshot. The
# alarm is a hung run's failure, not a wait forever.

C=$PWD/corpus
COUT=$PWD/.emo-build/check/corpus
mkdir -p "$COUT"

if [ "$MODE" = native ]; then
  ( cd "$C" && EMO_REGISTRY="$REG" "$EMO" build main.emo --target c -o \
      "$COUT/out" ) >"$OUT.log" 2>&1 && rc=0 || rc=$?
  expect 0 "the corpus builds for c" "$rc"
  DISPLAY_RUN=
  if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
    DISPLAY_RUN=xvfb-run
  fi
  # The gate's display is headless, so it stays off the GL path (no
  # DRI3) and off the accessibility bus (no session bus); the renderer's
  # warnings are the environment's, not the program's bytes.
  GSK_RENDERER=cairo GTK_A11Y=none EGL_LOG_LEVEL=fatal EMO_GUI_AUTOTEST=1 \
    perl -e 'alarm 30; exec @ARGV' \
    ${DISPLAY_RUN:+"$DISPLAY_RUN" -a} "$COUT/out" \
    >"$COUT/run.txt" 2>"$COUT/run.err" && rc=0 || rc=$?
  expect 0 "the corpus's window run exits 0" "$rc"
else
  # The emo compiler is a host binary, so the host generates the C and
  # the container compiles it. `emo build` resolves the package's
  # `pkg_config` through the wrapper below — the manifest's module is
  # answered by the container's pkg-config, not skipped — and then fails
  # at cc, because the host has no GTK headers. That failure is expected;
  # what matters is that the generated C is there for the container.
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'building the %s image (one-time, apt pulls GTK 4)...\n' "$IMAGE"
    docker build -t "$IMAGE" . || exit 1
  fi
  BIN=$PWD/.emo-build/check/bin
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexec docker run --rm %s pkg-config "$@"\n' "$IMAGE" \
    >"$BIN/pkg-config"
  chmod +x "$BIN/pkg-config"

  ( cd "$C" && PATH="$BIN:$PATH" EMO_REGISTRY="$REG" "$EMO" build main.emo \
      --target c -o "$COUT/out" ) >"$OUT.log" 2>&1 && rc=0 || rc=$?
  if [ -f "$C/.emo-build/emo_defs.h" ]; then rc=0; else rc=1; fi
  expect 0 "the host generates the corpus's C" "$rc"

  REGREL=${REG#"$PWD/"}
  docker run --rm -e REGREL="$REGREL" -v "$PWD:/work" -w /work "$IMAGE" sh -c '
    set -e
    cc -O2 -ffp-contract=off -std=c11 -Wall -Wno-deprecated-declarations \
      -I corpus/.emo-build $(pkg-config --cflags gtk4) \
      corpus/.emo-build/main.c corpus/.emo-build/emo_c_runtime.c \
      "$REGREL/emo/ui_gtk/0.1.0/shim.c" \
      $(pkg-config --libs gtk4) -lm -o .emo-build/check/corpus/out
  ' >"$OUT.log" 2>&1 && rc=0 || rc=$?
  expect 0 "the container compiles and links the corpus" "$rc"

  docker run --rm -v "$PWD:/work" -w /work "$IMAGE" sh -c '
    GSK_RENDERER=cairo GTK_A11Y=none EGL_LOG_LEVEL=fatal EMO_GUI_AUTOTEST=1 \
      perl -e "alarm 30; exec @ARGV" xvfb-run -a \
      .emo-build/check/corpus/out
  ' >"$COUT/run.txt" 2>"$COUT/run.err" && rc=0 || rc=$?
  expect 0 "the corpus's window run exits 0" "$rc"
fi

expect_same_file "$C/expected.txt" "$COUT/run.txt" \
  "and prints the file it is pinned to"

# The dependency's manifest is reached before any emitter, so the
# corpus's refusal is `ui_gtk`'s target list, not the FFI.
why "$C" main.emo ocaml "does not declare the \`ocaml\` target" \
  "the corpus --target ocaml says why"

exit $fail
