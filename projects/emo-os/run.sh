#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

elf='main.elf'

if [ ! -f "$elf" ]; then
  echo "run.sh: $elf not found; build both images first — start.sh does it" >&2
  echo "  (it stages the desktop's packages into a registry the user image" >&2
  echo "  requires, then builds the user image and the kernel; by hand, see" >&2
  echo "  docs/how-to-start-emoos.md)" >&2
  exit 1
fi

# The corpus leg (emo-desktop A7.3, A8.3): the frames' digests are the
# hosted corpus's numbers, never this file's. The fb backend's frame
# golden (projects/emo-desktop/fb/frame/golden) runs the counter the
# screen pass runs — the same loop, the same three keys — on the hosted
# canvas, and pins one `frame <digest>` line per presented frame in
# `expected.txt`: four lines, the mount's frame and one per key, the
# same bytes from the interpreter and every hosted target, the fb
# gate's own assertion. The assertions below read that file: the lines
# the pass prints as its carve presents, in the file's order, and the
# folds over the display's two screendumps — the first frame's and the
# session's last. The metal and the corpus cannot drift apart, because
# the numbers live in one place and it is the corpus. The dune smoke
# runs this script from a scratch tree that carries no fb tree and
# points FRAME_EXPECTED at the repository's file; a missing file is the
# loud end, never a default.
frame_expected=${FRAME_EXPECTED:-../emo-desktop/fb/frame/golden/expected.txt}
if [ ! -f "$frame_expected" ]; then
  echo "run.sh: the frames' corpus file is missing: $frame_expected" >&2
  echo "  (the hosted golden under projects/emo-desktop/fb/frame/golden pins the" >&2
  echo "  digests this run asserts; FRAME_EXPECTED names the file)" >&2
  exit 1
fi
frame_digests=$(awk '$1 == "frame" { print $2 }' "$frame_expected")
for d in $frame_digests; do
  case $d in
    ''|*[!0-9]*)
      echo "run.sh: $frame_expected carries a 'frame' line that is not a digest" >&2
      exit 1
      ;;
  esac
done
if [ "$(echo "$frame_digests" | wc -w | tr -d ' ')" -ne 4 ]; then
  echo "run.sh: $frame_expected must carry four 'frame <digest>' lines — the" >&2
  echo "  counter's session is the mount's frame and one per key (add, add, sub)" >&2
  exit 1
fi
frame_digest=$(echo "$frame_digests" | head -1)
frame_last=$(echo "$frame_digests" | tail -1)

# The window shell's corpus file (emo-desktop A9.1): the fb window
# golden (projects/emo-desktop/fb/win/golden) paints the shell pass's
# two windows through the session the pass runs — up, a focus, a key,
# a drag's focus and release, a drag back, a key — on the hosted canvas
# and pins one `frame <digest>` line per present: nine lines, the same
# bytes from every hosted target. The assertions below read that file
# the way they read the frames': the lines the pass prints as its
# windows present, in the file's order, and the folds over each
# window's rectangle of the display's screendumps at the beats the
# pointer is parked away. WIN_EXPECTED names the file; the dune smoke
# points it at the repository's.
win_expected=${WIN_EXPECTED:-../emo-desktop/fb/win/golden/expected.txt}
dock_expected=${DOCK_EXPECTED:-../emo-desktop/fb/desktop/golden/expected.txt}
if [ ! -f "$dock_expected" ]; then
  echo "run.sh: the dock's corpus file is missing: $dock_expected" >&2
  exit 1
fi
dock_digests=$(awk '$1 == "frame" { print $2 }' "$dock_expected")
if [ "$(echo "$dock_digests" | grep -c .)" -ne 3 ]; then
  echo "run.sh: $dock_expected must carry three 'frame <digest>' lines — the dock's" >&2
  echo "  strip with no app focused, alpha's tile lit, beta's" >&2
  exit 1
fi
dock_line() {
  echo "$dock_digests" | sed -n "${1}p"
}
if [ ! -f "$win_expected" ]; then
  echo "run.sh: the windows' corpus file is missing: $win_expected" >&2
  echo "  (the hosted golden under projects/emo-desktop/fb/win/golden pins the" >&2
  echo "  digests this run asserts; WIN_EXPECTED names the file)" >&2
  exit 1
fi
win_digests=$(awk '$1 == "frame" { print $2 }' "$win_expected")
for d in $win_digests; do
  case $d in
    ''|*[!0-9]*)
      echo "run.sh: $win_expected carries a 'frame' line that is not a digest" >&2
      exit 1
      ;;
  esac
done
if [ "$(echo "$win_digests" | wc -w | tr -d ' ')" -ne 9 ]; then
  echo "run.sh: $win_expected must carry nine 'frame <digest>' lines — the" >&2
  echo "  window shell's session is two windows up, a focus, a key, a drag's" >&2
  echo "  focus and release, a drag back, a key" >&2
  exit 1
fi
win_line() {
  echo "$win_digests" | sed -n "${1}p"
}

