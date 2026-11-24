#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# The boot tree always carries the TCC slots (T4.5): the kernel's
# user.S includes them whatever the mode, so a mode that does not build
# the compiler leaves the zero-length placeholders the install skips.
for tcc in tcc.elf tcc-libtcc1.a tcc-crt0.o tcc-libc.a tcc-test.c; do
  : > "$PWD/../$tcc"
done

# The musl body's proof image (T2.2): the same `chello.elf` slot, the
# port's crt and body instead of the C door's test. The default build
# stays the T1 program; the tracker's metal beat sets EMO_MUSL=1.
if [ "${EMO_MUSL:-0}" = 1 ]; then
  here=$PWD
  bash "$here/musl-port/build.sh"
  cp "$here/../muslhello.elf" "$here/../chello.elf"
  exit 0
fi

# The underlying cross compiler, read before EMO_CC becomes the sysroot
# wrapper: in one command's assignments bash applies them left to right,
# so a later `${EMO_CC}` would see the wrapper and exec itself forever.
emos_cc=${EMO_CROSS_CC:-${EMO_CC:-riscv64-elf-gcc}}
if [ "$emos_cc" = "$PWD/musl-port/sysroot/bin/riscv64-emoos-gcc" ]; then
  emos_cc=riscv64-elf-gcc
fi
if ! command -v "$emos_cc" >/dev/null 2>&1; then
  echo "c/build.sh: $emos_cc not found (macOS: brew install riscv64-elf-gcc)" >&2
  exit 1
fi

# The boot's foreground (T3.2/T4.1): the emosh C shell or dash, the
# first real POSIX program. The mode names the image the build carries;
# user.S embeds both slots, and an empty one is skipped at install.
if [ "${EMO_TCC:-0}" = 1 ]; then
  : > "$PWD/../emosh.elf"
  : > "$PWD/../dash.elf"
  : > "$PWD/../uutils.elf"
  EMO_CROSS_CC="$emos_cc" bash "$PWD/tcc-port/build.sh"
elif [ "${EMO_UTILS:-0}" = 1 ]; then
  : > "$PWD/../emosh.elf"
  : > "$PWD/../dash.elf"
  EMO_CROSS_CC="$emos_cc" bash "$PWD/utils/build.sh"
elif [ "${EMO_DASH:-0}" = 1 ]; then
  : > "$PWD/../emosh.elf"
  : > "$PWD/../uutils.elf"
  EMO_CROSS_CC="$emos_cc" bash "$PWD/dash-port/build.sh"
else
  : > "$PWD/../dash.elf"
  : > "$PWD/../uutils.elf"
  if [ "${EMO_SHELL:-0}" = 1 ]; then
    here=$PWD
    root=$(cd "$here/../../.." && pwd)
    sysroot="$here/musl-port/sysroot/bin/riscv64-emoos-gcc"
    emo="$root/_build/default/src/emo_cli/emo.exe"
    if [ ! -x "$emo" ]; then
      echo "c/build.sh: the Emo compiler is missing: $emo" >&2
      exit 1
    fi
    (cd "$root/projects/emo-shell" && \
      EMO_CC="$sysroot" EMO_CROSS_CC="$emos_cc" \
      "$emo" build main.emo --target c -o "$here/../emosh.elf")
  else
    # The kernel's user.S embeds emosh.elf whatever the boot; a build
    # without the shell writes the empty placeholder and the kernel skips
    # its install, so the golden keeps the Emo desktop.
    : > "$PWD/../emosh.elf"
  fi
fi

# The C door's test image is built whatever the boot: the first-run
# volume installs it like every app, and T3.4 drives its argv/envp
# probe from the launcher and the shell.
"$emos_cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -msmall-data-limit=0 -ffreestanding -fno-builtin -fno-pic \
  -fno-stack-protector -nostdlib -Wl,--build-id=none \
  -T chello.ld -o ../chello.elf crt0.s fork.s hello.c emo_posix.c \
  emo_syscall.c

echo "built ../chello.elf"
