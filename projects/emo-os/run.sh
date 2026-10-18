#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

expected='Hello, EmoOS!'
elf='main.elf'
log='.qemu.log'

if [ ! -f "$elf" ]; then
  echo "run.sh: $elf not found; run: emo build main.emo --target riscv64" >&2
  exit 1
fi

: > "$log"
qemu-system-riscv64 -machine virt -nographic -kernel "$elf" </dev/null >"$log" 2>&1 &
qemu_pid=$!

found=0
for _ in $(seq 1 100); do
  if grep -qF -- "$expected" "$log" 2>/dev/null; then
    found=1
    break
  fi
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 0.1
done

if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid" 2>/dev/null || true
fi
wait "$qemu_pid" 2>/dev/null || true

cat "$log"

if [ "$found" -ne 1 ]; then
  echo "run.sh: expected '$expected' in the serial output" >&2
  exit 1
fi

echo "run.sh: saw '$expected'; QEMU exited"
