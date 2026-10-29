#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

elf='main.elf'

if [ ! -f "$elf" ]; then
  echo "run.sh: $elf not found; build both images first:" >&2
  echo "  (cd hello && emo build main.emo --target riscv64 --profile user -o ../hello.elf)" >&2
  echo "  emo build main.emo --target riscv64" >&2
  exit 1
fi

# One boot: the named CPU config, the serial input on a named pipe
# written only after the kernel is ready — the tick proof's checksum is
# the gate, so the reader's request beats the input and the console
# sleeps in its device-wait before a byte exists — and the -d int
# trace on its own stream (the guest's console bytes are written one
# by one, and a dump woven between them would split the lines the
# assertions read; on stderr the trace never touches the serial). The
# assertions: the greeting, the Sv39 line (the kernel paged on the
# table it built), the checksum, the tick verdict, the five console
# deliveries in order, the user program's proof chain — the kill report
# included, the machine surviving its offender — the frame allocator's
# account as the last line, and the machine's own exit, the SBI
# poweroff.
boot() {
  local cpu="$1" mode="$2" log="$3"
  local fifo
  fifo=$(mktemp -u /tmp/emoos-serial.XXXXXX)
  mkfifo "$fifo"

  : > "$log"
  : > "$log.trace"
  qemu-system-riscv64 -machine virt -nographic -d int -cpu "$cpu" \
    -kernel "$elf" <"$fifo" >"$log" 2>"$log.trace" &
  local qemu_pid=$!
  exec 3>"$fifo"

  local found=0
  for _ in $(seq 1 200); do
    if grep -qF -- '4999999950000000' "$log" 2>/dev/null; then
      found=1
      break
    fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 0.1
  done

  if [ "$found" -eq 1 ]; then
    printf 'abcde' >&3
  fi

  # The user program's read blocks on the console until a byte exists:
  # feed one once its gate line is on the wire, then wait for the rest
  # of the proof chain.
  for _ in $(seq 1 100); do
    if grep -qF 'gate 500500 r3 r2' "$log" 2>/dev/null; then
      break
    fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 0.1
  done
  printf 'X' >&3

  local exited=0
  for _ in $(seq 1 150); do
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
    echo "run.sh: the tick proof's checksum never came" >&2
    exit 1
  fi
  if ! grep -qF -- 'Hello, EmoOS!' "$log"; then
    echo "run.sh: expected 'Hello, EmoOS!' in the serial output" >&2
    exit 1
  fi
  if [ "$(grep -c 'true' "$log" || true)" -lt 1 ]; then
    echo "run.sh: the tick verdict is missing; the tick is not running" >&2
    exit 1
  fi
  # The Sv39 line first (T6.1): mode 8 and the root the kernel built,
  # printed by the program after it compared the live satp against its
  # own table — the kernel is linked in the high half, so nothing after
  # the stub's first instructions could even run untranslated; the line
  # says the table running is the Emo-built one, not the stub's. Then
  # the five console deliveries, in request order, then the user
  # image's proof chain: staged, the U-mode greeting, the gate line,
  # the byte the read waited for, the misbehaving child's line, the
  # supervisor's kill report (the faulting load is the one the
  # hardware refuses, so the cause is the access fault — the epc
  # moves per build and is not asserted), then the runaway's line and
  # its allocator's exhaustion report (T5.1: the pass's own 64 KiB
  # arena, announced through the gate, the pid the spawn order
  # fixes), then the good child's line and the spawn/wait round trip
  # answering after both deaths: the machine survived its offenders.
  # Last, the frame allocator's account at the root's exit (T5.3):
  # thirteen blocks taken — the kernel's page tables' block (T6.1), the
  # six green spawns' arenas, then a stack and an arena for each of the
  # three user passes — and ten given back — the four readers' arenas
  # at their deaths, both blocks of each user pass at its kill or exit;
  # the two services and the page tables keep theirs. The byte offsets
  # are the serial order.
  local prev=0 pos line
  for line in 'sv39 8 0x8' '0:97' '1:98' '2:99' '3:100' '4:101' 'user: staged' 'U-MODE 500500' 'gate 500500 r3 r2' 'echo 88' 'doomed' 'user fault 8 cause 5' 'greedy' 'user heap 9 gone' 'born' 'wait 7' 'frames 13 10'; do
    pos=$(grep -aboF -- "$line" "$log" | head -1 | cut -d: -f1 || true)
    if [ -z "$pos" ]; then
      echo "run.sh: the console never delivered '$line'; a reader's byte is lost" >&2
      exit 1
    fi
    if [ "$pos" -lt "$prev" ]; then
      echo "run.sh: '$line' arrived out of order" >&2
      exit 1
    fi
    prev=$pos
  done
  if [ "$exited" -ne 1 ]; then
    echo "run.sh: QEMU did not exit on its own; the SBI poweroff is gone" >&2
    exit 1
  fi

  local ecalls
  ecalls=$(grep -c 'supervisor_ecall' "$log.trace" || true)
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
echo "run.sh: legacy SBI set_timer ticks: greeting, sv39, proof, console, user, kill, frames, self-exit"
# The stimecmp transport when it does.
boot 'rv64,sstc=true' sstc '.qemu-sstc.log'
echo "run.sh: sstc stimecmp ticks: greeting, sv39, proof, console, user, kill, frames, self-exit, 1 ecall"
