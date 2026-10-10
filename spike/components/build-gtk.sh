#!/bin/sh
# The component spike, GTK side: generate the C on the host (no GTK
# needed there), compile and link in the container, run under Xvfb.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}

"$EMO" build app.emo -o ui-app || true
if [ ! -f .emo-build/emo_defs.h ]; then
  echo "build-gtk.sh: pass 1 failed before writing the runtime header" >&2
  exit 1
fi

exec docker run --rm -v "$PWD:/work" -w /work emo-gtk-build sh -c '
  set -e
  cc -O2 $(pkg-config --cflags gtk4) -I .emo-build -c shim_gtk.c -o shim_gtk.o
  cc -O2 .emo-build/main.c .emo-build/emo_c_runtime.c shim_gtk.o \
    -o ui-app-gtk $(pkg-config --cflags --libs gtk4)
  EMO_GUI_AUTOTEST=1 xvfb-run -a ./ui-app-gtk
'
