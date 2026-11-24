#!/usr/bin/env bash
# The musl body's static build (EmoOS plan B, T2.2): the port's crt,
# TLS and gate shims beside the vendored sources the hello pulls. The
# musl tree is pristine at the repository root; this directory is the
# overlay, and the build compiles the manifest below, not the tree
# whole. Output: `projects/emo-os/muslhello.elf`.

set -euo pipefail
cd "$(dirname "$0")"

emos_cc=${EMO_CC:-riscv64-elf-gcc}
if ! command -v "$emos_cc" >/dev/null 2>&1; then
  echo "musl-port/build.sh: $emos_cc not found" >&2
  exit 1
fi

musl=../../../../third_party/musl
build=$PWD/.build
mkdir -p "$build/include/bits" "$build/obj"

sed -f "$musl/tools/mkalltypes.sed" \
  "$musl/arch/riscv64/bits/alltypes.h.in" \
  "$musl/include/alltypes.h.in" > "$build/include/bits/alltypes.h"
cp "$musl/arch/riscv64/bits/syscall.h.in" "$build/include/bits/syscall.h"
sed -n -e s/__NR_/SYS_/p < "$musl/arch/riscv64/bits/syscall.h.in" \
  >> "$build/include/bits/syscall.h"

cflags=(
  -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax
  -msmall-data-limit=0 -std=c99 -ffreestanding -fno-builtin -fno-pic
  -fno-stack-protector -nostdinc -Os -ffunction-sections -fdata-sections
  -D_XOPEN_SOURCE=700
  -I"$build/include"
  -I"$PWD/src/internal"
  -I"$musl/arch/riscv64" -I"$musl/arch/generic"
  -I"$musl/src/include" -I"$musl/src/internal" -I"$musl/include"
)

objects=()
compile() {
  local src=$1
  local name
  case "$src" in
    "$musl"/*) name=${src#"$musl"/} ;;
    *) name=port_$(basename "$src") ;;
  esac
  name=${name//\//_}
  name=${name%.*}
  local obj="$build/obj/$name.o"
  "$emos_cc" "${cflags[@]}" -c "$src" -o "$obj"
  objects+=("$obj")
}

compile crt0.s
compile tls.c
compile gate.c
compile stdio.c
compile hello.c
compile ../emo_syscall.c

for src in "$musl"/src/string/*.c; do compile "$src"; done

for src in \
  "$musl"/src/stdio/printf.c \
  "$musl"/src/stdio/vfprintf.c \
  "$musl"/src/stdio/fwrite.c \
  "$musl"/src/stdio/__towrite.c \
  "$musl"/src/stdio/__overflow.c \
  "$musl"/src/stdio/fflush.c \
  "$musl"/src/stdio/stdout.c \
  "$musl"/src/stdio/ofl.c; do
  compile "$src"
done

for src in "$musl"/src/malloc/mallocng/*.c; do compile "$src"; done
for src in \
  "$musl"/src/malloc/lite_malloc.c \
  "$musl"/src/malloc/free.c \
  "$musl"/src/malloc/realloc.c; do
  compile "$src"
done

for src in \
  "$musl"/src/env/getenv.c \
  "$musl"/src/env/setenv.c \
  "$musl"/src/env/putenv.c \
  "$musl"/src/env/unsetenv.c \
  "$musl"/src/env/__environ.c \
  "$musl"/src/errno/__errno_location.c \
  "$musl"/src/errno/strerror.c \
  "$musl"/src/internal/libc.c \
  "$musl"/src/internal/floatscan.c \
  "$musl"/src/internal/intscan.c \
  "$musl"/src/internal/shgetc.c \
  "$musl"/src/ctype/__ctype_get_mb_cur_max.c \
  "$musl"/src/locale/__lctrans.c \
  "$musl"/src/locale/c_locale.c \
  "$musl"/src/multibyte/wctomb.c \
  "$musl"/src/multibyte/wcrtomb.c \
  "$musl"/src/math/frexpl.c \
  "$musl"/src/math/scalbnl.c \
  "$musl"/src/math/scalbn.c \
  "$musl"/src/math/__fpclassifyl.c \
  "$musl"/src/math/__signbitl.c \
  "$musl"/src/math/fabs.c \
  "$musl"/src/math/fabsl.c; do
  compile "$src"
done

"$emos_cc" -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax \
  -nostdlib -T ../chello.ld -Wl,--gc-sections \
  -o ../../muslhello.elf "${objects[@]}" -lgcc

echo "built ../../muslhello.elf"
