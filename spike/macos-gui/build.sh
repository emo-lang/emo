#!/bin/sh
# Two-pass build. Pass 1 fails at link on purpose: emo build writes
# .emo-build/emo_c_runtime.h before it invokes cc, and cc stops on the
# undefined gui_* symbols. shim.m compiles against that header, and
# pass 2 links everything together.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}

"$EMO" build main.emo -o gui-spike || true
if [ ! -f .emo-build/emo_c_runtime.h ]; then
  echo "build.sh: pass 1 failed before writing the runtime header" >&2
  exit 1
fi
cc -O2 -fobjc-arc -Wno-deprecated-declarations -I .emo-build -c shim.m -o shim.o
"$EMO" build main.emo -o gui-spike --cclib="$PWD/shim.o" --cclib="-framework AppKit"
