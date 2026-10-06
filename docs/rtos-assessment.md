# Emo and real-time operating systems — an assessment

Written 2026-10-06. A technical feasibility assessment, not decided
design; project-state claims reflect the repository as of that date.

The question: how hard is it to build a real-time operating system — a
FreeRTOS-class kernel — in Emo?

## Two different undertakings

- **Port FreeRTOS (C) into an Emo image and call it from Emo.** With the
  freestanding `riscv64` target's C interop — freestanding C sources
  compiled into the image, the psABI as the contract — this is a
  low-to-medium effort. The friction is that Emo's processes are
  cooperative while FreeRTOS tasks are preemptive, so the two schedulers
  must agree on who owns the CPU and the interrupt vectors.
- **Reimplement an RTOS in Emo.** This is the real question, and it is
  hard — but the difficulty sits in the language, runtime, and tooling,
  not in the scheduler algorithm.

The rest of this note is about the second.

## What an RTOS needs

- **Preemptive priority scheduling** with bounded context-switch latency —
  the defining feature, and the one Emo does not yet have.
- **Timer and interrupt infrastructure**: a trap handler, a tick, time
  slices, ISRs.
- **ISR-safe synchronization**: mutexes (with priority inheritance),
  semaphores, queues, event groups, software timers.
- **Deterministic memory**: static or arena allocation, no collector
  pauses, no hidden allocation on the critical path.
- **`volatile` / MMIO semantics** and **atomics with memory barriers**
  (ISR-versus-task races).
- Per-task stacks, priorities, an idle task, tick-rate configuration.
- **WCET analysability**.
- Optionally memory protection (MPU/MMU).
- For safety-critical use, a **certifiable toolchain**.

## What Emo's design already helps

- **The freestanding target and a replaceable runtime.** `plan/step-22`
  gives no OS, no libc, no default runtime, with the allocator, GC, and
  scheduler as replaceable components — exactly the kernel-owns-its-runtime
  shape an RTOS wants.
- **No GC is preemption-friendly.** Preemption is then just save registers
  and switch stacks; a tracing collector would instead have to be
  preemption-safe or incremental. The current no-GC direction removes the
  hardest RTOS/preemption interaction (adding a collector later would make
  this *harder*, not easier).
- **Cooperative-first scheduling with copied messages** keeps a single
  hart lock-free and atomic-free, because processes share no mutable state.
- **The context switch is textbook**: roughly thirty assembly instructions
  to swap `sp`, `ra`, and the callee-saved registers, and
  `emo_sched_det` gives a reference model to diff against.
- **Explicit MMIO** through `peek`/`poke`; value semantics that reduce
  data races; structural interfaces with compile-time vtables, so the
  kernel has no runtime method lookup.
- **Width-explicit numbers**: one register for `Int64` on RV64.
- **Single-language closure** (the EmoOS ambition): kernel and shell in
  one language.

## What Emo's design works against

- **No preemption promise.** `plan/step-22` places timer preemption at M3
  and marks it "optional; semantics do not require it". An RTOS requires
  it, so it must be built.
- **No `volatile`, atomic, or barrier semantics** in the language.
  `peek`/`poke` are calls the optimizer may reorder or elide, and ISR/task
  races have no primitive. This is a language-and-codegen gap.
- **Gradual typing boxes dynamic regions**, and step 22 boxes `Int64` and
  `Float64` in the freestanding dynamic world; the tagged path has
  non-constant cost, which fights WCET.
- **Value semantics allocate** (strings, arrays, instances, messages) —
  fine with an arena or a static allocator, fatal if unbounded.
- **No loop statement yet** (decided, not implemented); tight loops and
  ISR bodies are recursion today.
- **Exceptions** (the catch form is still open in `CHECK.md`) must unwind
  in bounded time.
- **No debugger, profiler, WCET tooling, or MISRA-style checker.**
- **Not frozen** (no 1.0/LTS) and an empty ecosystem (BSPs, drivers,
  middleware), which rules out functional-safety certification for now.

## Difficulty by target

| Target | Difficulty | Notes |
| --- | --- | --- |
| Cooperative kernel (green threads, messages, MMIO console) | moderate | step 22's M2 scope; not an RTOS |
| Soft real-time industrial control / supervision | moderate | cooperative plus bounded allocation may suffice |
| Preemptive RTOS core (FreeRTOS-class) | hard (months to years) | M3 preemption plus `volatile`/atomics, deterministic memory, ISR infrastructure |
| Porting FreeRTOS (C) and driving it from Emo | low to moderate | C interop; scheduler-coexistence friction |
| Hard real-time with functional-safety certification | very hard, out of reach for now | needs a frozen language and a certifiable toolchain |

## The real blockers

The scheduler algorithm is textbook; the blockers are language- and
runtime-level guarantees — preemption safety, deterministic memory,
`volatile`/atomics, WCET analysis, and certification tooling. There is
also a model mismatch: Emo's processes and mailboxes exist for
*isolation* (Erlang's lineage), while an RTOS's priorities and priority
inheritance exist to *bound the worst-case latency*. Bounded-latency
semantics are not in Emo's model today.

This is the same conclusion `docs/industrial-software.md` reaches — "hard
real-time is out of reach" — and the distance is language and tooling,
not scheduling.

## A path, if pursued

1. **Cooperative kernel bring-up** (M1/M2): the freestanding backend and
   the scheduling policy.
2. **Preemption (M3)**: `stvec` trap handler, a timer (CLINT or SBI
   `set_timer`), time slices. No GC makes this a register/stack switch —
   Emo's advantage.
3. **Language primitives**: `volatile` semantics and atomics/barriers; its
   own decision in `CHECK.md`.
4. **Deterministic memory**: static or arena allocators; no unbounded
   allocation on the kernel path.
5. **Priority scheduling and priority inheritance**: policy in Emo, on top
   of the assembly mechanism (the split step 14 already settled).
6. **Tooling**: debugger, stack-depth analysis, WCET, static checking.
7. **Certification**: only after a frozen 1.0/LTS.

## Conclusion

A cooperative, GC-free, schedulable kernel in Emo is a moderate effort
whose skeleton is already planned. A FreeRTOS-class hard-real-time RTOS is
hard, with the budget in the language, runtime, and tooling rather than
the kernel logic. A *certifiable* RTOS is out of reach until Emo is frozen
and its tooling exists. The realistic first target is soft real-time
supervision, not hard real time.

## References

- `docs/industrial-software.md` — the plant-control segment and the "hard
  real-time is out of reach" conclusion.
- `docs/runtime-and-freestanding.md` — what freestanding and runtime mean.
- `plan/step-22-riscv64.md` — the freestanding target, its value model,
  and the cooperative / preemptive / SMP milestones.
- `plan/step-14-other-targets.md` — the scheduler assessment and the
  mechanism-versus-policy split.
- `README.md`, "EmoOS" — the single-language-closure ambition.
