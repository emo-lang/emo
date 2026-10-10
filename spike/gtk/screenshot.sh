#!/bin/sh
# Capture a PNG of the GTK window under Xvfb inside the container.
# Xvfb has no window manager, so GTK may map the window partly off
# screen — capture the application window by id instead of the root.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}

[ -f .emo-build/emo_defs.h ] || { "$EMO" build main.emo -o gtk-spike || true; }

docker run --rm -v "$PWD:/work" -w /work emo-gtk-build sh -c '
  set -e
  command -v xwininfo >/dev/null || {
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq x11-utils >/dev/null 2>&1
  }
  cc -O2 $(pkg-config --cflags gtk4) -I .emo-build -c shim.c -o shim.o
  cc -O2 .emo-build/main.c .emo-build/emo_c_runtime.c shim.o \
    -o gtk-spike $(pkg-config --cflags --libs gtk4)
  Xvfb :99 -screen 0 800x600x24 &
  XVFB_PID=$!
  sleep 1
  DISPLAY=:99 ./gtk-spike &
  APP_PID=$!
  sleep 3
  WID=$(DISPLAY=:99 xwininfo -root -tree \
        | grep "My Language GTK4 Spike" | head -1 | grep -o "0x[0-9a-f]*" | head -1)
  DISPLAY=:99 xwd -id "$WID" -silent \
    | xwdtopnm 2>/dev/null | pnmtopng > gtk-window.png
  kill $APP_PID $XVFB_PID 2>/dev/null || true
  echo "captured gtk-window.png (window $WID)"
'
