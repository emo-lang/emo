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

emos_cc=${EMO_CC:-riscv64-elf-gcc}
if ! command -v "$emos_cc" >/dev/null 2>&1; then
  echo "c/build.sh: $emos_cc not found (macOS: brew install riscv64-elf-gcc)" >&2
  exit 1
fi

"$emos_cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-pic \
  -fno-stack-protector -nostdlib -Wl,--build-id=none \
  -T chello.ld -o ../chello.elf crt0.s fork.s hello.c emo_posix.c \
  emo_syscall.c

echo "built ../chello.elf"
