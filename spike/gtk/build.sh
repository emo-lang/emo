#!/bin/sh
# Build the GTK spike on a machine with GTK 4. The two-pass shape is
# the same as the macOS spike: pass 1 fails at link on purpose, it
# writes .emo-build/ (including emo_defs.h) for the shim to compile
# against; pass 2 links the shim and GTK.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
GTK_CFLAGS="$(pkg-config --cflags gtk4)"
GTK_LIBS="$(pkg-config --libs gtk4)"

"$EMO" build main.emo -o gtk-spike || true
if [ ! -f .emo-build/emo_defs.h ]; then
  echo "build.sh: pass 1 failed before writing the runtime header" >&2
  exit 1
fi
cc -O2 $GTK_CFLAGS -I .emo-build -c shim.c -o shim.o
"$EMO" build main.emo -o gtk-spike --cclib="$PWD/shim.o" --cclib="$GTK_LIBS"
