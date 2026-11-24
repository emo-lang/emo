# The musl 1.2.6 vendor

`third_party/musl/` is musl 1.2.6, unmodified.

- Source: <https://musl.libc.org/releases/musl-1.2.6.tar.gz>
- SHA-256: `d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a`
- Release: 2026-03-20
- License: MIT; see `third_party/musl/COPYRIGHT`.

The tree sits at the repository root, not under `projects/emo-os/c/`:
the Emo package build assembles every `.S` under its project tree, and
musl's forty `.S` files (the fenv and arch string routines) would be
assembled beside the kernel. The overlay under
`projects/emo-os/c/musl-port/` carries no assembly.

`c/musl-port/` is EmoOS's overlay. A ported file keeps its musl path
under this directory and replaces the pristine tree's file when the
build's include or source list chooses the overlay first; the tree
stays the base an upstream diff runs against. The first overlay file
is `arch/riscv64/syscall_arch.h`, the gate's ecall stubs (T2.1); the
musl `src/` files that need the gate's verbs are the T2.2 work.

The Linux syscall numbers in
`third_party/musl/arch/riscv64/bits/syscall.h.in` are not EmoOS's ABI.
The port's `bits/syscall.h` (T2.2) names the gate verbs; the kernel
never sees a Linux syscall number. The build compiles a manifest of
musl objects, not the tree whole: the manifest is the "by need"
record, and the tree is its source.
