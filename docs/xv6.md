# Emo and an xv6-class kernel — a feasibility assessment

Written 2026-10-06. A technical feasibility assessment, not decided
design; project-state claims reflect the repository as of that date.

The question: **is it theoretically feasible to build an xv6-class
kernel in Emo — judging only the language design (syntax and semantics)
and the compilation architecture, setting development effort aside?**

## The short answer

**Feasible, with a precise boundary: not pure Emo.** The useful framing
is to split xv6 in two:

> **xv6 = a C half + an assembly half.** (`entry.S`, `trampoline.S`,
> `kernelvec.S`, `switch.S`, `start.c`, plus `riscv.h`'s inline-asm CSR
> helpers, `volatile` MMIO, and `__sync` spinlocks.)

The real question is therefore: **can Emo replace the C half while
keeping the assembly half?** Theoretically yes — provided the C half's
needs (raw addresses, bit-fields, unions, `volatile`, atomics) have an
outlet. Emo routes them through `Int64` + `peek`/`poke` + `Bytes` + an
assembly/C shim. The cost is that the type system goes blind exactly in
that half.

## Requirement by requirement

| What xv6 needs | Emo today | Theoretically reachable by |
| --- | --- | --- |
| Bare-metal boot, linker script, fixed layout | the `riscv64` target is planned (`plan/step-22`), not built | backend emits assembly text + `ld` script + entry stub |
| **CSR access** (`satp`/`stvec`/`sstatus`/`sepc`/…) | no primitive; `peek`/`poke` cannot reach register sets (`plan/step-14`) | hand-written `.S`/C shim (xv6 uses inline asm for this too) |
| **Trap entry and return** (`sret`) | no inline asm | hand-written `.S`, as in xv6 |
| Raw physical memory (MMIO, page tables) | `peek`/`poke` designed but **not built**; `Bytes` exists but is a hosted buffer | `Int64` address + `peek`/`poke` |
| **Bit-fields / overlapping unions** (PTE, `struct proc` over a page) | no union, no `offsetof`, no layout control | `Int64` masking + `peek`/`poke` at manual offsets |
| **In-place mutable tables** (`proc[]`, page freelist) | arrays immutable, fields frozen after `init`, no global `var` | raw memory + `Box` |
| **Spinlocks and atomics** (`amoswap`, LR/SC, `fence`) | no atomic or barrier semantics | assembly shims (the mechanism/policy split of `plan/step-14`) |
| `volatile` MMIO semantics | `peek`/`poke` are calls the optimizer may reorder or elide | the same shim, or a language-level `volatile` decision |
| Function pointers / interrupt dispatch | partial — a closure is a heap record `[code, captured]`, not a raw code address | compile-time vtables cover dispatch; `stvec` needs a shim |
| User mode (U-mode) and the `ecall` gate | all CSR + `sret` | assembly shims |
| Allocator (`kalloc`/`kfree`) | pluggable runtime, no GC, bump allocator | write the freelist yourself in Emo |
| Scheduling, syscall dispatch, FS, driver policy | expressible in plain Emo | Emo |
| Loops | tail recursion only so far (loops **decided, not implemented**) | tail recursion; `riscv64` guarantees `tail`/`jalr x0` |

## Three classes of gap, three different natures

**A. Purely mechanical gaps — add a primitive, the philosophy does not
move.**
CSR access, atomics/barriers, and raw code pointers. These are "add a
primitive" problems; `docs/rtos-assessment.md` already lists
`volatile`/atomics as an open `CHECK.md` decision. Once added, they are
closed.

**B. Escape hatch exists, but type safety goes to zero.**
Page tables, unions/overlays, and in-place mutable tables. These are
**not blockers**: use `Int64` as an address and read/write a PTE through
`peek`/`poke` eight bytes at a time, mask bits for bit-fields, and back
`proc[NPROC]` with raw memory. xv6's C code is essentially this already.
Emo can express it — but it expresses it as an **untyped memory
program**.