# The pointer's drawing (emo-desktop A8.2, T8.11): the sprite the
# compositor's cursor plane composites is the desktop's, drawn in
# `pointer.emo` as rows of cells (`#` ink, `o` paper, `.` clear), and
# the model of the display below reads those rows off the same file —
# the display's pixels and the drawing cannot drift apart, for the
# reason the frame's digest cannot: one drawing, one file. POINTER_SPRITE
# names the file; the dune smoke points it at the repository's.
pointer_sprite=${POINTER_SPRITE:-../emo-desktop/fb/pointer.emo}
if [ ! -f "$pointer_sprite" ]; then
  echo "run.sh: the pointer sprite's drawing is missing: $pointer_sprite" >&2
  echo "  (projects/emo-desktop/fb/pointer.emo draws the sprite the compositor" >&2
  echo "  composites and this run's display model reads; POINTER_SPRITE names it)" >&2
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
# offender — the screen carve's proof (T8.2: the first full-screen
# pass paints the carve its spawn was granted, the pattern read back
# through the kernel's half, the second screen spawn refused) with the
# desktop's first frame on it (emo-desktop A7.2: the pass lays the fb
# core's tree into the carve before the pattern, its own digest of the
# carve on the wire as `frame <n>`, and the display's screendump at the
# present digests to the same number — the number the hosted twin
# prints) — the
# desktop segment's verbs (T8.4: `output 1024x768`, the mode the
# device's own answer, and `present ok`, the grant's commit — the
# transfer and the flush complete before the line; the unauthorized
# `present r3` the input pass's refusal) — the
# input merge's proof (T8.3: the pass parked on the merged stream —
# `keys?` — the monitor's sendkey delivering the device's key event,
# the serial's byte riding the same stream after it, the bytes first)
# and the unknown grant's refusal (`close r4`) — the window buffer's
# proof (T8.5: the run handed, the mapping painted and read back, the
# commit recorded, the release home — the lifecycle's four lines and
# the clean exit) — the
# compositor's compositions (T8.6: the stack's blit answering the
# present, the move a second blit at (16,32), the focus, the close —
# the death notice's restart reclaiming the first instance's arena) —
# the golden's eyes (T8.8: the monitor's screendump takes the
# display's PPM once the moved copy's flush has landed, and every
# pixel reads back against the composition history's union — the
# gradient, the first copy's surviving rows, the moved copy on top) —
# the shell REPL taking the foreground (T7.3: the prompt,
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
  local mon qmp
  mon=$(mktemp -u /tmp/emoos-mon.XXXXXX)
  qmp=$(mktemp -u /tmp/emoos-qmp.XXXXXX)

  : > "$log"
  : > "$log.trace"
  # force-legacy=false: the transports report version 2 (the modern
  # register layout the driver speaks — 64-bit queue addresses, no
  # guest page size); a transitional device would answer version 1
  # and the driver's loud end names it. The display's mode is the
  # assessment's decided baseline (1024x768 XRGB8888) — the device
  # property is where that decision lives, and the driver still reads
  # whatever the device answers (T8.1; this QEMU's own default is
  # 1280x800, the golden would name it). The display itself has no
  # window on the asserted leg (`-display none`): its truth is the
  # monitor's screendump (T8.8); the ride's window is start.sh's. The
  # keyboard (T8.3) is the merged input stream's device half and the
  # tablet (T8.11) the pointer's — absolute axes, so the position the
  # monitor's mouse_move names is the position the device reports; the
  # monitor socket is the run's hand — the sendkey and the mouse_move
  # the input beat waits for.
  qemu-system-riscv64 -machine virt -nographic -display none -d int -cpu "$cpu" \
    -global virtio-mmio.force-legacy=false \
    -drive file="$img",format=raw,if=none,id=emoos-blk \
    -device virtio-blk-device,drive=emoos-blk \
    -device virtio-gpu-device,xres=1024,yres=768 \
    -device virtio-keyboard-device \
    -device virtio-tablet-device \
    -monitor unix:"$mon",server,nowait \
    -qmp unix:"$qmp",server,nowait \
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
  # The run's hand (T8.3): one HMP command over the monitor socket —
  # connect, take the banner, send the line, close. The sendkey is how
  # the merged input stream's device half gets its event; the serial
  # feed above is how the byte half does.
  hmp() {
    python3 - "$mon" "$1" <<'PYEOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.3)
try:
    s.recv(4096)
except OSError:
    pass
s.sendall((sys.argv[2] + "\n").encode())
time.sleep(0.3)
s.close()
PYEOF
  }
  # The run's other hand (T8.11): one QMP command over the second
  # socket — the capabilities handshake, the command, the answer read,
  # the socket closed. The pointer's events ride it: the monitor's
  # mouse_move queues relative motion, which an absolute device — the
  # tablet — has no handler for and QEMU drops, so the absolute report
  # is input-send-event's, the one hand that names a position.
  qmp() {
    python3 - "$qmp" "$1" <<'PYEOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
f = s.makefile('rw')
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
f.flush()
f.readline()
f.write(sys.argv[2] + "\n")
f.flush()
answer = json.loads(f.readline())
if "error" in answer:
    sys.exit(f"run.sh: QMP refused {sys.argv[2]}: {answer['error']}")
s.close()
PYEOF
  }
  abs() {
    qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":'"$1"'}},{"type":"abs","data":{"axis":"y","value":'"$2"'}}]}}'
  }
  # The first frame (emo-desktop A7.2, A8.3): the screen pass's loop
  # mounted the counter — the fb core laid its tree into the carve and
  # the carve presented it, its own digest of its words on the wire
  # (`frame <n>`) before the present. The monitor's screendump takes the
  # display's PPM, and the same fold over its pixels — `d = (d * 31 +
  # word) mod 2^32`, the word the pixel's XRGB, row-major — has to
  # answer the same number, which is the corpus's first number read
  # above (the hosted twin's `expected.txt`, A7.3): the carve the core
  # painted, the display the device scanned out, the canvas on the host
  # — three readings, one number, one file. The dump is taken here, with
  # the loop parked on the merged stream for its first key: nothing
  # presents until a byte arrives, so the display holds the first frame
  # alone.
  await 'present ok'
  hmp 'screendump .frame.ppm'
  digest_is() {
    local ppm="$1" want="$2" what="$3"
    if ! PPM="$ppm" WANT="$want" WHAT="$what" python3 - <<'PYEOF'
import os
import sys

data = open(os.environ['PPM'], 'rb').read()
if data[:16] != b'P6\n1024 768\n255\n' or len(data) != 16 + 1024 * 768 * 3:
    sys.exit(f"run.sh: the {os.environ['WHAT']}'s screendump is not the mode's P6 1024x768")
px = data[16:]
d = 0
for i in range(0, len(px), 3):
    d = (d * 31 + ((px[i] << 16) | (px[i + 1] << 8) | px[i + 2])) & 0xFFFFFFFF
want = int(os.environ['WANT'])
if d != want:
    sys.exit(f"run.sh: the display's {os.environ['WHAT']} digests to {d}; the corpus's is {want}")
PYEOF
    then
      kill "$qemu_pid" 2>/dev/null || true
      exit 1
    fi
  }
  digest_is .frame.ppm "$frame_digest" 'first frame'
  # The Elm loop's session (emo-desktop A8.3): the counter's three keys
  # through the serial line — each a byte on the merged stream the
  # pass's `Keys` maps onto a tag (`byte <n>` on the wire), through
  # `update` into the next model, through `view` into the next tree,
  # painted and presented from scratch, the frame before it reclaimed
  # through the pool — add, add, sub, one `present ok` each, counted
  # because the lines repeat; then the display at the session's end
  # folds to the corpus's last number, the counter at one, and the quit
  # key ends the loop, whose exit the pattern words and the parent's
  # wait follow.
  await_count() {
    local pat="$1" n="$2"
    for _ in $(seq 1 100); do
      if [ "$(grep -caF -- "$pat" "$log" 2>/dev/null || true)" -ge "$n" ]; then
        return 0
      fi
      kill -0 "$qemu_pid" 2>/dev/null || break
      sleep 0.1
    done
    echo "run.sh: the shell never delivered '$pat' $n times" >&2
    kill "$qemu_pid" 2>/dev/null || true
    exit 1
  }
  printf 'a' >&3
  await_count 'present ok' 2
  printf 'a' >&3
  await_count 'present ok' 3
  printf 'b' >&3
  await_count 'present ok' 4
  hmp 'screendump .counter.ppm'
  digest_is .counter.ppm "$frame_last" "session's last frame"
  printf 'q' >&3
  await 'byte 113'
  # The input merge's beat (T8.3): the pass parks on the merged stream
  # (`keys?` on the wire), the monitor's hand answers it — one sendkey,
  # the device's key event — and the serial's byte rides the same
  # stream after it: one stream, two sources, the bytes first.
  await 'keys?'
  hmp 'sendkey q'
  await 'key 1 16 1'
  printf 'K' >&3
  await 'byte 75'
  # The pointer's beat (T8.11, emo-desktop A8.2): the monitor's hand
  # moves the tablet to the display's center — input-send-event's
  # absolute coordinates on the device's 0..32767 axes — and two things
  # happen from the one report: the pointer driver's events ride the merged stream after
  # the keyboard's (the pass prints the X and the Y as `move <axis>
  # <value>`), and the driver's notice reaches the compositor, whose
  # cursor plane scales the position to the mode, composites the
  # desktop's sprite into the carve, presents the rectangle, and says
  # so once (`pointer 512 384`, the hotspot's place). The two lines'
  # order is the scheduler's, so each is awaited on its own; the
  # sprite's pixels are the second screendump's below.
  qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":16384}},{"type":"abs","data":{"axis":"y","value":16384}}]}}'
  await 'move 1 16384'
  await 'pointer 512 384'
  # The golden's eyes (T8.8, T8.13): the compositor's compositions
  # carried the window's frame into the carve and flushed — the monitor's
  # screendump takes the display's PPM and every pixel is read back
  # against the model of the composition: since the stack's walk
  # (T8.13) every composition clears the carve to the desktop's
  # background before it blits the stack, so the counter's last frame
  # and the screen carve's proof pattern are gone from the display the
  # moment the window pass first presents, and the moved copy's
  # composition leaves the window's frame at (16,32) alone — its first
  # copy at (0,0) is background again (the paint carries its row in the
  # blue lane, 0x57494E00 + row) — with the pointer's sprite over it all
  # at the center the beat put it at, hidden around the walk and shown
  # again. The roles' substance (emo-desktop A9.3) rides the same walk:
  # the popup hangs from the window at its (48,32) offset — (64,64) on
  # the display after the parent's move, the parent-relative binding
  # the model's arithmetic — the subsurface at (416,64), the panel the
  # bottom strip the walk paints last over everything. A wrong pixel
  # anywhere is the loud end — and a dead check kills the machine
  # first, the survivor poisons the next run.
  await 'comp 16 32'
  hmp 'screendump .screen.ppm'
  if ! POINTER_SPRITE="$pointer_sprite" python3 - <<'PYEOF'
