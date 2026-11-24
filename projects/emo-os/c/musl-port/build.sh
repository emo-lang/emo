#!/usr/bin/env bash
# The musl body's sysroot (EmoOS plan B, T2.2/T2.3): the port's crt,
# TLS and gate shims beside the vendored sources the library pulls. The
# musl tree is pristine at the repository root; this directory is the
# overlay, and the build compiles the manifest below, not the tree
# whole. It installs the headers, `libc.a`, the crt, the image's link
# script and `riscv64-emoos-gcc` under `sysroot/`, then builds the
# static hello through that wrapper.

set -euo pipefail
cd "$(dirname "$0")"

emos_cc=${EMO_CC:-riscv64-elf-gcc}
emos_ar=${EMO_AR:-riscv64-elf-ar}
if ! command -v "$emos_cc" >/dev/null 2>&1; then
  echo "musl-port/build.sh: $emos_cc not found" >&2
  exit 1
fi
if ! command -v "$emos_ar" >/dev/null 2>&1; then
  echo "musl-port/build.sh: $emos_ar not found" >&2
  exit 1
fi

musl=../../../../third_party/musl
build=$PWD/.build
sysroot=$PWD/sysroot
mkdir -p "$build/include/bits" "$build/obj" \
  "$sysroot/include/bits" "$sysroot/lib" "$sysroot/bin"

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

lib_objects=()
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
  lib_objects+=("$obj")
}

compile tls.c
compile gate.c
compile stdio.c
compile ../emo_syscall.c

# The T1 C door's gate functions ride under the musl headers (T3.1):
# its fd/path/process/pipe/signal layer, with the names musl's body
# already owns renamed out of the way. The bridge supplies musl's
# `DIR`, execvp, termios, calloc/exit and the runtime's unused extras.
"$emos_cc" "${cflags[@]}" \
  -Dmalloc=emo_t1_malloc -Dfree=emo_t1_free -Drealloc=emo_t1_realloc \
  -Dmmap=emo_t1_mmap -Dmunmap=emo_t1_munmap -Dmprotect=emo_t1_mprotect \
  -Dbrk=emo_t1_brk -Dsbrk=emo_t1_sbrk \
  -Dgetenv=emo_t1_getenv -Dsetenv=emo_t1_setenv \
  -Dunsetenv=emo_t1_unsetenv -Denviron=emo_t1_environ \
  -Dstat=emo_t1_stat -Dfstat=emo_t1_fstat \
  -Dopendir=emo_t1_opendir -Dreaddir=emo_t1_readdir \
  -Dclosedir=emo_t1_closedir -Dexit=emo_t1_exit \
  -c ../emo_posix.c -o "$build/obj/port_emo_posix.o"
lib_objects+=("$build/obj/port_emo_posix.o")
"$emos_cc" "${cflags[@]}" -c ../fork.s -o "$build/obj/port_fork.o"
lib_objects+=("$build/obj/port_fork.o")
compile posix_bridge.c

for src in "$musl"/src/string/*.c; do compile "$src"; done

for src in \
  "$musl"/src/stdio/printf.c \
  "$musl"/src/stdio/vfprintf.c \
  "$musl"/src/stdio/fwrite.c \
  "$musl"/src/stdio/__towrite.c \
  "$musl"/src/stdio/__overflow.c \
  "$musl"/src/stdio/fflush.c \
  "$musl"/src/stdio/stdout.c \
  "$musl"/src/stdio/ofl.c \
  "$musl"/src/stdio/puts.c \
  "$musl"/src/stdio/fputs.c \
  "$musl"/src/stdio/putc_unlocked.c \
  "$musl"/src/stdio/fprintf.c \
  "$musl"/src/stdio/snprintf.c \
  "$musl"/src/stdio/vsnprintf.c \
  "$musl"/src/stdio/fclose.c \
  "$musl"/src/stdio/fputc.c \
  "$musl"/src/stdio/setvbuf.c \
  "$musl"/src/stdio/open_memstream.c \
  "$musl"/src/stdio/ofl_add.c \
  "$musl"/src/stdio/stderr.c; do
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
  "$musl"/src/math/fabsl.c \
  "$musl"/src/stdlib/qsort.c \
  "$musl"/src/stdlib/qsort_nr.c; do
  compile "$src"
done

libc_new="$build/libc-$$.a"
"$emos_ar" rcs "$libc_new" "${lib_objects[@]}"
cp "$libc_new" "$build/libc.a"
"$emos_cc" "${cflags[@]}" -c crt0.s -o "$build/obj/port_crt0.o"

cp -R "$musl/include/." "$sysroot/include/"
cp "$musl"/arch/generic/bits/*.h "$sysroot/include/bits/"
cp "$musl"/arch/riscv64/bits/*.h "$sysroot/include/bits/"
cp "$build/include/bits/alltypes.h" "$sysroot/include/bits/"
cp "$build/include/bits/syscall.h" "$sysroot/include/bits/"
cp "$build/libc.a" "$sysroot/lib/libc.a"
cp "$build/obj/port_crt0.o" "$sysroot/lib/crt0.o"
cp ../chello.ld "$sysroot/lib/emo.ld"
cp riscv64-emoos-gcc.in "$sysroot/bin/riscv64-emoos-gcc"
chmod +x "$sysroot/bin/riscv64-emoos-gcc"

prog=${EMO_PROG:-hello.c}
EMO_CROSS_CC="$emos_cc" "$sysroot/bin/riscv64-emoos-gcc" "$prog" \
  -o ../../muslhello.elf

echo "built ../../muslhello.elf from $prog through $sysroot/bin/riscv64-emoos-gcc"
