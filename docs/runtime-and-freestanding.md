# Runtime and freestanding — two terms, two axes

Emo's docs use "freestanding", "runtime", and "host runtime" repeatedly —
the `riscv64` target, the native backend, the proposed self-contained
backend. They describe two different things: **freestanding is about the
environment a program runs in; runtime is about the code that supports it
while it runs.** This note pins both down and maps them onto Emo's
targets.

## Freestanding

The word comes from the C and C++ standards, which define two execution
environments:

| | Hosted | Freestanding |
| --- | --- | --- |
| Operating system | present | none, or a minimal firmware layer |
| Standard library | the full C library (stdio, stdlib, string, files, threads, …) | only what the compiler itself needs (`stddef.h`, `stdint.h`, `limits.h`, `stdarg.h`, `stdbool.h`, …) |
| Entry point | the standard `main`, returning to the OS | whatever the implementation defines (`_start`, a boot stub) |
| Memory | `malloc` and friends from libc | you provide the allocator |
| I/O | `printf`, `fopen`, sockets, … | you provide it (MMIO registers, or a firmware call) |
| Compiler flag | default | `-ffreestanding` |

Freestanding means **no OS and no standard library: you supply the
ground.** It is the environment of kernels, embedded systems, firmware,
bootloaders, and bare-metal real-time code.

It is not exactly "bare metal". Emo's `riscv64` target has two boot
profiles: profile A (the default) is hosted by OpenSBI and runs in
S-mode, so a firmware layer exists but no OS or libc; profile B
(`-bios none`, M-mode, its own UART driver) is true bare metal. Both are
freestanding relative to the operating system and the C library — the
difference is whether a firmware layer sits underneath.

In Emo (`plan/step-22-riscv64.md`), `riscv64` is the freestanding
target: no OS, no libc, no default runtime; the allocator, GC, and
scheduler are replaceable components; `core` is the only library layer
kernel code may use; `peek`/`poke` are the explicitly dangerous memory
primitives. Its `println` does not call libc — it makes an SBI `ecall`
into the firmware's console.

## Runtime

A language's **runtime** is the code and data structures that support a
program while it runs — what the compiler assumes already exists and
calls into. It is not the logic the user wrote; it is the machinery that
makes that logic work. Depending on the language it includes some of:

- **memory management** — an allocator, a garbage collector;
- **value representation** — boxing and unboxing, type-tag checks,
  string operations;
- **dispatch** — method tables and vtables, dynamic type tests;
- **concurrency** — a scheduler, threads or processes, mailboxes;
- **exceptions** — throw and unwind;
- **arithmetic support** — bignums, overflow checks;
- **startup and teardown** — entry, initialization, exit;
- **OS interaction** — often overlapping the standard library.

Compiler versus runtime: the compiler translates source to machine code;
the runtime is linked into the output and runs alongside it. Standard
library versus runtime is a blurrier line — `println` is a standard
library *surface*, while the scheduler and collector it leans on are
*runtime*. The standard library is the face a user sees; the runtime is
the machine behind it.

"Runtime" also carries a few other senses worth keeping apart:

1. **Language runtime** — the sense above.
2. **Host runtime** — the runtime of the *host language* an
   implementation borrows. Emo's shipped native backend emits OCaml and
   links the **OCaml runtime**, so every Emo binary carries OCaml's
   collector and value model; that is a host runtime.
3. **Cloud / execution runtime** — a "Lambda runtime", a "JVM runtime":
   the environment a program is run in, not the language's own machinery.
4. **Runtime versus compile time** — runtime errors versus compile-time
   errors, runtime types versus static types. A different axis.

In Emo, the runtime layer is `src/emo_eval` (the evaluator),
`src/emo_runtime` (native boxing, builtins, dispatch helpers), and
`src/emo_sched` (the process scheduler). The README states that the
runtime "ships inside the binary": the scheduler and networking stack
are libraries of the backend, so a compiled program carries its runtime
with it, with no interpreter and no runtime download. A freestanding
target has **no host runtime** — it carries its own, with its own
allocator (step 22's bump allocator, "GC deferred").

Why the runtime matters to the GC, FFI, and HPC discussions: the runtime
owns **value representation, memory management, and scheduling**. "No
GC" and "seamless C FFI" are, underneath, rewrites of that layer — how a
value is laid out (boxed, tagged, address-stable), who reclaims memory
(tracing GC, reference counting, arenas), and how C enters (the ABI, the
root-scanning problem). It is why the proposed self-contained backend's
cost sits in the runtime, not in code generation.

## The two axes, applied to Emo

Crossing the two axes names the targets precisely:

| | Borrowed host runtime | Own runtime |
| --- | --- | --- |
| **Hosted** | the shipped native backend (emits OCaml, links the OCaml runtime) | the proposed self-contained backend (`plan/step-23-hosted-native-ffi.md`) |
| **Freestanding** | — (not a useful combination) | the `riscv64` target (`plan/step-22-riscv64.md`) |

Read that way, "a freestanding target" and "a self-contained runtime" are
statements about different axes: the first about the environment an image
boots into, the second about whose machinery carries the program.

## References

- `docs/native-backend.md` — the shipped native backend, its OCaml
  emission and its C FFI.
- `plan/step-22-riscv64.md` — the freestanding target, its value model
  and boot profiles.
- `plan/step-23-hosted-native-ffi.md` — the proposed self-contained
  hosted backend.
- `README.md`, "Native Builds" — the runtime-ships-inside-the-binary
  statement.