import sys

data = open('.screen.ppm', 'rb').read()
if data[:16] != b'P6\n1024 768\n255\n' or len(data) != 16 + 1024 * 768 * 3:
    sys.exit("run.sh: the screendump is not the mode's P6 1024x768")
px = data[16:]

# The pointer sprite (T8.11, emo-desktop A8.2): the drawing's rows read
# off pointer.emo — the quoted strings of `.`, `#` and `o` — composited
# over everything at the hotspot the beat put it at, (512, 384): ink
# black, paper white, a clear cell the pixel beneath. The compositor hid
# it around the walk and showed it again, so it lies over the background
# untouched by the blit.
import os
import re

rows = re.findall(r'^\s*"([.#o]+)",?\s*$', open(os.environ['POINTER_SPRITE']).read(), re.M)
if len(rows) != 17 or any(len(r) != 12 for r in rows):
    sys.exit(f"run.sh: {os.environ['POINTER_SPRITE']} does not draw the 12x17 sprite")

def sprite(x, y):
    r, c = y - 384, x - 512
    if 0 <= r < 17 and 0 <= c < 12:
        cell = rows[r][c]
        if cell == '#':
            return (0, 0, 0)
        if cell == 'o':
            return (255, 255, 255)
    return None

def want(x, y):
    s = sprite(x, y)
    if s is not None:
        return s
    if 0 <= x < 1024 and 736 <= y < 768:
        return (78, 76, y - 736)
    if 64 <= x < 192 and 64 <= y < 128:
        return (79, 80, y - 64)
    if 416 <= x < 480 and 64 <= y < 128:
        return (85, 66, y - 64)
    if 16 <= x < 528 and 32 <= y < 160:
        return (73, 78, y - 32)
    return (48, 48, 56)

