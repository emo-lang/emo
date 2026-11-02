#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# The ride, not the verification: start.sh boots the machine and hands
# it the terminal — the hand-driven boot of
# docs/how-to-start-emoos.md in one command. run.sh is the golden smoke
# that asserts the serial chain; this one asserts nothing and drives.
# The display leg (T8.8): the machine's screen is a cocoa window — the
# same virtio-gpu and 1024x768 baseline the golden asserts through the
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
# (emo-desktop A7.2): EmoUI's core, the fb backend's core and the first
# frame, from their own trees. They are staged into a registry named for
# the sources' content — the way every gate in the tree stages one — and
# the build reads it through EMO_REGISTRY, which names the one registry
# a build resolves from, so the stub is staged beside them out of the
# compiler's own tree; a change in any of them is a stale user image.

user_elf='hello.elf'
elf='main.elf'

ui_dir='../emo-ui'
fb_dir='../emo-desktop/fb'
syscall_dir='../../stdlib/registry/syscall/0.1.0'
syscall_src="$syscall_dir/package.emo $syscall_dir/syscall.emo"
ui_src="$ui_dir/package.emo $ui_dir/ui.emo $ui_dir/debug.emo"
fb_src="$fb_dir/package.emo $fb_dir/ui_fb.emo $fb_dir/font.emo"
frame_src="$fb_dir/frame/package.emo $fb_dir/frame/ui_fb_frame.emo"

registry() {
  local sum
  # shellcheck disable=SC2086
  sum=$(cat $syscall_src $ui_src $fb_src $frame_src | cksum | awk '{print $1}')
  local reg="$PWD/.emo-build/registry-$sum"
  mkdir -p "$reg/syscall/0.1.0" "$reg/emo/ui/0.1.0" "$reg/emo/ui_fb/0.1.0" \
    "$reg/emo/ui_fb_frame/0.1.0"
  # shellcheck disable=SC2086
  cp $syscall_src "$reg/syscall/0.1.0/"
  # shellcheck disable=SC2086
  cp $ui_src "$reg/emo/ui/0.1.0/"
  # shellcheck disable=SC2086
  cp $fb_src "$reg/emo/ui_fb/0.1.0/"
  # shellcheck disable=SC2086
  cp $frame_src "$reg/emo/ui_fb_frame/0.1.0/"
  printf '%s' "$reg"
}

if [ $# -gt 1 ] || { [ $# -eq 1 ] && [ "$1" != '--fresh' ]; }; then
  echo "usage: $0 [--fresh]" >&2
  echo '  --fresh  re-create the disk before booting (a fresh volume loses its files)' >&2
  exit 2
fi

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
if stale "$user_elf" hello/*.emo hello/package.emo hello/package.lock $syscall_src $ui_src $fb_src $frame_src ||
   stale "$elf" *.emo *.S link.ld "$user_elf"; then
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
  (cd hello && EMO_REGISTRY="$reg" "$emo" build main.emo --target riscv64 --profile user -o "../$user_elf")
  "$emo" build main.emo --target riscv64 -o "$elf"
fi

# The disk is a raw 1 MiB image; the filesystem formats a blank one at
# its first mount and keeps its files across boots. The volume is kept
# between sessions — the files survive the poweroff — and --fresh
# trades it for a blank one.
img='.blk.img'
if [ ! -f "$img" ] || [ "${1:-}" = '--fresh' ]; then
  dd if=/dev/zero of="$img" bs=1048576 count=1 status=none
fi

if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
  echo 'start.sh: qemu-system-riscv64 not found (macOS: brew install qemu)' >&2
  exit 1
fi

echo 'EmoOS: the machine'"'"'s screen is the window that opens; this terminal is the serial console.' >&2
echo '  the boot stops twice for keys on its way to the emo-os> prompt:' >&2
echo '    five keys once the fs mount line has gone by (the console delivery test)' >&2
echo '    one key when "gate 500500 r3 r2" appears (the read proof)' >&2
echo '  type nothing else before the prompt — early bytes surface later and garble the exchange' >&2
echo '  the kill reports on the way are the proof chain working, not trouble' >&2
echo '  poweroff ends the machine; Ctrl-A X kills QEMU' >&2

# -display cocoa: the display leg's window (T8.8); -serial mon:stdio
# keeps the serial-and-monitor mux -nographic used to hold, so the
# console hand-feel is unchanged.
exec qemu-system-riscv64 -machine virt -display cocoa -serial mon:stdio \
  -global virtio-mmio.force-legacy=false \
  -drive file="$img",format=raw,if=none,id=emoos-blk \
  -device virtio-blk-device,drive=emoos-blk \
  -device virtio-gpu-device,xres=1024,yres=768 \
  -device virtio-keyboard-device \
  -kernel "$elf"