**C. Genuine model conflict — needs a design decision.**
**Shared mutable global kernel state.** Emo's value semantics, immutable
arrays, fields frozen after `init`, block-scoped `var` that cannot
escape, and copy-on-send messages are designed for *isolation* (the
Erlang lineage) — the opposite of the aliased, in-place-mutated, global
mutable structures a kernel wants. The theoretical way out is to model
**the whole kernel as one Emo process**, hold global state in a set of
`Box` cells, and drop everything else to raw memory behind
`peek`/`poke`. It works, but the language has no native idiom for "a
kernel data structure" — that is the interesting theoretical question,
not the assembly.

## The compilation architecture

- **The backend shape is adequate.** `riscv64` emits assembly text for
  GNU `as`/`ld` with a generated linker script, and hand-written
  `.S`/freestanding C sources compile into the image with the psABI as
  the contract — exactly the "C interop on bare metal" shape
  `plan/step-14` describes. The IR (named functions, closures,
  compile-time vtables, guaranteed tail calls) is sufficient for kernel
  logic.
- **No GC is an asset.** The bump allocator can serve as the base under
  `kalloc`, with the freelist maintained by hand; once preemption exists
  it is a pure register/stack switch, with no incremental collector to
  reconcile.
- **Two hard prerequisites:**
  1. On `riscv64`, `plan/step-22` currently **refuses `foreign def` at
     emission time**, while a kernel needs a bridge for CSRs, atomics,
     and trap handling. The "compile C/assembly into the image" bridge
     must therefore move ahead of the FFI ladder (`plan/step-14`,
     rungs 1–2); without it M1 is not reachable.
  2. **`Int32` and exact-width `peek`/`poke`**: device registers must be
     accessed at their width (`docs/numeric-width.md` says so), and
     `Int32` is at present only an agreed future type with an open
     surface.
- Also, `Int64`/`Float64` are **boxed two-word cells** in the
  freestanding dynamic world; the kernel path depends on step 13's
  Stage B specialization keeping raw registers, or every access goes
  through the boxed path.

## A sharper observation

Pulling this together: **Emo's type system is least capable exactly
where a kernel most needs it.** The things that carry the most safety
value in kernel code — physical versus virtual addresses, the width and
volatility of MMIO registers, PTE bit-fields, the layout of
`struct proc` — all degrade in Emo to `Int64` plus raw memory, on which
the checker has nothing to say.

So "xv6 in Emo" is theoretically sound, but what it buys is not a
*safer* kernel — it is the **single-language closure** (kernel, shell,
and UI in one language). At xv6's scale, Emo is closer to an
**orchestration layer over raw memory** (with everything but a garbage
collector) than a language that checks the kernel's most dangerous code.

## Verdict

- **Pure Emo, no new surface, no assembly/C shim: not feasible.** CSRs,
  trap return, and atomics are not expressible.
- **Emo plus a thin substrate** (assembly/C shim — the mechanism/policy
  split `plan/step-14` already accepts): **theoretically feasible.**
  Page-table construction, the allocator, the process table, scheduling,
  syscall dispatch, ELF loading, driver policy, and filesystem logic are
  all expressible in Emo.
- **The only true theoretical blockers are three:** (1) trap/CSR/atomic
  primitives — addable; (2) an idiom for shared mutable global state —
  one design decision; (3) the value model's blind spot for aliased
  memory — an escape hatch exists, but it is untyped.

In one sentence: **feasibility does not turn on the scheduler or the
page-table algorithm, but on whether Emo is willing to admit that kernel
code needs a raw-memory sublanguage the type system cannot check but
whose semantics are precisely defined.** `peek`/`poke` are its germ; add
`volatile`, atomics, and exact widths and xv6 becomes writable in Emo.

## References

- `docs/rtos-assessment.md` — the RTOS parallel, and the same
  "hard-real-time is out of reach" conclusion.
- `docs/runtime-and-freestanding.md` — freestanding versus runtime, and
  the `riscv64` target's position in the two axes.
- `docs/numeric-width.md` — width-explicit numerics and the `Int32` /
  exact-width `peek`/`poke` gap for MMIO.
- `plan/step-22-riscv64.md` — the freestanding target, the value model,
  the boot profiles, and the `foreign def` refusal.
- `plan/step-14-other-targets.md` — the RISC-V reference note, the
  mechanism/policy split, and the C-interop ladder.
- `docs/native-backend.md` — the IR/specialization pipeline and the
  `foreign def` surface.
- `README.md`, "EmoOS" — the single-language-closure ambition.
