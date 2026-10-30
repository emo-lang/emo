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

# The block device's backing (T7.1): a raw 1 MiB image, written zero
# before the first boot (T7.2) — so the two boots below are one story:
# the first finds a blank disk and the filesystem formats it, the
# second finds the volume the first left and mounts it. A dirty image
# from an earlier run changes nothing.
img='.blk.img'
dd if=/dev/zero of="$img" bs=1048576 count=1 status=none

# One boot: the named CPU config, the serial input on a named pipe
# written only after the kernel is ready — the tick proof's checksum is
# the gate, so the reader's request beats the input and the console
# sleeps in its device-wait before a byte exists — and the -d int
# trace on its own stream (the guest's console bytes are written one
# by one, and a dump woven between them would split the lines the
# assertions read; on stderr the trace never touches the serial). The
# assertions: the greeting, the Sv39 line (the kernel paged on the
# table it built), the checksum, the tick verdict, the filesystem's
# mount lines (the first instance's, then the one the supervisor
# restarted), the five console deliveries in order, the user program's
# proof chain — the kill report included, the machine surviving its
# offender — the shell REPL taking the foreground (T7.3: the prompt,
# the help line, the echo, the list, the boot file read back, the
# refusal after the remove, the unknown word named, and `poweroff`
# reaching the exit route) with the counter command starting the
# machine's program from the prompt (T7.4/T7.5: the console renderer's
# frames, the keys through the Elm loop, the quit key bringing the
# prompt back), the frame allocator's account as the last
# line, and the machine's own exit, the SBI poweroff. The filesystem's
# lines differ per boot (T7.2): the first boot's first mount formats
# the blank disk and counts no file, its restarted instance counts the
# root's one; the second boot's instances count the two files the
# first boot left.
boot() {
  local cpu="$1" mode="$2" log="$3" mount1="$4" mount2="$5" formats="$6"
  local fifo
  fifo=$(mktemp -u /tmp/emoos-serial.XXXXXX)
  mkfifo "$fifo"

  : > "$log"
  : > "$log.trace"
  # force-legacy=false: the transports report version 2 (the modern
  # register layout the driver speaks — 64-bit queue addresses, no
  # guest page size); a transitional device would answer version 1
  # and the driver's loud end names it.
  qemu-system-riscv64 -machine virt -nographic -d int -cpu "$cpu" \
    -global virtio-mmio.force-legacy=false \
    -drive file="$img",format=raw,if=none,id=emoos-blk \
    -device virtio-blk-device,drive=emoos-blk \
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

  # The shell (T7.3, docs/shell.md): the REPL takes the machine's
  # foreground once the proof chain is done — the first prompt is the
  # sync point, and every command waits for its answer before the next
  # feed. A line goes out in chunks no longer than the UART's receive
  # FIFO (16 bytes): QEMU delivers a burst before the guest's ISR
  # drains it, and an overrun drops bytes, so the pauses keep the
  # delivery boring. The exchange rides the same assertions as the
  # chain below; the poweroff command is what reaches the exit route
  # now.
  feed() {
    local s="$1" i=0
    while [ "$i" -lt "${#s}" ]; do
      printf '%s' "${s:i:12}" >&3
      sleep 0.05
      i=$((i + 12))
    done
    printf '\n' >&3
  }
  await() {
    local pat="$1"
    for _ in $(seq 1 100); do
      if grep -qF -- "$pat" "$log" 2>/dev/null; then
        return 0
      fi
      kill -0 "$qemu_pid" 2>/dev/null || break
      sleep 0.1
    done
    echo "run.sh: the shell never delivered '$pat'" >&2
    # The machine dies with the assertion, or the survivor poisons the
    # next run: its fifo, its log, and its disk are this run's.
    kill "$qemu_pid" 2>/dev/null || true
    exit 1
  }
  # The counter command (T7.5, docs/ui.md): the machine's program —
  # the console renderer pass (T7.4) — begun from the prompt, the
  # full-boot golden's beat between the shell and the filesystem
  # roundtrip. The shell spawns and parks at the wait; the first frame
  # is on the wire the moment the pass is spawned — no input needed —
  # then the keys, one byte at a time: `a` through update into
  # `count 001`, `b` back to `000`, `q` ending the pass, whose exit
  # answers the shell's wait and brings the prompt back. The frame
  # rides the write verb whole; nothing echoes — the frame is the
  # answer. The `help` fed after `q` queues behind it in the console's
  # ring: the child's read takes the `q` and quits, the REPL's read
  # takes the rest — the FIFO order is the whole handoff.
  await 'emo>'
  feed 'counter'
  await 'EmoUI on EmoOS'
  printf 'a' >&3
  await 'count 001'
  printf 'b' >&3
  printf 'q' >&3

  feed 'help'
  await 'commands: help echo ls cat write rm counter poweroff'
  feed 'echo repl answers'
  await 'echo repl answers'
  feed 'ls'
  await 'hello.txt'
  feed 'write note.txt shell wrote this'
  feed 'ls'
  feed 'cat boot.txt'
  await 'EmoOS boots from disk'
  feed 'rm note.txt'
  feed 'cat note.txt'
  await 'cat: no such file'
  feed 'bogus'
  await 'bogus: unknown command'
  feed 'poweroff'

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
  # the block device's line (T7.1: the driver scanned the virtio-mmio
  # slots, negotiated the modern layout, built its queue on one
  # allocator block, and the capacity reads 2048 sectors — the 1 MiB
  # image below), then the filesystem's first mount line (T7.2: the
  # service read sector 0 through the driver, formatted the blank disk
  # on the first boot or found the volume on the second, wrote the
  # generation back, read the name table, rebuilt its free map), then
  # the five console deliveries, in request order, then the restarted
  # instance's mount line (the root wrote a file through the first
  # instance and stopped it; the runtime's death hook told the
  # supervisor, which spawned the next — the generation one higher,
  # the file counted: the mount table durable on the disk, the cache
  # rebuilt from it) and `fs restart ok` (the file read back through
  # the restarted instance, byte for byte), then the user image's proof
  # chain: staged, the U-mode greeting (T6.2: every byte out of U-mode
  # rides the gate — the pass's own table maps nothing else), the gate
  # line, the byte the read waited for, the filesystem roundtrip
  # through the gate (T7.2: a 600-byte file written and read back byte
  # for byte, a second file written and removed, the list naming two),
  # the misbehaving
  # child's line, the supervisor's kill report (the faulting load is
  # the one the pass's own table maps nothing — the load page fault,
  # cause 13; the epc moves per build and is not asserted, but T6.4's
  # stval names the address and is asserted), then the runaway's line
  # and its allocator's exhaustion report (T5.1: the pass's own 64 KiB
  # arena, announced through the gate, the pid the spawn order fixes),
  # then the store-fault pass's line and its report (T6.4: a store
  # where the pass's own table maps nothing — the store page fault,
  # cause 15, the address named), then the reach pass's line and its
  # report (T6.5: a store at a kernel address, mapped without U — the
  # walk reaches the leaf and the permission fails, the same cause 15,
  # the kernel's high-half address named in full), then the good
  # child's line and the spawn/wait round trip answering after the
  # four deaths: the machine survived its offenders. Then the shell
  # (T7.3, docs/shell.md): the first prompt — the REPL took the
  # foreground when the proof chain ended — and the counter command
  # (T7.5, docs/ui.md) starting the machine's program from it (T7.4's
  # console renderer pass): the title line, the count's 000, the
  # buttons row, `count 001` after the first key, the quit key ending
  # the pass (the second `count 000` unasserted — the first occurrence
  # already proves the frame), its exit answering the shell's wait and
  # the prompt back — the full-boot golden's beat: a user program
  # begun from the shell. Then the shell's filesystem roundtrip: the
  # help line
  # (the eight commands), the echo
  # command's echo, the list naming hello.txt, the boot file's bytes
  # read back through the gate (`cat boot.txt`; the file the kernel
  # root wrote through the first instance, read by a user program —
  # nothing staged by the test), the refusal after the remove
  # (`cat: no such file`), the unknown word naming itself — the
  # machine's foreground answering, every byte through the gate. Then
  # the DMA
  # proof at the machine's end (T6.5): after everything this boot
  # took, split, and gave back, the allocator still answers one whole
  # 64 KiB block — block-aligned, one pattern word per frame, every
  # one read back — and returns it. Last, the frame allocator's
  # account at the root's exit (T5.3): thirty-three blocks taken — the
  # kernel's page tables' block (T6.1), the ten green spawns' arenas
  # (the three services', the supervisor's, the filesystem's two
  # instances', and the four readers'), the filesystem's cache block
  # (the supervisor's, held across the instances) and the root's
  # scratch block for its proof, a stack and an arena for each of the
  # six user passes, the six blocks the per-process tables' frames
  # split (the store-fault pass's frames from the splits' leftovers,
  # the reach pass's table splitting the fifth, the counter pass's the
  # sixth), the DMA check's block, and the block driver's queue block
  # (T7.1, held for the service's life like the services' arenas) —
  # and nineteen given back — the four readers' arenas at their
  # deaths, the first filesystem instance's arena at its stop, the
  # root's scratch block after its proof, both blocks of each user
  # pass at its kill or exit (the counter pass's at its clean exit),
  # and the DMA check's block home; the three services, the
  # supervisor, the live filesystem instance, every table, the cache
  # block, and the queue keep theirs. The byte offsets are the serial
  # order.
  local prev=0 pos line
  for line in 'sv39 8 0x8' 'blk 2048 ready' "$mount1" '0:97' '1:98' '2:99' '3:100' '4:101' "$mount2" 'fs restart ok' 'user: staged' 'U-MODE 500500' 'gate 500500 r3 r2' 'echo 88' 'fs rw ok' 'fs ls 2' 'doomed' 'user fault 12 cause 13' 'addr 0x80000000' 'greedy' 'user heap 13 gone' 'smash' 'user fault 14 cause 15' 'addr 0x40000000' 'reach' 'user fault 15 cause 15' 'addr 0xffffffc080200000' 'born' 'wait 7' 'emo>' 'EmoUI on EmoOS' 'count 000' '[a plus]' 'count 001' 'commands: help echo ls cat write rm counter poweroff' 'echo repl answers' 'hello.txt' 'EmoOS boots from disk' 'cat: no such file' 'bogus: unknown command' 'dma 0xffffffc08' '0000 ok' 'frames 33 19'; do
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
  # The shell's write, proven by the list that followed it: the second
  # `ls` answered `note.txt` on the line right after `hello.txt` — a
  # pair the write's own echo cannot produce (the first `ls` ran
  # before the write, so the line after its `hello.txt` is the
  # prompt). The check runs here, after the poweroff, because by then
  # both lists are on the wire.
  if ! grep -A1 '^hello.txt$' "$log" | grep -q '^note.txt$'; then
    echo "run.sh: the shell's write never made the list" >&2
    exit 1
  fi
  # The format happens exactly once, on the blank disk: the first boot's
  # first mount says so before its mount line; the second boot's never
  # does — the volume the first boot left is what it mounts.
  local formatted
  formatted=$(grep -c 'fs formatted' "$log" || true)
  if [ "$formatted" -ne "$formats" ]; then
    echo "run.sh: expected 'fs formatted' $formats time(s), saw $formatted" >&2
    exit 1
  fi
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
# The first boot meets the blank disk: the filesystem formats it, and
# its restarted instance counts the root's one file.
boot 'rv64,sstc=false' legacy '.qemu.log' 'fs gen 1 files 0' 'fs gen 2 files 1' 1
echo "run.sh: legacy SBI set_timer ticks: greeting, sv39, proof, fs format, console, fs restart, user, fs roundtrip, kill, shell, counter, frames, self-exit"
# The stimecmp transport when it does. The second boot meets the volume
# the first left — two files, the root's and hello's — and formats
# nothing: the mount table came off the disk.
boot 'rv64,sstc=true' sstc '.qemu-sstc.log' 'fs gen 3 files 2' 'fs gen 4 files 2' 0
echo "run.sh: sstc stimecmp ticks: greeting, sv39, proof, fs mount, console, fs restart, user, fs roundtrip, kill, shell, counter, frames, self-exit, 1 ecall"
