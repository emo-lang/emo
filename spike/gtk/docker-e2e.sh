#!/bin/sh
# End-to-end from a machine without GTK: generate the C on the host
# (the Emo compiler), then compile, link, and run inside the
# emo-gtk-build container — GTK 4 plus Xvfb, so the app runs with a
# real (virtual) display and the autotest clicks a real button.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}

# Pass 1 on the host: write .emo-build/ (main.c, runtime, emo_defs.h);
# linking fails here because the host has no GTK — that is expected.
"$EMO" build main.emo -o gtk-spike || true
if [ ! -f .emo-build/emo_defs.h ]; then
  echo "docker-e2e.sh: pass 1 failed before writing the runtime header" >&2
  exit 1
fi

if ! docker image inspect emo-gtk-build >/dev/null 2>&1; then
  echo "building the emo-gtk-build image (one-time, apt pulls GTK dev)..."
  docker build -t emo-gtk-build .
fi

# Inside the container: compile the shim, link everything, and run
# under Xvfb with the autotest armed.
exec docker run --rm -v "$PWD:/work" -w /work emo-gtk-build sh -c '
  set -e
  cc -O2 $(pkg-config --cflags gtk4) -I .emo-build -c shim.c -o shim.o
  cc -O2 .emo-build/main.c .emo-build/emo_c_runtime.c shim.o \
    -o gtk-spike $(pkg-config --cflags --libs gtk4)
  echo "linked $(ls -la gtk-spike | awk \"{print \\\$5}\") bytes"
  EMO_GUI_AUTOTEST=1 xvfb-run -a ./gtk-spike
'
