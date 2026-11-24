#!/usr/bin/env bash
# The build-system probe (T4.3): one program through make, pkg-config
# and CMake. The dash tarball's own configure/make is the real-world
# leg; this pins the handles a Linux tarball's build files reach for.
set -euo pipefail
cd "$(dirname "$0")"
here=$PWD
sysroot=$here/../musl-port/sysroot
cc=$sysroot/bin/riscv64-emoos-gcc
out=$(mktemp -d "${TMPDIR:-/tmp}/emoos-build-probe.XXXXXX")

make -C "$here" CC="$cc" OUT="$out/probe-make.elf" >/dev/null
echo "make: probe-make.elf"

export PKG_CONFIG_PATH="$sysroot/lib/pkgconfig"
if ! pkg-config --exists emoos; then
  echo "pkg-config: emoos.pc not found" >&2
  exit 1
fi
cflags=$(pkg-config --cflags emoos)
libs=$(pkg-config --libs emoos)
# shellcheck disable=SC2086
"$cc" -Os $cflags -o "$out/probe-pc.elf" main.c $libs
echo "pkg-config: probe-pc.elf ($(pkg-config --modversion emoos))"

if command -v cmake >/dev/null 2>&1; then
  cmake -S "$here" -B "$out/cmake" \
    -DCMAKE_TOOLCHAIN_FILE="$sysroot/riscv64-emoos.cmake" >/dev/null
  cmake --build "$out/cmake" >/dev/null
  cp "$out/cmake/probe" "$out/probe-cmake.elf"
  echo "cmake: probe-cmake.elf"
else
  echo "cmake: skipped (not on this host; the toolchain file ships in the sysroot)"
fi

for f in "$out"/probe-*.elf; do
  [ -f "$f" ] || continue
  file "$f" | grep -q "RISC-V" || { echo "not a RISC-V ELF: $f" >&2; exit 1; }
done
echo "build systems ok"
