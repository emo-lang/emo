#!/usr/bin/env bash
# TCC on EmoOS (T4.5): the self-hosted C compiler. The pristine source
# is vendored at third_party/tcc (the `mob` branch, 0.9.28rc — its
# riscv64 backend); this overlay builds it through the musl sysroot's
# wrapper, with the host's cc for the generators. The image and the
# link inputs land in the boot tree: `tcc.elf`, `tcc-libtcc1.a`,
# `tcc-crt0.o`, `tcc-libc.a`, and the acceptance source `tcc-test.c`.
# The guest links with TCC's own linker: `-nostdlib -static` plus these
# inputs, at the image window's base.

set -euo pipefail
cd "$(dirname "$0")"

here=$PWD
root=$(cd "$PWD/../../../.." && pwd)
src="$root/third_party/tcc"
sysroot="$root/projects/emo-os/c/musl-port/sysroot"
boot="$root/projects/emo-os"
cc=${EMO_CROSS_CC:-${EMO_CC:-riscv64-elf-gcc}}
if [ "$cc" = "$sysroot/bin/riscv64-emoos-gcc" ]; then
  cc=riscv64-elf-gcc
fi
ar=${EMO_AR:-riscv64-elf-ar}
# TCC's build writes its objects and its test corpus into the source
# directory; the copy lives outside projects/emo-os, where the Emo
# kernel build would otherwise assemble every vendored `.S` test.
build=${TMPDIR:-/tmp}/emoos-tcc-port

if [ ! -x "$sysroot/bin/riscv64-emoos-gcc" ]; then
  echo "tcc-port/build.sh: the sysroot is missing; build musl-port first" >&2
  exit 1
fi
if ! command -v "$cc" >/dev/null 2>&1; then
  echo "tcc-port/build.sh: $cc not found (macOS: brew install riscv64-elf-gcc)" >&2
  exit 1
fi
if ! command -v "$ar" >/dev/null 2>&1; then
  echo "tcc-port/build.sh: $ar not found" >&2
  exit 1
fi

mkdir -p "$build"
cp -R "$src/." "$build/"
cd "$build"

# The host builds the target compiler: the riscv64 backend with the
# sysroot's headers and the wrapper's flags. Bounds checking and
# backtraces stay off — the image's statically linked body does not
# carry their probes, and the acceptance's link is the plain one.
./configure --cpu=riscv64 --targetos=Linux \
  --cc="$sysroot/bin/riscv64-emoos-gcc" --prefix=/usr \
  --extra-cflags="-Os" --config-bcheck=no --config-backtrace=no

# c2str is the build's own generator, not the target's: the host cc
# builds it, the target make reads its output.
cc -DC2STR conftest.c -o c2str.exe

make T=riscv64 AR="$ar" tcc -j4

# TCC's runtime helpers, compiled by the wrapper (the target tcc cannot
# run on the host); `__riscv64_clear_cache` is TCC's builtin, mapped to
# the compiler's own for this one host-side build.
make -C lib T=riscv64 riscv64-libtcc1-usegcc=yes \
  CC="$sysroot/bin/riscv64-emoos-gcc" AR="$ar" \
  CFLAGS="-D__riscv64_clear_cache=__builtin___clear_cache"

cp tcc "$boot/tcc.elf"
cp libtcc1.a "$boot/tcc-libtcc1.a"
"$sysroot/bin/riscv64-emoos-gcc" -c "$here/crt0.s" -o "$boot/tcc-crt0.o"

# The guest link's library is the machine's own C door runtime, not the
# 502 KB musl archive: TCC's compiler process holds the archive whole,
# and the musl body's peak crosses its arena. The T1 fd layer plus the
# gate (and the two musl-crt hooks the crt names) is the small, honest
# bootstrap target; the musl archive waits for the arena's later rung.
t1="$root/projects/emo-os/c"
"$cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-pic \
  -fno-stack-protector -I "$t1" \
  -c "$t1/emo_posix.c" -o "$build/tcc-t1-posix.o"
"$cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-pic \
  -fno-stack-protector -I "$t1" \
  -c "$t1/emo_syscall.c" -o "$build/tcc-t1-syscall.o"
"$cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-pic \
  -fno-stack-protector -I "$t1" \
  -c "$here/mini.c" -o "$build/tcc-t1-mini.o"
libc_ar="$build/tcc-libc-$$.a"
"$ar" rcs "$libc_ar" "$build/tcc-t1-posix.o" \
  "$build/tcc-t1-syscall.o" "$build/tcc-t1-mini.o"
cp "$libc_ar" "$boot/tcc-libc.a"

cp "$here/tcc-test.c" "$boot/tcc-test.c"

echo "built ../../tcc.elf and the guest link inputs through the sysroot"
