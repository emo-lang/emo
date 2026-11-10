#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# The ride, not the verification: start.sh boots the machine and hands
# it the terminal — the hand-driven boot of
# docs/how-to-start-emoos.md in one command. run.sh is the golden smoke
# that asserts the serial chain; this one asserts nothing and drives.
# The display leg (T8.8): the machine's screen is a cocoa window — the
# same virtio-gpu and 1920x1080 baseline the golden asserts through the
# monitor's screendump, here shown live — while the serial console
# stays the terminal (`-serial mon:stdio`, the mux `-nographic` used
# to keep). The keyboard rides along: without a DeviceID 18 on the
# buses the input service's scan ends loudly, so the ride's boot needs
# the device half of its input stream.
#
# The images are not committed. The user image builds first — the
# kernel's build assembles user.S, which embeds hello.elf, so the ELF
# has to exist before the kernel links — then the kernel. A source
# newer than an image rebuilds both, in that order; a fresh tree with
# both images present boots without the toolchain.
#
# The user image requires the desktop's packages beside the syscall stub
# (emo-desktop A7.2): EmoUI's core, the fb backend's core, the first
# frame with the counter the screen pass runs (A8.3), the window
# shell's windows (A9.1), the desktop shell's dock (A10.2), and the
# window buffer's metal side (A11.1), from their own trees. They are staged into a registry named for the sources' content
# — the way every gate in the tree stages one — and the build reads it
# through EMO_REGISTRY, which names the one registry a build resolves
# from, so the stub is staged beside them out of the compiler's own
# tree; a change in any of them is a stale user image. The apps' corpus
# (emo/ui_apps, A10.3) is staged for the three app programs, which are
# build roots of their own — the boot image execs them by name and no
# longer carries them (A11.1).

user_elf='hello.elf'
elf='main.elf'

ui_dir='../emo-ui'
fb_dir='../emo-desktop/fb'
syscall_dir='../../stdlib/registry/syscall/0.1.0'
syscall_src="$syscall_dir/package.emo $syscall_dir/syscall.emo"
ui_src="$ui_dir/package.emo $ui_dir/ui.emo $ui_dir/debug.emo"
fb_src="$fb_dir/package.emo $fb_dir/ui_fb.emo $fb_dir/raster.emo $fb_dir/face_inter.emo $fb_dir/face_mono.emo $fb_dir/pointer.emo"
frame_src="$fb_dir/frame/package.emo $fb_dir/frame/ui_fb_frame.emo $fb_dir/frame/counter.emo"
win_src="$fb_dir/win/package.emo $fb_dir/win/ui_fb_win.emo"
desktop_src="$fb_dir/desktop/package.emo $fb_dir/desktop/emo_desktop.emo"
apps_src="$fb_dir/apps/package.emo $fb_dir/apps/ui_apps.emo $fb_dir/apps/counter.emo $fb_dir/apps/files.emo $fb_dir/apps/editor.emo"
winbuf_src="$fb_dir/winbuf/package.emo $fb_dir/winbuf/ui_fb_winbuf.emo"
counter_src="$fb_dir/apps/counter/package.emo $fb_dir/apps/counter/main.emo"
files_src="$fb_dir/apps/files/package.emo $fb_dir/apps/files/main.emo"
editor_src="$fb_dir/apps/editor/package.emo $fb_dir/apps/editor/main.emo"
spin_src="$fb_dir/apps/spin/package.emo $fb_dir/apps/spin/main.emo"

registry() {
  local sum
  # shellcheck disable=SC2086
  sum=$(cat $syscall_src $ui_src $fb_src $frame_src $win_src $desktop_src $apps_src $winbuf_src | cksum | awk '{print $1}')
  local reg="$PWD/.emo-build/registry-$sum"
  mkdir -p "$reg/syscall/0.1.0" "$reg/emo/ui/0.1.0" "$reg/emo/ui_fb/0.1.0" \
    "$reg/emo/ui_fb_frame/0.1.0" "$reg/emo/ui_fb_win/0.1.0" "$reg/emo/ui_apps/0.1.0" \
    "$reg/emo/ui_fb_winbuf/0.1.0"
  # shellcheck disable=SC2086
  cp $syscall_src "$reg/syscall/0.1.0/"
  # shellcheck disable=SC2086
  cp $ui_src "$reg/emo/ui/0.1.0/"
  # shellcheck disable=SC2086
  cp $fb_src "$reg/emo/ui_fb/0.1.0/"
  # shellcheck disable=SC2086
  cp $frame_src "$reg/emo/ui_fb_frame/0.1.0/"
  # shellcheck disable=SC2086
  cp $win_src "$reg/emo/ui_fb_win/0.1.0/"
  mkdir -p "$reg/emo_desktop/0.1.0"
  cp $desktop_src "$reg/emo_desktop/0.1.0/"
  # shellcheck disable=SC2086
  cp $apps_src "$reg/emo/ui_apps/0.1.0/"
  # shellcheck disable=SC2086
  cp $winbuf_src "$reg/emo/ui_fb_winbuf/0.1.0/"
  printf '%s' "$reg"
}

