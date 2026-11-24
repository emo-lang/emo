#!/bin/sh
# The calculator's gate: the application's arithmetic and keys, and one
# session's displays on every backend.
#
#   ./check.sh
#
# `emo/ui_calculator` is the application — a model, a pure `update` and a
# pure `view` that name no platform — and each directory below it is one
# platform's entry: a package of its own with the application and that
# platform's backend as dependencies, so only an entry names the
# platform. `expected.txt` is the headless entry's output on the
# interpreter: the display after every frame of the hosted session. Every
# other entry prints the same line a frame, so each is pinned to that
# file's first lines — all of it where a frame is a line, the window
# session's lines where a frame is a screen, the page session's where a
# frame is a document.
#
# The hosted entries must be byte-identical on all five hosted targets,
# `c` and `ocaml` included — the framebuffer's on four, and on `beam` for
# the page session, a frame of pixels costing seconds there. The window
# entries (AppKit, GTK 4) and the page run where they are built for: the
# macOS window needs a Darwin host and a logged-in session, the GTK
# window GTK 4 or the `emo-ui-gtk-build` container, and the page
# Node >= 22.13; each says so and passes where its platform is missing.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac
ROOT=$(cd ../../../.. && pwd)
STAGE=$ROOT/scripts/stage-registry.sh
UI=$ROOT/projects/emo-ui
RUNNER=$UI/wasm-runner.mjs
PAGE=$UI/browser/page.mjs
IMAGE=${EMO_GTK_IMAGE:-emo-ui-gtk-build}

have_node() {
  command -v node >/dev/null 2>&1 &&
    node -e 'require("node:module").stripTypeScriptTypes' >/dev/null 2>&1
}
have_gtk() { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists gtk4 2>/dev/null; }
have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# A frame of the window session's trace (fifty-four keys and the mount),
# and one of the page session's.
WINDOW_LINES=55
PAGE_LINES=7

mkdir -p .emo-build/check
OUT=$PWD/.emo-build/check/out
W=$PWD/.emo-build/check
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

# build <dir> <entry> <target> <artifact> — status in $rc, log in
# $OUT.log. The subshell keeps the `cd` from leaking; the `&&`/`||`
# keeps `set -e` from ending the run.
build() {
  ( cd "$1" && EMO_REGISTRY="$REG" "$EMO" build "$2" --target "$3" -o "$4" ) \
    >"$OUT.log" 2>&1
}

# run_target <target> <artifact> <capture> — the artifact a target builds
# runs the way that target runs it, and its bytes land in the capture.
run_target() {
  case $1 in
    ocaml)      "$2" >"$3" 2>&1 && rc=0 || rc=$? ;;
    c)          "$2" >"$3" 2>&1 && rc=0 || rc=$? ;;
    typescript) node "$2.ts" >"$3" 2>&1 && rc=0 || rc=$? ;;
    wasm)       node "$RUNNER" "$2.wasm" >"$3" 2>&1 && rc=0 || rc=$? ;;
    beam)       ( cd "$(dirname "$2")" && ERL_CRASH_DUMP=/dev/null timeout 120 \
                    erl -noshell -pa . -eval 'out:main(), erlang:halt(0).' ) \
                  >"$3" 2>&1 && rc=0 || rc=$? ;;
  esac
}

# hosted <dir> <entry> <pinned> <what> <targets...> — one entry on the
# interpreter, then on each target: it runs, it builds, it exits 0, and
# its bytes are the interpreter's.
hosted() {
  dir=$1
  entry=$2
  want=$3
  what=$4
  shift 4
  root=$PWD/.emo-build/check/$dir
  mkdir -p "$root"
  ( cd "$dir" && EMO_REGISTRY="$REG" "$EMO" run "$entry.emo" ) >"$root/interp.txt" \
    2>"$root/interp.err" && rc=0 || rc=$?
  expect 0 "the $what runs on the interpreter" "$rc"
  expect_same_file "$want" "$root/interp.txt" \
    "and prints the file it is pinned to"
  for t in "$@"; do
    mkdir -p "$root/$t"
    # The capture is emptied first: a failed build leaves the last run's
    # artifact where the target would read it, and nothing of a run
    # before's may pass for this one's.
    : >"$root/$t.txt"
    build "$dir" "$entry.emo" "$t" "$root/$t/out" && rc=0 || rc=$?
    expect 0 "the $what builds for $t" "$rc"
    if [ "$rc" = 0 ]; then
      run_target "$t" "$root/$t/out" "$root/$t.txt"
    else
      rc=99
    fi
    expect 0 "the $what exits 0 on $t" "$rc"
    expect_same_file "$want" "$root/$t.txt" \
      "the $what's bytes on $t are the interpreter's"
  done
}