for y in range(768):
    row = px[y * 3072:(y + 1) * 3072]
    for x in range(1024):
        got = (row[x * 3], row[x * 3 + 1], row[x * 3 + 2])
        if got != want(x, y):
            sys.exit(f'run.sh: the pixel at ({x},{y}) is {got}, the model says {want(x, y)}')
PYEOF
  then
    kill "$qemu_pid" 2>/dev/null || true
    exit 1
  fi
  await 'win 0'
  # The window era's display beat is done; the desk pass parks before its
  # first frame (the counter's shape), so every era below waits for this
  # run's byte at its own gate.
  printf 'c' >&3
  # The client's kill and rebirth (emo-desktop A9.2): a client pass of
  # its own opens a toplevel surface at (96,320), presents it — the
  # composition `comp 96 320` carries the client's frame alone, the
  # T8.5 window's entry pruned — and dies without closing: a store its
  # table maps nothing, the fault the death-side reclaim waits for, the
  # run back to the allocator, the row emptied, the surface off the
  # stack (`comp reclaim` names the dead owner). The hand opens the
  # rebirth: a fresh pass, a fresh grant (3), a different place
  # (512,320) and a different pattern — the comp carries the reborn
  # frame alone, which is the reclaim's arithmetic proof: a stuck
  # surface would double the carried sum. The screendump is the visual
  # one: the reborn window's rows where it stands, the dead client's
  # old rect background — the walk cleared the carve and the surface is
  # off the stack — the pointer parked at (16,16) out of both rects.
  await 'comp 96 320 2102906880'
  await 'client up 5'
  await 'user fault 26 cause 15'
  await 'addr 0x20000000'
  printf 'c' >&3
  await 'comp reclaim 26'
  await 'client up 6'
  await 'comp 512 320 4174893056'
  abs 512 683
  sleep 1
  hmp 'screendump .client.ppm'
  if ! POINTER_SPRITE="$pointer_sprite" python3 - <<'PYEOF2'
import os
import re
import sys

e = os.environ
data = open('.client.ppm', 'rb').read()
if data[:16] != b'P6\n1024 768\n255\n' or len(data) != 16 + 1024 * 768 * 3:
    sys.exit("run.sh: the client screendump is not the mode's P6 1024x768")
px = data[16:]

rows = re.findall(r'^\s*"([.#o]+)",?\s*$', open(e['POINTER_SPRITE']).read(), re.M)
if len(rows) != 17 or any(len(r) != 12 for r in rows):
    sys.exit(f"run.sh: {e['POINTER_SPRITE']} does not draw the 12x17 sprite")

def sprite(x, y):
    r, c = y - 16, x - 16
    if 0 <= r < 17 and 0 <= c < 12:
        cell = rows[r][c]
        if cell == '#':
            return (0, 0, 0)
        if cell == 'o':
            return (255, 255, 255)
    return None

def want(x, y):
    s = sprite(x, y)
    if s is not None:
        return s
    if 512 <= x < 896 and 320 <= y < 448:
        return (69, 66, y - 320)
    return (48, 48, 56)

for y in range(768):
    row = px[y * 3072:(y + 1) * 3072]
    for x in range(1024):
        got = (row[x * 3], row[x * 3 + 1], row[x * 3 + 2])
        if got != want(x, y):
            sys.exit(f'run.sh: the pixel at ({x},{y}) is {got}, the model says {want(x, y)}')
