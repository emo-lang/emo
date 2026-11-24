# The TCC 0.9.28rc vendor

`third_party/tcc/` is TCC's `mob` branch at commit
`e9e9e7f6236895a32c5e905aada486bab6671e95`, unmodified.

- Source: <https://repo.or.cz/tinycc.git>, branch `mob`; the release
  line is 0.9.28rc (see `third_party/tcc/VERSION`).
- License: LGPL-2.1; see `third_party/tcc/COPYING` and `RELICENSING`.
- Why `mob`: the 0.9.27 release has no riscv64 backend; `mob` carries
  `riscv64-gen.c`, `riscv64-link.c` and `riscv64-asm.c`.

The tree sits at the repository root beside `third_party/dash`; TCC's
build writes `config.mak` and its objects into the source directory, so
the overlay under `projects/emo-os/c/tcc-port/` copies the tree into a
temporary directory and builds there, leaving the vendor pristine. The
overlay's `build.sh` installs `tcc.elf`, `tcc-libtcc1.a`, `tcc-crt0.o`,
`tcc-libc.a` and the acceptance source `tcc-test.c` into the boot tree.

`tcc-crt0.o` is the port's own entry: TCC's linker does not read the
GNU link script, so it clears from the linker's `_edata` to its `_end`.
`tcc-libc.a` is the machine's T1 C door runtime (`emo_posix.c` +
`emo_syscall.c`) plus the two musl-crt hooks (`mini.c`), not the 502 KB
musl archive: TCC holds the archive whole while linking, and that peak
crosses the spawned process's arena. The musl archive waits for the
arena's later rung.
