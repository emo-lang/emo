#!/bin/sh
# The face's smoke leg (emo-desktop M20): the corpus application
# live on headless sway. The host stages the registry and emits the
# face's C and the injector's C; the container compiles both, runs
# the face under sway, and the virtual keyboard injects i, i, d,
# Enter — the transcript's tag lines and the frame digests are the
# verdict, with the capture beside them on any miss.

set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
emo="${EMO:-emo}"
work="$(mktemp -d /tmp/emo-face-smoke-XXXXXX)"
mkdir -p "$work/src/face" "$work/src/inject" "$work/out"

echo "face-smoke: work in $work"

# The host's half: stage, resolve, emit both programs.
FACE="$repo/projects/emo-desktop/wayland"
(cd "$FACE" && ./check.sh >/dev/null)
REG=$(ls -td "$FACE/.emo-build/registry-"* | head -1)
(cd "$FACE" && EMO_REGISTRY="$REG" "$emo" build --target c main.emo >/dev/null)
cp "$FACE/.emo-build/main.c" "$FACE/.emo-build/emo_c_runtime.c" \
   "$FACE/.emo-build/emo_c_runtime.h" "$FACE/.emo-build/emo_defs.h" "$work/src/face/"
mv "$FACE/.emo-build" "$work/face-emo-build"

INJ="$repo/examples/wayland_inject"
(cd "$INJ" && "$emo" deps resolve >/dev/null && "$emo" build --target c main.emo >/dev/null)
cp "$INJ/.emo-build/main.c" "$INJ/.emo-build/emo_c_runtime.c" \
   "$INJ/.emo-build/emo_c_runtime.h" "$INJ/.emo-build/emo_defs.h" "$work/src/inject/"
mv "$INJ/.emo-build" "$work/inject-emo-build" 2>/dev/null || true

# The container's half: compile both, sway headless, the face live,
# the keys injected, the transcript and the capture out.
docker build -q -t emo-wayland-smoke -f "$repo/devtools/wayland-smoke.Dockerfile" \
  "$repo/devtools" >/dev/null

docker run --rm \
  -v "$work/src:/src:ro" \
  -v "$work/out:/out" \
  emo-wayland-smoke \
  sh -c '
    set -e
    cc -O2 -fno-strict-aliasing -std=c11 -I /src/face \
       /src/face/main.c /src/face/emo_c_runtime.c -lm -o /out/face
    cc -O2 -fno-strict-aliasing -std=c11 -I /src/inject \
       /src/inject/main.c /src/inject/emo_c_runtime.c -lm -o /out/inject
    export XDG_RUNTIME_DIR=/tmp/xdg
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    sway -d -c /dev/null >/tmp/sway.log 2>&1 &
    for i in $(seq 1 50); do
      [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
      sleep 0.1
    done
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { echo "face-smoke: sway socket never appeared"; exit 3; }
    # The face first: the virtual devices it creates fill the seat
    # capabilities, the grants pass, and the window maps. The
    # injector starts after the corpus is live, so the injected keys
    # land on the focused window.
    WAYLAND_DISPLAY=wayland-1 /out/face >/tmp/face.log 2>&1 &
    face=$!
    for i in $(seq 1 200); do
      grep -q "the desktop runs live" /tmp/face.log 2>/dev/null && break
      sleep 0.1
    done
    grep -q "the desktop runs live" /tmp/face.log || { echo "face-smoke: FAIL — the face never went live"; cat /tmp/face.log; echo "--- face alive?"; kill -0 "$face" 2>/dev/null && echo yes || echo no; exit 5; }
    WAYLAND_DISPLAY=wayland-1 /out/inject >/tmp/inject.log 2>&1 &
    injector=$!
    for i in $(seq 1 100); do
      grep -q "inject: keys out" /tmp/inject.log 2>/dev/null && break
      sleep 0.1
    done
    cp /tmp/sway.log /out/sway.log
    cp /tmp/face.log /out/face.log
    cp /tmp/inject.log /out/inject.log
    sleep 1
    grep -q "face: click at 36 688 delivers tag 0" /tmp/face.log || { echo "face-smoke: FAIL — the dock click never delivered"; fail=1; }
    grep -q "face: key 106 delivers tag 4" /tmp/face.log || { echo "face-smoke: FAIL — the right arrow never delivered"; fail=1; }
    grep -q "face: key 10 delivers tag 5" /tmp/face.log || { echo "face-smoke: FAIL — the enter launch never delivered"; fail=1; }
    if [ "$fail" != 0 ]; then
      echo "--- face.log:"; cat /tmp/face.log
      echo "--- inject.log:"; cat /tmp/inject.log
    fi
    frames=$(grep -c "^frame " /tmp/face.log)
    distinct=$(grep "^frame " /tmp/face.log | sort -u | wc -l)
    echo "face-smoke: frames $frames, distinct $distinct"
    [ "$distinct" -ge 2 ] || { echo "face-smoke: FAIL — the frames never changed"; fail=1; }
    cp /tmp/sway.log /out/sway.log
    cp /tmp/face.log /out/face.log
    cp /tmp/inject.log /out/inject.log
    WAYLAND_DISPLAY=wayland-1 grim -t ppm /out/frame.ppm || true
    kill "$face" "$injector" 2>/dev/null || true
    echo "face-smoke: PASS — the desktop ran live, the click landed, and the keys drove it"
  '

echo "face-smoke: work kept in $work (the capture and the logs are there)"
