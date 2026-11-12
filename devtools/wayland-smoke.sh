#!/bin/sh
# The wayland smoke leg: the host emits the paint demo's C, the
# container compiles it and runs it under headless sway, grim
# captures the screen, and the capture's pixels answer whether the
# frame arrived — the top half red, the bottom half blue.
#
# The compiler on the host is $EMO (default: emo on the PATH). The
# Dockerfile builds the image on first use. The leg exits nonzero
# with the capture kept beside the work files on any miss.

set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
emo="${EMO:-emo}"
work="$(mktemp -d /tmp/emo-wayland-smoke-XXXXXX)"
mkdir -p "$work/src" "$work/out"

echo "smoke: work in $work"

# The host's half: emit the demo's C.
cd "$repo/examples/wayland_paint"
"$emo" build --target c main.emo
cp .emo-build/main.c .emo-build/emo_c_runtime.c .emo-build/emo_c_runtime.h \
   .emo-build/emo_defs.h "$work/src/"
if [ -d .emo-build ]; then
  mv .emo-build "$work/paint-emo-build"
fi

# The container's half: compile, sway headless, the client, grim.
docker build -q -t emo-wayland-smoke -f "$repo/devtools/wayland-smoke.Dockerfile" \
  "$repo/devtools" >/dev/null

docker run --rm \
  -v "$work/src:/src:ro" \
  -v "$work/out:/out" \
  emo-wayland-smoke \
  sh -c '
    set -e
    cc -O2 -fno-strict-aliasing -std=c11 -I /src \
       /src/main.c /src/emo_c_runtime.c -lm -o /out/paint
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    sway -c /dev/null >/tmp/sway.log 2>&1 &
    for i in $(seq 1 50); do
      [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
      sleep 0.1
    done
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { echo "smoke: sway socket never appeared"; cat /tmp/sway.log; exit 3; }
    WAYLAND_DISPLAY=wayland-1 /out/paint >/tmp/paint.log 2>&1 &
    client=$!
    for i in $(seq 1 100); do
      grep -q "commit ok" /tmp/paint.log 2>/dev/null && break
      sleep 0.1
    done
    grep -q "commit ok" /tmp/paint.log || { echo "smoke: the client never committed"; cat /tmp/paint.log /tmp/sway.log; exit 4; }
    sleep 1
    WAYLAND_DISPLAY=wayland-1 grim -t ppm /out/frame.ppm
    cp /tmp/paint.log /out/paint.log
    cp /tmp/sway.log /out/sway.log
    kill "$client" 2>/dev/null || true
    echo "smoke: capture kept at /out/frame.ppm"
  '

# The pixels' verdict: red ff0000, blue 0000ff, counted from the PPM.
hexs="$(od -v -An -tx1 "$work/out/frame.ppm" | tr -d ' \n')"
red="$(printf '%s' "$hexs" | grep -o 'ff0000' | wc -l | tr -d ' ')"
blue="$(printf '%s' "$hexs" | grep -o '0000ff' | wc -l | tr -d ' ')"
echo "smoke: red pixels ~$red, blue pixels ~$blue"

fail=0
if [ "$red" -lt 1000 ]; then echo "smoke: FAIL — the red half never arrived"; fail=1; fi
if [ "$blue" -lt 1000 ]; then echo "smoke: FAIL — the blue half never arrived"; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "smoke: PASS — the first frame is on a real compositor"
else
  echo "smoke: work kept in $work (the capture and the logs are there)"
  exit 1
fi
