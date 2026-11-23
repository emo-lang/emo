#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

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
