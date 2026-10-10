#!/bin/sh
# The component spike, macOS side: two-pass build, the shim links
# against AppKit on this machine.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}

"$EMO" build app.emo -o ui-app || true
if [ ! -f .emo-build/emo_defs.h ]; then
  echo "build-mac.sh: pass 1 failed before writing the runtime header" >&2
  exit 1
fi
cc -O2 -fobjc-arc -Wno-deprecated-declarations -I .emo-build \
  -c shim_mac.m -o shim_mac.o
"$EMO" build app.emo -o ui-app --cclib="$PWD/shim_mac.o" \
  --cclib="-framework AppKit"