if [ $# -gt 2 ]; then
  echo "usage: $0 [--fresh] [--hand]" >&2
  echo '  --fresh  re-create the disk before booting (a fresh volume loses its files)' >&2
  echo '  --hand   skip the auto-ride and drive the proof chain'"'"'s windows by hand' >&2
  exit 2
fi

fresh=no
hand=no
for arg in "$@"; do
  case $arg in
    --fresh) fresh=yes ;;
    --hand) hand=yes ;;
    *) echo "usage: $0 [--fresh] [--hand]" >&2; exit 2 ;;
  esac
done

stale() {
  local img="$1"; shift
  if [ ! -f "$img" ]; then
    return 0
  fi
  local f
  for f in "$@"; do
    if [ -e "$f" ] && [ "$f" -nt "$img" ]; then
      return 0
    fi
  done
  return 1
}

# shellcheck disable=SC2086
if stale "$user_elf" hello/*.emo hello/package.emo hello/package.lock $syscall_src $ui_src $fb_src $frame_src $win_src $desktop_src $apps_src $winbuf_src ||
   stale counter.elf $counter_src $syscall_src $ui_src $fb_src $apps_src $winbuf_src ||
   stale files.elf $files_src $syscall_src $ui_src $fb_src $apps_src $winbuf_src ||
   stale editor.elf $editor_src $syscall_src $ui_src $fb_src $apps_src $winbuf_src ||
   stale spin.elf $spin_src ||
   stale "$elf" *.emo *.S link.ld "$user_elf" counter.elf files.elf editor.elf spin.elf; then
  if command -v emo >/dev/null 2>&1; then
    emo=emo
  else
    emo=''
    dir="$(pwd)"
    while [ "$dir" != / ]; do
      if [ -x "$dir/_build/default/src/emo_cli/emo.exe" ]; then
        emo="$dir/_build/default/src/emo_cli/emo.exe"
        break
      fi
      dir="$(dirname "$dir")"
    done
  fi
  if [ -z "$emo" ]; then
    echo 'start.sh: the images are missing or stale and the compiler is nowhere to find.' >&2
    echo '  Build it once from the repository root (docs/how-to-start-emoos.md):' >&2
    echo '    export PATH="$HOME/.opam/5.5.2/bin:$PATH"' >&2
    echo '    eval "$(opam env --switch=5.5.2 --set-switch)"' >&2
    echo '    dune build src/emo_cli/emo.exe' >&2
    exit 1
  fi
  echo "start.sh: building the images with $emo" >&2
  reg=$(registry)
  here=$PWD
  (cd hello && EMO_REGISTRY="$reg" "$emo" build main.emo --target riscv64 --profile user -o "../$user_elf")
  (cd ../emo-desktop/fb/apps/counter && EMO_REGISTRY="$reg" "$emo" build main.emo --target riscv64 --profile app -o "$here/counter.elf")
  (cd ../emo-desktop/fb/apps/files && EMO_REGISTRY="$reg" "$emo" build main.emo --target riscv64 --profile app -o "$here/files.elf")
  (cd ../emo-desktop/fb/apps/editor && EMO_REGISTRY="$reg" "$emo" build main.emo --target riscv64 --profile app -o "$here/editor.elf")
  (cd ../emo-desktop/fb/apps/spin && EMO_REGISTRY="$reg" "$emo" build main.emo --target riscv64 --profile app -o "$here/spin.elf")
  "$emo" build main.emo --target riscv64 -o "$elf"
fi

# The disk is a raw 4 MiB image; the filesystem formats a blank one at
# its first mount, installs the apps' images on it (emo-desktop A11.1),
# and keeps its files across boots. The volume is kept between sessions
# — the files survive the poweroff — and --fresh trades it for a blank
# one (the next boot installs the images again).
img='.blk.img'
if [ ! -f "$img" ] || [ "$fresh" = yes ]; then
  dd if=/dev/zero of="$img" bs=4194304 count=1 status=none
fi

if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
  echo 'start.sh: qemu-system-riscv64 not found (macOS: brew install qemu)' >&2
  exit 1
fi

# The ride drives itself: the proof chain's windows are fed their bytes
# automatically — the same beats `run.sh` asserts — so the machine
# boots to the desktop hands-free and the terminal becomes the REPL's
# console at the prompt. `--hand` keeps the old ride: the windows listed
# in docs/how-to-start-emoos.md, typed by you.
if [ "$hand" = yes ]; then
  echo 'EmoOS: the machine'"'"'s screen is the window that opens; this terminal is the serial console.' >&2
  echo '  the proof chain stops for keys on its way to the desktop — the windows and' >&2
  echo '  their bytes are listed in docs/how-to-start-emoos.md (driving it by hand)' >&2
  echo '  until the desktop composes, the screen holds the boot'"'"'s own gradient flush —' >&2
  echo '  the banded colors are the machine waiting, not a fault' >&2
  echo '  the kill reports on the way are the proof chain working, not trouble' >&2
  echo '  poweroff ends the machine; Ctrl-A X kills QEMU' >&2
  exec qemu-system-riscv64 -machine virt -display cocoa -serial mon:stdio \
    -global virtio-mmio.force-legacy=false \
    -drive file="$img",format=raw,if=none,id=emoos-blk \
    -device virtio-blk-device,drive=emoos-blk \
    -device virtio-gpu-device,xres=1920,yres=1080 \
    -device virtio-keyboard-device \
    -device virtio-tablet-device \
    -kernel "$elf"
fi

echo 'EmoOS: the machine'"'"'s screen is the window that opens; the boot drives itself to' >&2
echo '  the desktop — the proof chain'"'"'s windows are fed automatically. At the prompt' >&2
echo '  this terminal is the REPL'"'"'s console: poweroff ends the machine, Ctrl-A X kills QEMU.' >&2

# The serial rides a FIFO so the ride's feeder and, after the prompt,
# the terminal relay both write it; the serial's bytes land in
# .ride.log for the feeder's greps (the file, not a tee — a tee's block
# buffering would lag the greps) and `tail -f` shows them live on the
# terminal. The pointer beat rides QMP's input-send-event (the absolute
# report the cocoa mouse also delivers, here without the grab).
log='.ride.log'
fifo=$(mktemp -u /tmp/emoos-serial.XXXXXX)
mkfifo "$fifo"
qmp_sock=$(mktemp -u /tmp/emoos-qmp.XXXXXX)
qemu-system-riscv64 -machine virt -display cocoa -serial mon:stdio \
  -global virtio-mmio.force-legacy=false \
  -drive file="$img",format=raw,if=none,id=emoos-blk \
  -device virtio-blk-device,drive=emoos-blk \
  -device virtio-gpu-device,xres=1920,yres=1080 \
  -device virtio-keyboard-device \
  -device virtio-tablet-device \
  -qmp unix:"$qmp_sock",server,nowait \
  -kernel "$elf" <"$fifo" >"$log" 2>&1 &
qemu_pid=$!
tail -f "$log" -n +1 >&2 &
tail_pid=$!
trap 'kill "$qemu_pid" "$tail_pid" 2>/dev/null || true' EXIT
exec 3>"$fifo"

ride_wait() {
  local pat="$1" n=0
  while [ "$n" -lt 400 ]; do
    if grep -qF -- "$pat" "$log" 2>/dev/null; then
      return 0
    fi
    kill -0 "$qemu_pid" 2>/dev/null || return 1
    sleep 0.25
    n=$((n + 1))
  done
  return 1
}

ride_type() {
  printf '%s' "$1" >&3
}

ride_move() {
  python3 - "$qmp_sock" <<'PYEOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": [
    {"type": "abs", "data": {"axis": "x", "value": 16384}},
    {"type": "abs", "data": {"axis": "y", "value": 16384}}]}}) + "\n")
f.flush()
json.loads(f.readline())
s.close()
PYEOF
}

# The beats, run.sh's own feeding discipline: each window waited for on
# the log, its bytes fed when it asks. A beat that never comes (the
# machine wedged, or a beat the tree outgrew) is not the ride's death —
# the relay starts anyway and the hand-driven sequence takes over.
ride() {
  ride_wait '4999999950000000' && ride_type 'abcde' || return 1
  ride_wait 'gate 500500 r3 r2' && ride_type 'X' || return 1
  ride_wait 'present ok' && ride_type 'a' || return 1
  sleep 1 && ride_type 'a'
  sleep 1 && ride_type 'b'
  sleep 1 && ride_type 'q'
  ride_wait 'keys?' && { ride_type 'q'; sleep 1; ride_type 'K'; } || return 1
  ride_wait 'byte 75' || return 1
  ride_move
  ride_wait 'pointer 960 540' || return 1
  ride_wait 'comp 16 32' || return 1
  ride_wait 'win 0' && ride_type 'c' || return 1
  ride_wait 'addr 0x20000000' && ride_type 'c' || return 1
  sleep 5 && ride_type 'c'
  ride_wait 'client back' && ride_type 'z' || return 1
  sleep 3
  ride_wait 'desk range 32767 32767' || return 1
  sleep 3 && ride_type 'q'
  ride_wait 'desk 0' || return 1
  ride_wait 'emo-os>'
}

if ride; then
  echo 'EmoOS: the desktop is up — this terminal is the REPL'"'"'s console now.' >&2
  echo '  poweroff ends the machine; Ctrl-D or Ctrl-A X also quit.' >&2
else
  echo 'EmoOS: the auto-ride stalled — drive the remaining windows by hand;' >&2
  echo '  docs/how-to-start-emoos.md lists them in order.' >&2
fi

# The hand-off: the terminal's bytes ride to the machine byte for byte
# (`cat`, not a `read -n1` loop — the read eats the newline that ends
# the REPL's line, and a poweroff without its newline never runs); the
# feeder is done, fd 3 is the terminal's alone from here.
cat >&3
kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
