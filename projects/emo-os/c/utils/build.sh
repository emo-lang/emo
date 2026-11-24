#!/usr/bin/env bash
# The core utilities' first corpus (T4.2): one static binary, applets
# by argv, through the musl sysroot's wrapper. The image lands in the
# boot tree's `uutils.elf` slot beside dash's.
set -euo pipefail
cd "$(dirname "$0")"
here=$PWD
sysroot="$here/../musl-port/sysroot/bin/riscv64-emoos-gcc"
if [ ! -x "$sysroot" ]; then
  echo "utils/build.sh: the sysroot is missing; build musl-port first" >&2
  exit 1
fi
"$sysroot" -Os -o "$here/../../uutils.elf" uutils.c
echo "built ../../uutils.elf through the sysroot"
