#!/bin/sh
# The face's gate (emo-desktop M20): the wayland demo rides the fb
# gate's staged-registry pattern — the emo-ui core and the fb
# packages staged from source beside the stdlib's wayland/net/os —
# and the demo builds on the c target.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

UI=$(cd ../../emo-ui && pwd)
FB=$(cd ../fb && pwd)
STDLIB=$(cd ../../../stdlib && pwd)

mkdir -p .emo-build
sum=$(cat "$UI/package.emo" "$UI/ui.emo" "$UI/debug.emo" \
  "$FB/package.emo" "$FB/ui_fb.emo" "$FB/pointer.emo" "$FB/raster.emo" \
  "$FB/face_inter.emo" "$FB/face_mono.emo" \
  "$FB/canvas/package.emo" "$FB/canvas/ui_fb_canvas.emo" \
  "$FB/frame/package.emo" "$FB/frame/ui_fb_frame.emo" "$FB/frame/counter.emo" \
  "$FB/desktop/package.emo" "$FB/desktop/emo_desktop.emo" \
  package.emo main.emo \
  "$STDLIB/registry/wayland/0.1.0/package.emo" "$STDLIB/registry/wayland/0.1.0/wayland.emo" \
  "$STDLIB/registry/net/0.1.0/package.emo" "$STDLIB/registry/net/0.1.0/net.emo" \
  "$STDLIB/registry/os/0.1.0/package.emo" "$STDLIB/registry/os/0.1.0/os.emo" \
  | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum
mkdir -p "$REG/emo/ui/0.1.0" "$REG/emo/ui_fb/0.1.0" \
  "$REG/emo/ui_fb_canvas/0.1.0" "$REG/emo/ui_fb_frame/0.1.0" "$REG/emo_desktop/0.1.0"
cp "$UI/package.emo" "$UI/ui.emo" "$UI/debug.emo" "$REG/emo/ui/0.1.0/"
cp "$FB/package.emo" "$FB/ui_fb.emo" "$FB/pointer.emo" "$FB/raster.emo" \
  "$FB/face_inter.emo" "$FB/face_mono.emo" "$REG/emo/ui_fb/0.1.0/"
cp "$FB/canvas/package.emo" "$FB/canvas/ui_fb_canvas.emo" "$REG/emo/ui_fb_canvas/0.1.0/"
cp "$FB/frame/package.emo" "$FB/frame/ui_fb_frame.emo" "$FB/frame/counter.emo" "$REG/emo/ui_fb_frame/0.1.0/"
mkdir -p "$REG/emo_desktop/0.1.0"
cp "$FB/desktop/package.emo" "$FB/desktop/emo_desktop.emo" "$REG/emo_desktop/0.1.0/"
mkdir -p "$REG/wayland/0.1.0" "$REG/net/0.1.0" "$REG/os/0.1.0"
cp "$STDLIB/registry/wayland/0.1.0/package.emo" "$STDLIB/registry/wayland/0.1.0/wayland.emo" "$REG/wayland/0.1.0/"
cp "$STDLIB/registry/net/0.1.0/package.emo" "$STDLIB/registry/net/0.1.0/net.emo" "$REG/net/0.1.0/"
cp "$STDLIB/registry/os/0.1.0/package.emo" "$STDLIB/registry/os/0.1.0/os.emo" "$REG/os/0.1.0/"

# The stdlib's wayland/net/os resolve from the bundled registry; the
# scoped emo/ui* names resolve from the staged one. The lock rides
# beside the manifest.
EMO_REGISTRY="$REG" "$EMO" deps resolve >/dev/null
EMO_REGISTRY="$REG" "$EMO" check main.emo
echo "the face type-checks"