PYEOF2
  then
    kill "$qemu_pid" 2>/dev/null || true
    exit 1
  fi
  printf 'c' >&3
  await 'client back'
  printf 'z' >&3
  abs 16384 16384
  sleep 1
  # The window shell (emo-desktop A9.1, T8.13): the desk pass puts two
  # toplevel windows up — alpha at (64,128), beta at (576,384), each
  # 384x128, their grants 2 and 3, the pointer's range the device's own
  # answer through verb 18 (`desk range 32767 32767`) — and the display
  # is read three ways at every parked beat: the pixels outside the two
  # windows are the background with the sprite where the hand left it,
  # and each window's rectangle folds to the digest the hosted twin's
  # file names for that frame (the same fold the carve's frames use,
  # over the rectangle alone), or does not when another window covers
  # it — the stack's order on the display. The beats: both windows up
  # (the first two lines of the file); a press on alpha's body focusing
  # it (`desk focus 2`), a key routed to alpha (`desk key 2 1`); a press
  # on beta's bar focusing beta and beginning a drag (`desk focus 3`),
  # the pointer walked to where beta lands over alpha, the release
  # presenting it there (`desk drag 3 96 160`) — beta on top, alpha's
  # rectangle no longer its own frame; the drag back (`desk drag 3 576
  # 384`); a key routed to beta (`desk key 3 1`); the quit byte ending
  # the shell, its windows closed, the parent's wait answered (`desk
  # 0`). The hand is QMP's input-send-event: absolute reports on the
  # tablet's axes (a display position P is P*32 on x and the first value
  # at or past P*128/3 on y, the mode over the range) and the left
  # button's press and release; before each screendump the pointer is
  # parked at (16,700), off both windows, so no window's fold carries the
  # sprite — the plane says its one line at the first placement only, so
  # the park waits a beat and the model's sprite is the check.
  desk_is() {
    local ppm="$1" ax="$2" ay="$3" bx="$4" by="$5" want_a="$6" not_a="$7" want_b="$8" cx="$9" cy="${10}" want_d="${11}" what="${12}"
    if ! PPM="$ppm" AX="$ax" AY="$ay" BX="$bx" BY="$by" WANT_A="$want_a" NOT_A="$not_a" WANT_B="$want_b" CX="$cx" CY="$cy" WANT_D="$want_d" WHAT="$what" POINTER_SPRITE="$pointer_sprite" python3 - <<'PYEOF'
import os
import re
import sys

e = os.environ
data = open(e['PPM'], 'rb').read()
if data[:16] != b'P6\n1024 768\n255\n' or len(data) != 16 + 1024 * 768 * 3:
    sys.exit(f"run.sh: the {e['WHAT']}'s screendump is not the mode's P6 1024x768")
px = data[16:]
ax, ay, bx, by = int(e['AX']), int(e['AY']), int(e['BX']), int(e['BY'])
cx, cy = int(e['CX']), int(e['CY'])
W, H = 384, 128
# The dock (emo-desktop A10.2): the shell's strip at the bottom edge,
# the walk's topmost — no window over it, the sprite parked out of it.
DX, DY, DW, DH = 0, 728, 1024, 40

rows = re.findall(r'^\s*"([.#o]+)",?\s*$', open(e['POINTER_SPRITE']).read(), re.M)
if len(rows) != 17 or any(len(r) != 12 for r in rows):
    sys.exit(f"run.sh: {e['POINTER_SPRITE']} does not draw the 12x17 sprite")

def sprite(x, y):
    r, c = y - cy, x - cx
    if 0 <= r < 17 and 0 <= c < 12:
        cell = rows[r][c]
        if cell == '#':
            return (0, 0, 0)
        if cell == 'o':
            return (255, 255, 255)
    return None

def inside(x, y, wx, wy):
    return wx <= x < wx + W and wy <= y < wy + H

for y in range(768):
    row = px[y * 3072:(y + 1) * 3072]
    for x in range(1024):
        if inside(x, y, ax, ay) or inside(x, y, bx, by):
            continue
        if DX <= x < DX + DW and DY <= y < DY + DH:
            continue
        got = (row[x * 3], row[x * 3 + 1], row[x * 3 + 2])
        want = sprite(x, y) or (48, 48, 56)
        if got != want:
            sys.exit(f"run.sh: at the {e['WHAT']} the pixel at ({x},{y}) is {got}, the model says {want}")

def fold(wx, wy, fw, fh):
    d = 0
    for y in range(wy, wy + fh):
        o = (y * 1024 + wx) * 3
        for x in range(fw):
            d = (d * 31 + ((px[o] << 16) | (px[o + 1] << 8) | px[o + 2])) & 0xFFFFFFFF
            o += 3
    return d

fa = fold(ax, ay, W, H)
fb = fold(bx, by, W, H)
fd = fold(DX, DY, DW, DH)
if e['WANT_A'] and fa != int(e['WANT_A']):
    sys.exit(f"run.sh: at the {e['WHAT']} alpha's rectangle digests to {fa}; the corpus's is {e['WANT_A']}")
if e['NOT_A'] and fa == int(e['NOT_A']):
    sys.exit(f"run.sh: at the {e['WHAT']} alpha's rectangle still digests to its own frame {fa}; beta should cover it")
if fb != int(e['WANT_B']):
    sys.exit(f"run.sh: at the {e['WHAT']} beta's rectangle digests to {fb}; the corpus's is {e['WANT_B']}")
if fd != int(e['WANT_D']):
    sys.exit(f"run.sh: at the {e['WHAT']} the dock's strip digests to {fd}; the corpus's is {e['WANT_D']}")
PYEOF
    then
      kill "$qemu_pid" 2>/dev/null || true
      exit 1
    fi
  }
  btn() {
    qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"down":'"$1"',"button":"left"}}]}}'
  }
  await 'desk range 32767 32767'
  await 'desk b 8'
  await 'comp 576 384'
  # The dock's first frame (emo-desktop A10.2): the strip's own
  # present, its composition the walk's carrying of it — the panel
  # over everything, the model's bottom strip skipped for it.
  await 'comp 0 728'
  hmp 'screendump .desk1.ppm'
  desk_is .desk1.ppm 64 128 576 384 "$(win_line 1)" '' "$(win_line 2)" 512 384 "$(dock_line 1)" 'windows up'
  abs 3200 8534
  btn true
  btn false
  await 'desk focus 7'
  await 'comp 0 728'
  printf 'a' >&3
  await 'desk key 7 1'
  # The beta focus rides the dock's tile (emo-desktop A10.2): a press
  # on the strip names the tile, the tile names its app, the dock
  # repaints with the tile lit.
  abs 2048 31979
  btn true
  btn false
  await 'desk focus 8'
  await 'comp 0 728'
  abs 19200 16896
  btn true
  abs 11520 12118
  abs 3840 7339
  btn false
  await 'desk drag 8 96 160'
  abs 512 29867
  sleep 1
  hmp 'screendump .desk2.ppm'
  desk_is .desk2.ppm 64 128 96 160 '' "$(win_line 5)" "$(win_line 6)" 16 700 "$(dock_line 3)" 'drag'
  abs 4480 7339
  btn true
  abs 12000 12000
  abs 19840 16896
  btn false
  await 'desk drag 8 576 384'
  printf 'a' >&3
  await 'desk key 8 1'
  abs 512 29867
  sleep 1
  hmp 'screendump .desk3.ppm'
  desk_is .desk3.ppm 64 128 576 384 "$(win_line 5)" '' "$(win_line 9)" 16 700 "$(dock_line 3)" 'drag back'
  printf 'q' >&3
  await 'desk 0'
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
  await 'emo-os>'
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
  # image below), then the display driver's two lines (T8.1: the
  # virtio-gpu on the blk_service's shape — the slot scan, the modern
  # negotiation, the control queue on one allocator block, the 2D path
  # whole: the resource created at the format the baseline decided, the
  # screen carve attached as the backing, scanout 0 pointed at it — and
  # the mode is the device's own answer, 1024x768, never a constant),
  # then the root's flush smoke (`gpu flush ok`: the paint rode the
  # mode the driver answered, the device's transfer and flush both came
  # back OK — the pixels left the carve's physical bytes and reached
  # the display), then the filesystem's first mount line (T7.2: the
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
  # child's line (the pids are the spawn order's: the pointer driver,
  # T8.11, is one more kernel process ahead of every user pass, so the
  # four offenders are 18 to 21 now), the supervisor's kill report (the faulting load is
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
  # four deaths: the machine survived its offenders. Then the screen
  # carve's proof (T8.2): the machine's first full-screen pass — the
  # cells-page token poked, the spawn's kernel side handing the carve
  # into the child's table, the child's pattern painted across the
  # whole 4 MiB and read back through the kernel's half (`screen
  # 0x86c00000 ok`, the base asserted in full) — and the second screen
  # spawn refused, the carve handed once (`screen r5`, the resource
  # refusal's number). Then the desktop segment's verbs (T8.4):
  # `output 1024x768` — the mode the device's own answer through verb
  # 11 — and `present ok`, the grant's commit through verb 10 (the
  # gate checked the carve's holder, the display service judged the
  # rect, the transfer and the flush completed before the line); the
  # input pass's `present r3` is the authorization table's edge, the
  # permission refusal a non-holder meets. Then the shell
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
  # account at the root's exit (T5.3): fifty-three blocks taken — the
  # kernel's page tables' block (T6.1), the fourteen green spawns'
  # arenas (the five services', the compositor supervisor's, the
  # compositor's two instances', the supervisor's, the filesystem's
  # two instances', and the four readers'), the filesystem's cache
  # block (the supervisor's, held across the instances) and the root's
  # scratch block for its proof, a stack and an arena for each of the
  # eleven user passes (the screen pass's, the input pass's, and the
  # window pass's, T8.2, T8.3, and T8.5, beside the six, and the two
  # clients', A9.2), the
  # eleven blocks the per-process tables' frames split (the store-fault
  # pass's frames from the splits' leftovers, the reach pass's table
  # splitting the fifth, the counter pass's the sixth, the screen
  # pass's the seventh, the input pass's the eighth, the window pass's
  # the ninth, the clients' the tenth and the eleventh), the window
  # buffer's four-block run (T8.5, taken at
  # win_new and given back at its win_close), the clients' two (A9.2:
  # each spawn's arena and table and each win_new's run, the dead
  # one's every block back through the compositor's reclaim, the
  # reborn one's through its close), the DMA check's block,
  # and the block driver's
  # queue block (T7.1) beside the display driver's (T8.1), the input
  # driver's (T8.3) and the pointer driver's (T8.11 — its two-block
  # arena run and its queue block are the three the count grew by),
  # each held
  # for the service's life like the services' arenas — and
  # thirty given back, twelve of them the clients' (A9.2) — the four readers' arenas at
  # their deaths, the first filesystem instance's arena at its stop,
  # the first compositor instance's arena at its stop (T8.6's restart
  # proof), the root's scratch block after its proof, both blocks of
  # each user pass at its kill or exit (the counter pass's, the screen
  # pass's, the input pass's, and the window pass's at their clean
  # exits, and the clients': the dead one's to the fault's reap and
  # the compositor's reclaim, the reborn one's to its exit), the
  # window buffer's run at its close, and the DMA check's
  # block home; the services, the supervisors, the live filesystem and
  # compositor instances, every table, the cache block, and the queues
  # keep theirs. The byte offsets are the serial order.
  local prev=0 pos line
  for line in 'sv39 8 0x8' 'blk 2048 ready' 'gpu 1024x768 ready' 'input ready' 'pointer ready' 'gpu flush ok' "$mount1" '0:97' '1:98' '2:99' '3:100' '4:101' "$mount2" 'fs restart ok' 'user: staged' 'U-MODE 500500' 'gate 500500 r3 r2' 'echo 88' 'fs rw ok' 'fs ls 2' 'doomed' 'user fault 18 cause 13' 'addr 0x80000000' 'greedy' 'user heap 19 gone' 'smash' 'user fault 20 cause 15' 'addr 0x40000000' 'reach' 'user fault 21 cause 15' 'addr 0xffffffc080200000' 'born' 'wait 7' 'output 1024x768' 'present ok' 'byte 97' 'byte 98' 'byte 113' 'screen 0x86c00000 ok' 'screen r5' 'keys?' 'key 1 16 1' 'byte 75' 'move 0 16384' 'move 1 16384' 'present r3' 'close r4' 'win 1' 'present r4' 'role toplevel r4' 'win ok' 'win sum 2803875840' 'format 0 ok' 'format 1 r4' 'scale 1 ok' 'scale 2 r4' 'protocol 1' 'comp 0 0 2803875840' 'win shown' 'comp 48 32 2619455488' 'popup up' 'comp 400 32 1177728000' 'sub up' 'parent panel r4' 'comp 0 736 3644232704' 'panel up' 'parent gone r4' 'win moved' 'comp 16 32 3644232704' 'win focused' 'popup closed' 'sub closed' 'panel closed' 'win closed' 'win 0' 'comp 96 320 2102906880' 'client up 5' 'user fault 26 cause 15' 'addr 0x20000000' 'comp reclaim 26' 'comp 512 320 4174893056' 'client up 6' 'client back' 'desk range 32767 32767' 'desk a 7' 'desk b 8' 'comp 64 128' 'comp 576 384' 'desk focus 7' 'desk key 7 1' 'desk focus 8' 'desk drag 8 96 160' 'desk drag 8 576 384' 'desk key 8 1' 'desk 0' ' _____                   ' $'\033[36m   ____     ____  ' 'emo-os>' 'EmoUI on EmoOS' 'count 000' '[a plus]' 'count 001' 'commands: help echo ls cat write rm counter poweroff' 'echo repl answers' 'hello.txt' 'EmoOS boots from disk' 'cat: no such file' 'bogus: unknown command' 'dma 0xffffffc08' 'frames 111 73'; do
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
  # The frame callback's line (emo-desktop A9.3): the win pass's answer
  # to its park — the composition the client's frame rode, so the line
  # is the callback's proof. Its order against the dying client's lines
  # is the scheduler's (the reply wakes both), so it is placed here,
  # not in the list above: after the park's marker, before the era's
  # end.
  cbstart=$(grep -aboF -- 'win 0' "$log" | head -1 | cut -d: -f1)
  cbend=$(grep -aboF -- 'client back' "$log" | head -1 | cut -d: -f1)
  cbpos=$(grep -aboF -- 'cb ok' "$log" | head -1 | cut -d: -f1 || true)
  if [ -z "$cbpos" ]; then
    echo "run.sh: the console never delivered 'cb ok'; the frame callback never answered" >&2
    exit 1
  fi
  if [ "$cbpos" -lt "$cbstart" ] || [ "$cbpos" -gt "$cbend" ]; then
    echo "run.sh: 'cb ok' arrived outside its era (after byte $cbstart, before byte $cbend)" >&2
    exit 1
  fi
  # The loop's frames (emo-desktop A7.2, A7.3, A8.3): the pass's own
  # digest of the carve at every present, whole lines, in the corpus's
  # order — the four of `$frame_expected`, never a literal of this
  # file's, so the metal asserts the corpus leg's file directly. The
  # first lies between the mode's line and the first present's (the
  # mount's frame, before any key); each later one after the one before
  # it — the second and the fourth are the same number, the counter at
  # one both times, so the search for each starts past the last — and
  # the last before the carve's read-back, which is the loop's end.
  local fprev=-1 fpos opos ppos spos d
  opos=$(grep -aboF -- 'output 1024x768' "$log" | head -1 | cut -d: -f1)
  ppos=$(grep -aboF -- 'present ok' "$log" | head -1 | cut -d: -f1)
  spos=$(grep -aboF -- 'screen 0x86c00000 ok' "$log" | head -1 | cut -d: -f1)
  for d in $frame_digests; do
    fpos=$(grep -aboE -- "^frame $d\$" "$log" | cut -d: -f1 | awk -v p="$fprev" '$1 > p { print; exit }' || true)
    if [ -z "$fpos" ]; then
      echo "run.sh: the screen pass never delivered 'frame $d' after byte $fprev (the corpus's frames, $frame_expected)" >&2
      exit 1
    fi
    if [ "$fprev" -lt 0 ] && { [ "$fpos" -lt "$opos" ] || [ "$fpos" -gt "$ppos" ]; }; then
      echo "run.sh: 'frame $d' arrived out of order" >&2
      exit 1
    fi
    fprev=$fpos
  done
  if [ "$fprev" -gt "$spos" ]; then
    echo "run.sh: the loop's last frame arrived after the carve's read-back" >&2
    exit 1
  fi
  if [ "$(grep -c '^present ok$' "$log" || true)" -ne 4 ]; then
    echo "run.sh: expected the loop's four presents, one per frame" >&2
    exit 1
  fi
  # The windows' frames (emo-desktop A9.1): the desk pass's own digest
  # of each window's buffer at every present, whole lines, in the
  # corpus's order — the nine of `$win_expected`, never a literal of
  # this file's. The first lies after the window pass's exit and the
  # last before the desk pass's; a frame presented twice is two lines,
  # so the search for each starts past the last; and a window's present
  # says no `present ok` — the count above stays the loop's.
  local wprev wstart wend
  wstart=$(grep -aboF -- 'win 0' "$log" | head -1 | cut -d: -f1)
  wend=$(grep -aboF -- 'desk 0' "$log" | head -1 | cut -d: -f1)
  wprev=$wstart
  for d in $win_digests; do
    fpos=$(grep -aboE -- "^frame $d\$" "$log" | cut -d: -f1 | awk -v p="$wprev" '$1 > p { print; exit }' || true)
    if [ -z "$fpos" ]; then
      echo "run.sh: the desk pass never delivered 'frame $d' after byte $wprev (the corpus's windows, $win_expected)" >&2
      exit 1
    fi
    wprev=$fpos
  done
  if [ "$wprev" -gt "$wend" ]; then
    echo "run.sh: the windows' last frame arrived after the desk pass's exit" >&2
    exit 1
  fi
  # The dock's frames (emo-desktop A10.2): the strip's own digests —
  # none focused, alpha's tile lit, beta's — in the corpus's order,
  # interleaved with the windows' (the search for each starts past the
  # last, seeded past the desk era's first line), the last before the
  # desk pass's exit.
  local dprev dpos dstart
  dstart=$(grep -aboF -- 'desk range 32767 32767' "$log" | head -1 | cut -d: -f1)
  dprev=$dstart
  for d in $dock_digests; do
    dpos=$(grep -aboE -- "^frame $d\$" "$log" | cut -d: -f1 | awk -v p="$dprev" '$1 > p { print; exit }' || true)
    if [ -z "$dpos" ]; then
      echo "run.sh: the desk pass never delivered 'frame $d' after byte $dprev (the corpus's dock, $dock_expected)" >&2
      exit 1
    fi
    dprev=$dpos
  done
  if [ "$dprev" -gt "$wend" ]; then
    echo "run.sh: the dock's last frame arrived after the desk pass's exit" >&2
    exit 1
  fi
  # The cursor plane's line (T8.11): the compositor's one `pointer`
  # line — the hotspot at the display's center, the position the beat's
  # mouse_move named scaled to the mode — after the byte the input pass
  # read and before the window pass began: its order against the pass's
  # own `move` lines is the scheduler's, so it is placed here, not in
  # the list above.
  local qpos bpos wpos
  qpos=$(grep -aboF -- 'pointer 512 384' "$log" | head -1 | cut -d: -f1 || true)
  if [ -z "$qpos" ]; then
    echo "run.sh: the compositor never delivered 'pointer 512 384'" >&2
    exit 1
  fi
  bpos=$(grep -aboF -- 'byte 75' "$log" | head -1 | cut -d: -f1)
  wpos=$(grep -aboF -- 'win 1' "$log" | head -1 | cut -d: -f1)
  if [ "$qpos" -lt "$bpos" ] || [ "$qpos" -gt "$wpos" ]; then
    echo "run.sh: 'pointer 512 384' arrived out of order" >&2
    exit 1
  fi
  if [ "$(grep -c '^pointer ' "$log" || true)" -ne 2 ]; then
    echo "run.sh: expected the plane's one 'pointer' line beside 'pointer ready'" >&2
    exit 1
  fi
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
  # The DMA proof's line, whole: the block the allocator answered at the
  # machine's end was block-aligned (the tail 0000) and named by its
  # kernel alias. The fragments above pin the line's place — its start
  # only, because the screen carve's line (T8.2) ends the same way —
  # this pins the tail.
  if ! grep -qE '^dma 0x[0-9a-f]+0000 ok$' "$log"; then
    echo "run.sh: the dma proof's block was not block-aligned" >&2
    exit 1
  fi
  # The screen carve's line, whole (T8.2): the base is the carve's
  # physical address, asserted in full — stable across builds, unlike
  # the dma block's.
  if ! grep -qE '^screen 0x86c00000 ok$' "$log"; then
    echo "run.sh: the screen carve's line is not the carve's base" >&2
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
echo "run.sh: legacy SBI set_timer ticks: greeting, sv39, proof, fs format, console, gpu, input, pointer, fs restart, user, fs roundtrip, kill, screen, frame, keys, pointer plane, win, comp restart, desk, shell, counter, frames, self-exit"
# The stimecmp transport when it does. The second boot meets the volume
# the first left — two files, the root's and hello's — and formats
# nothing: the mount table came off the disk.
boot 'rv64,sstc=true' sstc '.qemu-sstc.log' 'fs gen 3 files 2' 'fs gen 4 files 2' 0
echo "run.sh: sstc stimecmp ticks: greeting, sv39, proof, fs mount, console, gpu, input, pointer, fs restart, user, fs roundtrip, kill, screen, frame, keys, pointer plane, win, comp restart, desk, shell, counter, frames, self-exit, 1 ecall"
