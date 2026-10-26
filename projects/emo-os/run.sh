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

# The serial input rides a named pipe, written only after the kernel is
# up: OpenSBI's boot takes the UART away first, and anything written
# before the payload polls is gone. The write end stays open on fd 3
# so the machine never sees an early EOF.
fifo=$(mktemp -u /tmp/emoos-serial.XXXXXX)
mkfifo "$fifo"

: > "$log"
qemu-system-riscv64 -machine virt -nographic -d int -kernel "$elf" \
  <"$fifo" >"$log" 2>&1 &
qemu_pid=$!
exec 3>"$fifo"

found=0
for _ in $(seq 1 100); do
  if grep -qF -- "$expected" "$log" 2>/dev/null; then
    found=1
    break
  fi
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 0.1
done

if [ "$found" -eq 1 ]; then
  printf 'hi\n' >&3
fi

# The proof that SBI still owns poweroff: after the echo, the machine
# shuts itself down — QEMU exits on its own.
exited=0
for _ in $(seq 1 50); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    exited=1
    break
  fi
  sleep 0.1
done

if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid" 2>/dev/null || true
fi
wait "$qemu_pid" 2>/dev/null || true
exec 3>&-

cat "$log"

if [ "$found" -ne 1 ]; then
  echo "run.sh: expected '$expected' in the serial output" >&2
  exit 1
fi

if ! grep -qF 'hi' "$log"; then
  echo "run.sh: the echo line never came back; the UART's read lane is dead" >&2
  exit 1
fi

if [ "$exited" -ne 1 ]; then
  echo "run.sh: QEMU did not exit on its own; the SBI poweroff is gone" >&2
  exit 1
fi

# One ecall for the whole boot — the poweroff. Every console byte now
# rides the 16550A driver, so the SBI putchar ecall is gone from the
# output path; the -d int trace counts what remains.
ecalls=$(grep -c 'supervisor_ecall' "$log" || true)
if [ "$ecalls" -ne 1 ]; then
  echo "run.sh: expected exactly 1 ecall (the SBI poweroff), saw $ecalls" >&2
  exit 1
fi

echo "run.sh: saw '$expected', the echo 'hi', one ecall (poweroff); QEMU exited"
