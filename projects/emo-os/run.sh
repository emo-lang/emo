#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

elf='main.elf'

if [ ! -f "$elf" ]; then
  echo "run.sh: $elf not found; run: emo build main.emo --target riscv64" >&2
  exit 1
fi

# One boot: the named CPU config, the serial input on a named pipe
# written only after the kernel is up (OpenSBI's boot takes the UART
# first, so anything written before the payload polls is gone), the
# -d int trace in the log for the ecall count. The assertions: the
# greeting, the tick proof's checksum and three verdicts, the echoed
# line, and the machine's own exit — the SBI poweroff.
boot() {
  local cpu="$1" mode="$2" log="$3"
  local fifo
  fifo=$(mktemp -u /tmp/emoos-serial.XXXXXX)
  mkfifo "$fifo"

  : > "$log"
  qemu-system-riscv64 -machine virt -nographic -d int -cpu "$cpu" \
    -kernel "$elf" <"$fifo" >"$log" 2>&1 &
  local qemu_pid=$!
  exec 3>"$fifo"

  local found=0
  for _ in $(seq 1 100); do
    if grep -qF -- 'Hello, EmoOS!' "$log" 2>/dev/null; then
      found=1
      break
    fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 0.1
  done

  if [ "$found" -eq 1 ]; then
    printf 'hi\n' >&3
  fi

  local exited=0
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
    echo "run.sh: expected 'Hello, EmoOS!' in the serial output" >&2
    exit 1
  fi
  if ! grep -qF '4999999950000000' "$log"; then
    echo "run.sh: the tick proof's checksum is wrong; a trap bent a register" >&2
    exit 1
  fi
  if [ "$(grep -c 'true' "$log" || true)" -lt 3 ]; then
    echo "run.sh: the tick proof's verdicts are missing; the tick is not running" >&2
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

  local ecalls
  ecalls=$(grep -c 'supervisor_ecall' "$log" || true)
  if [ "$mode" = legacy ]; then
    # The SBI set_timer fallback: one ecall per re-arm, one for the
    # poweroff — many, and every one of them the tick working.
    if [ "$ecalls" -le 1 ]; then
      echo "run.sh: expected the SBI set_timer rearms, saw $ecalls ecalls" >&2
      exit 1
    fi
  else
    # The sstc transport: stimecmp writes need no ecall; the boot's
    # only one is the poweroff.
    if [ "$ecalls" -ne 1 ]; then
      echo "run.sh: expected exactly 1 ecall (the SBI poweroff), saw $ecalls" >&2
      exit 1
    fi
  fi
}

# The SBI fallback drives the tick when the CPU has no Sstc to delegate.
boot 'rv64,sstc=false' legacy '.qemu.log'
echo "run.sh: legacy SBI set_timer ticks: greeting, proof, echo, self-exit"
# The stimecmp transport when it does.
boot 'rv64,sstc=true' sstc '.qemu-sstc.log'
echo "run.sh: sstc stimecmp ticks: greeting, proof, echo, self-exit, 1 ecall"
