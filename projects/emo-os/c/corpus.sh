#!/usr/bin/env bash
# The package corpus and its CI (T4.4): build the sysroot, then every
# port the corpus carries, and report what each needs and produces.
# The metal legs (dash, uutils) are the tracker's records; this is the
# build half a CI runs on every change.
set -euo pipefail
cd "$(dirname "$0")"
here=$PWD
boot=$here/..

echo "corpus: the sysroot (musl 1.2.6 + the T1 gate layer)"
env EMO_CC="${EMO_CC:-riscv64-elf-gcc}" bash "$here/musl-port/build.sh" >/dev/null
echo "  builds: musl-port/sysroot/lib/libc.a"

echo "corpus: dash 0.5.12 (autotools configure + make)"
env EMO_CC="${EMO_CC:-riscv64-elf-gcc}" bash "$here/dash-port/build.sh" >/dev/null
echo "  builds: dash.elf $(wc -c < "$boot/dash.elf") bytes; runs on metal (T4.1)"

echo "corpus: uutils (T4.2; the sysroot wrapper, no host build system)"
env EMO_CC="${EMO_CC:-riscv64-elf-gcc}" bash "$here/utils/build.sh" >/dev/null
echo "  builds: uutils.elf $(wc -c < "$boot/uutils.elf") bytes; runs on metal (T4.2)"

echo "corpus: the build-system probe (T4.3: make, pkg-config, CMake)"
bash "$here/build-support/probe.sh"
echo "  builds: probe ELFs; not booted (the linker is the metal ports' own)"

echo "corpus ok"
