#!/usr/bin/env bash
# dash on EmoOS (T4.1): the first real POSIX program. The pristine
# source is vendored at third_party/dash; this overlay builds it
# through the musl sysroot's wrapper, with the host's cc for the
# generators dash's make runs at build time. The image lands in the
# boot tree's `dash.elf` slot, beside emosh's.

set -euo pipefail
cd "$(dirname "$0")"

root=$(cd "$PWD/../../../.." && pwd)
src="$root/third_party/dash"
sysroot="$root/projects/emo-os/c/musl-port/sysroot"
cc=${EMO_CROSS_CC:-${EMO_CC:-riscv64-elf-gcc}}
if [ "$cc" = "$sysroot/bin/riscv64-emoos-gcc" ]; then
  cc=riscv64-elf-gcc
fi
build=$PWD/.build

if [ ! -x "$sysroot/bin/riscv64-emoos-gcc" ]; then
  echo "dash-port/build.sh: the sysroot is missing; build musl-port first" >&2
  exit 1
fi

mkdir -p "$build"
cd "$build"
if [ ! -f Makefile ]; then
  CC="$sysroot/bin/riscv64-emoos-gcc" CC_FOR_BUILD=cc \
    "$src/configure" --host=riscv64-emoos --build="$("$src/config.guess")"
fi
if [ -f src/main.o ]; then
  # The sysroot's libc.a is not a make prerequisite: touch one object
  # so the link runs again after a port change, without `-B` waking
  # the vendor's autotools rules.
  touch src/main.o
fi
make -j4
cp src/dash "$root/projects/emo-os/dash.elf"
echo "built ../../dash.elf from the vendored dash through the sysroot"
