#!/usr/bin/env bash
# The conformance probe (EmoOS plan B, T2.4): the same C suite on the
# host's C library and on EmoOS. The host leg is the host compiler's
# libc (the C reference here; the Emo interpreter is not a C runtime);
# the metal leg boots the proof image through the sysroot's wrapper and
# reads the same markers. The outputs diff byte for byte.

set -euo pipefail
cd "$(dirname "$0")"

build=$PWD/.build
mkdir -p "$build"

host_cc=${HOST_CC:-cc}
"$host_cc" -O2 -D_GNU_SOURCE -o "$build/conformance-host" conformance.c
"$build/conformance-host" > "$build/conformance-host.txt"

{
  sleep 45
  printf 'desktop\n'
  sleep 8
  printf 'exec chello.elf\n'
  sleep 20
  printf 'poweroff\n'
  sleep 10
} | env EMO_MUSL=1 EMO_PROG=conformance.c bash ../../start.sh --fresh \
  > "$build/conformance-metal.log" 2>&1

tr -d '\r' < "$build/conformance-metal.log" \
  | sed -e 's/emo-os> //g' \
  | sed -n '/conformance start/,/conformance end/p' \
  > "$build/conformance-metal.txt"

diff -u "$build/conformance-host.txt" "$build/conformance-metal.txt"
echo "conformance: host and metal agree"

(cd .. && env -u EMO_MUSL -u EMO_PROG bash build.sh) >/dev/null
