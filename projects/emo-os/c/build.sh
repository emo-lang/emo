#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# The musl body's proof image (T2.2): the same `chello.elf` slot, the
# port's crt and body instead of the C door's test. The default build
# stays the T1 program; the tracker's metal beat sets EMO_MUSL=1.
if [ "${EMO_MUSL:-0}" = 1 ]; then
  here=$PWD
  bash "$here/musl-port/build.sh"
  cp "$here/../muslhello.elf" "$here/../chello.elf"
  exit 0
fi

# The underlying cross compiler, read before EMO_CC becomes the sysroot
# wrapper: in one command's assignments bash applies them left to right,
# so a later `${EMO_CC}` would see the wrapper and exec itself forever.
emos_cc=${EMO_CROSS_CC:-${EMO_CC:-riscv64-elf-gcc}}
if [ "$emos_cc" = "$PWD/musl-port/sysroot/bin/riscv64-emoos-gcc" ]; then
  emos_cc=riscv64-elf-gcc
fi
if ! command -v "$emos_cc" >/dev/null 2>&1; then
  echo "c/build.sh: $emos_cc not found (macOS: brew install riscv64-elf-gcc)" >&2
  exit 1
fi

# The emosh boot shell (T3.2): the Emo shell's C build through the
# sysroot, installed by the boot's first-run image.
if [ "${EMO_SHELL:-0}" = 1 ]; then
  here=$PWD
  root=$(cd "$here/../../.." && pwd)
  sysroot="$here/musl-port/sysroot/bin/riscv64-emoos-gcc"
  emo="$root/_build/default/src/emo_cli/emo.exe"
  if [ ! -x "$emo" ]; then
    echo "c/build.sh: the Emo compiler is missing: $emo" >&2
    exit 1
  fi
  (cd "$root/projects/emo-shell" && \
    EMO_CC="$sysroot" EMO_CROSS_CC="$emos_cc" \
    "$emo" build main.emo --target c -o "$here/../emosh.elf")
else
  # The kernel's user.S embeds emosh.elf whatever the boot; a build
  # without the shell writes the empty placeholder and the kernel skips
  # its install, so the golden keeps the Emo desktop.
  : > "$PWD/../emosh.elf"
fi

# The C door's test image is built whatever the boot: the first-run
# volume installs it like every app, and T3.4 drives its argv/envp
# probe from the launcher and the shell.
"$emos_cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-pic \
  -fno-stack-protector -nostdlib -Wl,--build-id=none \
  -T chello.ld -o ../chello.elf crt0.s fork.s hello.c emo_posix.c \
  emo_syscall.c

echo "built ../chello.elf"
