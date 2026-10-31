#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# The ride, not the verification: start.sh boots the machine and hands
# it the terminal — the hand-driven boot of
# docs/how-to-start-emoos.md in one command. run.sh is the golden smoke
# that asserts the serial chain; this one asserts nothing and drives.
#
# The images are not committed. The user image builds first — the
# kernel's build assembles user.S, which embeds hello.elf, so the ELF
# has to exist before the kernel links — then the kernel. A source
# newer than an image rebuilds both, in that order; a fresh tree with
# both images present boots without the toolchain.

user_elf='hello.elf'
elf='main.elf'

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

if stale "$user_elf" hello/*.emo hello/package.emo hello/package.lock ||
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
  (cd hello && "$emo" build main.emo --target riscv64 --profile user -o "../$user_elf")
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

echo 'EmoOS: the serial console is this terminal.' >&2
echo '  the boot stops twice for keys on its way to the emo-os> prompt:' >&2
echo '    five keys once the fs mount line has gone by (the console delivery test)' >&2
echo '    one key when "gate 500500 r3 r2" appears (the read proof)' >&2
echo '  type nothing else before the prompt — early bytes surface later and garble the exchange' >&2
echo '  the kill reports on the way are the proof chain working, not trouble' >&2
echo '  poweroff ends the machine; Ctrl-A X kills QEMU' >&2

exec qemu-system-riscv64 -machine virt -nographic \
  -global virtio-mmio.force-legacy=false \
  -drive file="$img",format=raw,if=none,id=emoos-blk \
  -device virtio-blk-device,drive=emoos-blk \
  -kernel "$elf"
