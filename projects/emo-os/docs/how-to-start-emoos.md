# How to start EmoOS

The steps from a clean checkout to the machine's prompt, and the
commands the prompt answers. The machine itself is the README's
subject and the design notes' ([`shell.md`](shell.md),
[`ui.md`](ui.md), [`fs.md`](fs.md), [`sv39.md`](sv39.md)); this page
is only how to drive it.

Chinese translation: [`how-to-start-emoos.zh-CN.md`](how-to-start-emoos.zh-CN.md).

## Prerequisites

- **`qemu-system-riscv64`** — QEMU's RISC-V system emulator. On macOS
  the Homebrew `qemu` formula carries it; on Linux the distribution's
  `qemu-system-misc` (or equivalent) does.
- **OCaml + dune** — to build the compiler once. The repository pins
  the opam switch `5.5.2`.

The compiler is one self-contained binary. From the repository root:

```console
$ export PATH="$HOME/.opam/5.5.2/bin:$PATH"
$ eval "$(opam env --switch=5.5.2 --set-switch)"
$ dune build src/emo_cli/emo.exe
```

The binary lands at `_build/default/src/emo_cli/emo.exe`; the steps
below call it by path. Put it on your `PATH` if you prefer the
README's shorter `emo` spelling.

## The two images

EmoOS is two Emo programs built by the one compiler: the user image —
the shell and the machine's program live in it — and the kernel image,
which embeds the user ELF at its own build. From `projects/emo-os/`:

```console
$ (cd hello && ../../_build/default/src/emo_cli/emo.exe build main.emo \
     --target riscv64 --profile user -o ../hello.elf)
$ ../../_build/default/src/emo_cli/emo.exe build main.emo --target riscv64 \
     -o main.elf
```

The user image builds first: the kernel's build assembles `user.S`,
which embeds `hello.elf` — the ELF has to exist before the kernel
links. After any change to `hello/` or to the kernel's own modules,
rebuild both, in that order.

## The golden smoke

```console
$ ./run.sh
```

`run.sh` is the verification, not the ride. It zeroes the disk image
and boots the machine twice — the first boot meets a blank disk and
formats it, the second mounts the volume the first left, so the two
boots are one story — the first with the SBI `set_timer` fallback
driving the tick, the second with the `stimecmp` transport. Each boot
runs the whole serial chain (bring-up, the proofs, the shell exchange
starting the machine's program, the filesystem roundtrip, the exit
route) and asserts every line's presence and order; a missing or
misordered line fails the run. Three consecutive runs byte-identical
is the bar the tracker's tasks are held to.

## Driving it by hand

The disk is a raw 1 MiB image. The filesystem formats a blank one at
its first mount and keeps its files across boots, so create it once
and re-create it whenever a fresh volume is wanted:

```console
$ dd if=/dev/zero of=.blk.img bs=1048576 count=1
$ qemu-system-riscv64 -machine virt -nographic \
    -global virtio-mmio.force-legacy=false \
    -drive file=.blk.img,format=raw,if=none,id=emoos-blk \
    -device virtio-blk-device,drive=emoos-blk \
    -kernel main.elf
```

The serial console is the terminal. OpenSBI's banner goes by, the
kernel boots paged on the table it built (the `sv39 8 0x…` line), the
block device and the filesystem report — and the chain pauses once:
**the read proof blocks on the console until a byte exists, so type
any key when the `gate 500500 r3 r2` line appears** (`echo 88` is the
answer to an X). The four kill reports that follow are the proof chain
doing its job — misbehaving passes dying alone (one of them by its own
allocator's exhaustion) while the machine goes on — not trouble. Then
the prompt:

    emo>

Bytes typed before the prompt are lost: OpenSBI holds the UART first,
and the console service's reader is not up yet.

The prompt answers eight commands, lowercase and exact:

| Command | Effect |
| --- | --- |
| `help` | names the eight |
| `echo TEXT` | prints the text back |
| `ls` | lists the volume's files, one per line |
| `cat NAME` | prints a file's bytes |
| `write NAME TEXT` | makes the file the text's bytes; quiet on success |
| `rm NAME` | removes the file; quiet on success |
| `counter` | starts the machine's program — the console renderer: the frames paint on the console, `a`/`b` add and subtract, `q` returns to the prompt |
| `poweroff` | ends the machine — the exit route's `dma` line and frames account, then QEMU exits on its own |

`write`/`ls`/`cat`/`rm` are the filesystem's roundtrip — the files
are on the disk and survive the poweroff. A session that ends
otherwise: **Ctrl-A X** kills QEMU.

The default QEMU CPU has no Sstc to delegate, so the tick rides the
SBI `set_timer` fallback — nothing to configure; `run.sh` is what
pins both timer transports.

## Where to read on

- [`docs/TASKS.md`](TASKS.md) — the tracker: what the machine does, task by task, each with its pins.
- [`docs/shell.md`](shell.md) — the REPL: the line, the commands, the strictness the surface carries.
- [`docs/ui.md`](ui.md) — the console renderer the `counter` command starts.
- [`docs/fs.md`](fs.md) — the filesystem: the disk's layout, the restart semantics.
- [`docs/sv39.md`](sv39.md) — the address spaces, the trampoline, the page-fault kill.
- [`docs/syscalls.md`](syscalls.md) — the gate: the verbs every byte above rides.