# host_c <entry> <artifact> — the host generates a GTK entry's C. `emo
# build` resolves the dependency's `pkg_config` through the wrapper the
# GTK leg puts on PATH ($BIN) and then fails at cc, because the host has
# no GTK headers. That failure is expected; what matters is that this
# run got as far as the compiler and left the C there for the container —
# always as `main.c`, whichever entry was built — so the failure is read
# off this run's own log and never off a file an earlier run left. A host
# that happens to have the headers builds the program whole. Status in
# $rc, log in $OUT.log.
host_c() {
  ( cd gtk && PATH="$BIN:$PATH" EMO_REGISTRY="$REG" "$EMO" build "$1" \
      --target c -o "$2" ) >"$OUT.log" 2>&1 && rc=0 || rc=$?
  if [ "$rc" != 0 ]; then
    rc=1
    if [ -f gtk/.emo-build/main.c ] && \
        grep -q "the C compiler failed" "$OUT.log"; then
      rc=0
    fi
  fi
}

# container_cc <program> — the container compiles the generated C with the
# backend's shim and links it into `.emo-build/check/gtk/<program>`. The
# registry is under the mounted directory, so the container reaches the
# shim by a path relative to it. Status in $rc, log in $OUT.log.
container_cc() {
  regrel=${REG#"$PWD/"}
  docker run --rm -v "$PWD:/work" -w /work "$IMAGE" sh -c "
    set -e
    cc -O2 -ffp-contract=off -std=c11 -Wall -Wno-deprecated-declarations \\
      -I gtk/.emo-build \$(pkg-config --cflags gtk4) \\
      gtk/.emo-build/main.c gtk/.emo-build/emo_c_runtime.c \\
      $regrel/emo/ui_gtk/0.1.0/shim.c \\
      \$(pkg-config --libs gtk4) -lm -o .emo-build/check/gtk/$1
  " >"$OUT.log" 2>&1 && rc=0 || rc=$?
}

# --- the registry: the core, every backend, and the application ----------
#
# The directory is named for the sources' content, so a run can never
# serve a module a package no longer has. The list is the calculator's
# reach — every family package an entry requires, each by the files its
# own gate stages.

FB=$ROOT/projects/emo-desktop/fb
sum=$(cat "$ROOT/scripts/stage-registry.sh" \
  "$UI/package.emo" "$UI/ui.emo" "$UI/debug.emo" \
  "$UI/tui/package.emo" "$UI/tui/ui_tui.emo" \
  "$UI/ssr/package.emo" "$UI/ssr/ui_ssr.emo" \
  "$UI/browser/package.emo" "$UI/browser/ui_browser.emo" "$UI/browser/css.emo" \
  "$UI/macos/package.emo" "$UI/macos/ui_macos.emo" "$UI/macos/box.emo" \
  "$UI/macos/shim.m" \
  "$UI/gtk/package.emo" "$UI/gtk/ui_gtk.emo" "$UI/gtk/box.emo" "$UI/gtk/shim.c" \
  "$FB/package.emo" "$FB/ui_fb.emo" "$FB/pointer.emo" "$FB/raster.emo" \
  "$FB/face_inter.emo" "$FB/face_mono.emo" \
  "$FB/canvas/package.emo" "$FB/canvas/ui_fb_canvas.emo" \
  "$FB/frame/package.emo" "$FB/frame/ui_fb_frame.emo" "$FB/frame/counter.emo" \
  | cksum | awk '{print $1}')
asum=$(cat package.emo main.emo number.emo | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum-$asum
"$STAGE" "$REG"

# --- the application ------------------------------------------------------
#
# `emo check` reads the whole package, the test included. The test raises
# on a failed assertion, so its exit status is the result and the `ok`
# lines are the count of what ran. The package is pure Emo with no
# `printf` and no `chars()`, so it lowers for `riscv64` too — the metal's
# target, where the desktop's own pass would run it.

EMO_REGISTRY="$REG" "$EMO" check main.emo >/dev/null 2>&1 && rc=0 || rc=$?
expect 0 "the application and its test type-check" "$rc"

EMO_REGISTRY="$REG" "$EMO" run test.emo >"$OUT.run" 2>&1 && rc=0 || rc=$?
expect 0 "the application's test runs to the end" "$rc"
n=$(grep -c '^ok ' "$OUT.run" || true)
expect 80 "all eighty assertions pass" "$n"

mkdir -p "$PWD/.emo-build/check/riscv64"
build . main.emo riscv64 "$PWD/.emo-build/check/riscv64/calc" && rc=0 || rc=$?
expect 0 "the application lowers for riscv64" "$rc"

# --- the hosted backends, the session stepped by the entry ----------------

hosted debug main expected.txt "headless calculator" ocaml c typescript wasm beam
hosted ssr main ssr/expected.txt "server-rendered calculator" \
  ocaml c typescript wasm beam
# The terminal backend declares four targets: `wasm` has no `printf`, so
# resolution refuses before any emitter runs.
hosted tui main tui/expected.txt "terminal calculator" \
  ocaml c typescript beam
# The framebuffer entry declares all five, but `beam` runs its own leg
# below.
hosted fb main fb/expected.txt "framebuffer calculator" \
  ocaml c typescript wasm

mkdir -p "$PWD/.emo-build/check/tui/wasm"
build tui main.emo wasm "$PWD/.emo-build/check/tui/wasm/out" && rc=0 || rc=$?
got=$(grep -o -m1 "does not declare the \`wasm\` target" "$OUT.log" \
  | head -1 || true)
expect "does not declare the \`wasm\` target" \
  "the terminal entry --target wasm says why" "$got"

# --- the framebuffer's beam leg: the page session ------------------------
#
# On `beam` a pixel store copies the canvas's whole `Bytes` — measured
# 2026-11-24: the same 46,080 stores take 2.0 s into a 368 KB canvas and
# 18.7 s into one ten times its size — so a frame of the calculator costs
# seconds there (8.2 s on a 384x240 canvas, against 0.03 s for its
# layout), and the window session's fifty-five frames would outlast any
# alarm. `page.emo` is the page session on the same canvas: seven frames,
# whose bytes are the first of `expected.txt`'s, the interpreter's and the
# target's alike.

FP=$PWD/.emo-build/check/fb-page
mkdir -p "$FP"
head -n $((PAGE_LINES * 2)) fb/expected.txt >"$W/page-frames.txt"
( cd fb && EMO_REGISTRY="$REG" "$EMO" run page.emo ) >"$FP/interp.txt" \
  2>"$FP/interp.err" && rc=0 || rc=$?
expect 0 "the framebuffer's page session runs on the interpreter" "$rc"
expect_same_file "$W/page-frames.txt" "$FP/interp.txt" \
  "and prints the framebuffer golden's first frames"
: >"$FP/beam.txt"
mkdir -p "$FP/beam"
build fb page.emo beam "$FP/beam/out" && rc=0 || rc=$?
expect 0 "the framebuffer's page session builds for beam" "$rc"
if [ "$rc" = 0 ]; then
  run_target beam "$FP/beam/out" "$FP/beam.txt"
else
  rc=99
fi
expect 0 "the framebuffer's page session exits 0 on beam" "$rc"
expect_same_file "$W/page-frames.txt" "$FP/beam.txt" \
  "and the framebuffer's bytes on beam are the interpreter's"

# --- the shorter sessions are the hosted session's first lines ------------
#
# The goldens the three printing backends are pinned to carry the trace
# beside their own frames; what they carry of it must be the head of
# `expected.txt`, or an entry is replaying another session.

head -n "$WINDOW_LINES" expected.txt >"$W/window.txt"
head -n "$PAGE_LINES" expected.txt >"$W/page.txt"
grep '^display ' tui/expected.txt | head -n "$WINDOW_LINES" >"$W/tui.trace"
expect_same_file "$W/window.txt" "$W/tui.trace" \
  "the terminal golden's trace is the window session's lines"
grep '^display ' fb/expected.txt | head -n "$WINDOW_LINES" >"$W/fb.trace"
expect_same_file "$W/window.txt" "$W/fb.trace" \
  "and the framebuffer golden's is"
grep '^display ' ssr/expected.txt | head -n "$PAGE_LINES" >"$W/ssr.trace"
expect_same_file "$W/page.txt" "$W/ssr.trace" \
  "and the server-rendered golden's is the page session's lines"

# The window session as the harnesses take it: one line of tags, read
# from the application rather than written down here.
( cd debug && EMO_REGISTRY="$REG" "$EMO" run script.emo ) >"$W/script.txt" \
  2>/dev/null

# --- the page -------------------------------------------------------------

if have_node; then
  BOUT=$PWD/.emo-build/check/browser
  mkdir -p "$BOUT"
  build browser main.emo browser "$BOUT/out" && rc=0 || rc=$?
  expect 0 "the calculator's page builds for browser" "$rc"

  # `session.emo` mounts and returns, as the application's entry does: a
  # page has no input source, so the stub page clicks the hosted
  # session's tags — each the element a key's tag rides and the listener
  # a person's click would call.
  : >"$BOUT/run.txt"
  build browser session.emo browser "$BOUT/session" && rc=0 || rc=$?
  expect 0 "the calculator's session builds for browser" "$rc"
  if [ "$rc" = 0 ] && [ -s "$W/script.txt" ]; then
    perl -e 'alarm 120; exec @ARGV' node "$PAGE" "$BOUT/session.js" \
      "$(cat "$W/script.txt")" >"$BOUT/run.txt" 2>"$BOUT/run.err" \
      && rc=0 || rc=$?
  else
    rc=99
  fi
  expect 0 "the calculator's page run exits 0" "$rc"
  expect_same_file expected.txt "$BOUT/run.txt" \
    "and clicked key by key, the page prints the hosted session's displays"
else
  printf 'skip the page: Node >= 22.13 is missing\n'
fi

# --- the macOS window -----------------------------------------------------

# `EMO_GUI_AUTOTEST` makes the shim click the tags in the script and then
# terminate, so the run needs no one at the keyboard and no screenshot;
# the alarm is a hung run's failure, not a wait forever (fifty-four tags,
# a click apart). `EMO_GUI_COUNT` names a file the shim writes the number
# of widgets it made into, as it leaves: the calculator's tree changes no
# node from one key to the next, so a window that keeps what the diff
# keeps makes the first frame's twenty — the display and nineteen keys —
# and not one more.

if [ "$(uname -s)" != Darwin ]; then
  printf 'skip the macOS window: not a Darwin host\n'
else
  MOUT=$PWD/.emo-build/check/macos
  mkdir -p "$MOUT"
  build macos main.emo c "$MOUT/calculator" && rc=0 || rc=$?
  expect 0 "the calculator a person clicks builds for c" "$rc"

  : >"$MOUT/run.txt"
  build macos session.emo c "$MOUT/session" && rc=0 || rc=$?
  expect 0 "the calculator's window session builds for c" "$rc"
  if [ "$rc" = 0 ]; then
    EMO_GUI_AUTOTEST=1 EMO_GUI_COUNT="$MOUT/count.txt" \
      perl -e 'alarm 60; exec @ARGV' "$MOUT/session" >"$MOUT/run.txt" \
      2>"$MOUT/run.err" && rc=0 || rc=$?
  else
    rc=99
  fi
  expect 0 "the calculator's window run exits 0" "$rc"
  expect_same_file "$W/window.txt" "$MOUT/run.txt" \
    "and the window prints the window session's displays"
  got=$(cat "$MOUT/count.txt" 2>/dev/null || true)
  expect "ui: made 20 widgets" \
    "and the window keeps its widgets across the window session" "$got"
fi

# --- the GTK 4 window -----------------------------------------------------

# GTK 4 is a Linux toolkit. On a host where `pkg-config gtk4` answers the
# gate builds and runs natively (under Xvfb when there is no display);
# elsewhere the host generates the C and the `emo-ui-gtk-build` container
# compiles and runs it, which is how a macOS host checks the window.

GTK_MODE=none
if have_gtk; then
  GTK_MODE=native
elif have_docker; then
  GTK_MODE=docker
else
  printf 'skip the GTK 4 window: no pkg-config gtk4 and no Docker\n'
fi

if [ "$GTK_MODE" != none ]; then
  GOUT=$PWD/.emo-build/check/gtk
  mkdir -p "$GOUT"
  : >"$GOUT/run.txt"
  if [ "$GTK_MODE" = native ]; then
    build gtk session.emo c "$GOUT/session" && rc=0 || rc=$?
    expect 0 "the calculator's window session builds for c with GTK 4" "$rc"
    if [ "$rc" = 0 ]; then
      DISPLAY_RUN=
      if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
        DISPLAY_RUN=xvfb-run
      fi
      # The gate's display is headless, so it stays off the GL path (no
      # DRI3) and off the accessibility bus (no session bus).
      GSK_RENDERER=cairo GTK_A11Y=none EGL_LOG_LEVEL=fatal EMO_GUI_AUTOTEST=1 \
        EMO_GUI_COUNT="$GOUT/count.txt" \
        perl -e 'alarm 60; exec @ARGV' ${DISPLAY_RUN:+"$DISPLAY_RUN" -a} \
        "$GOUT/session" >"$GOUT/run.txt" 2>"$GOUT/run.err" && rc=0 || rc=$?
    else
      rc=99
    fi
  else
    # The emo compiler is a host binary, so the host generates the C and
    # the container compiles it. `emo build` resolves the dependency's
    # `pkg_config` through the wrapper below and then fails at cc,
    # because the host has no GTK headers. That failure is expected; what
    # matters is that the C is there for the container.
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
      printf 'building the %s image (one-time, apt pulls GTK 4)...\n' "$IMAGE"
      docker build -t "$IMAGE" "$UI/gtk" || exit 1
    fi
    BIN=$PWD/.emo-build/check/bin
    mkdir -p "$BIN"
    printf '#!/bin/sh\nexec docker run --rm %s pkg-config "$@"\n' "$IMAGE" \
      >"$BIN/pkg-config"
    chmod +x "$BIN/pkg-config"

    host_c session.emo "$GOUT/session"
    expect 0 "the host generates the window session's C" "$rc"
    container_cc session
    expect 0 "the container compiles and links the window session" "$rc"
    if [ "$rc" = 0 ]; then
      docker run --rm -v "$PWD:/work" -w /work "$IMAGE" sh -c '
        GSK_RENDERER=cairo GTK_A11Y=none EGL_LOG_LEVEL=fatal \
          EMO_GUI_AUTOTEST=1 EMO_GUI_COUNT=.emo-build/check/gtk/count.txt \
          perl -e "alarm 60; exec @ARGV" xvfb-run -a \
          .emo-build/check/gtk/session > .emo-build/check/gtk/run.txt \
          2> .emo-build/check/gtk/run.err
      ' >"$OUT.log" 2>&1 && rc=0 || rc=$?
    else
      rc=99
    fi
  fi
  expect 0 "the calculator's GTK window run exits 0" "$rc"
  expect_same_file "$W/window.txt" "$GOUT/run.txt" \
    "and the GTK window prints the window session's displays"
  got=$(cat "$GOUT/count.txt" 2>/dev/null || true)
  expect "ui: made 20 widgets" \
    "and the GTK window keeps its widgets across the window session" "$got"

  # The entry a person clicks builds and links too.
  if [ "$GTK_MODE" = native ]; then
    build gtk main.emo c "$GOUT/calculator" && rc=0 || rc=$?
  else
    host_c main.emo "$GOUT/calculator"
    expect 0 "the host generates the application's C" "$rc"
    container_cc calculator
  fi
  expect 0 "the calculator a person clicks builds for c with GTK 4" "$rc"
fi

exit $fail
