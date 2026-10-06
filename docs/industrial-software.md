# Emo and industrial software — an assessment

Written 2026-10-06. This is a market-positioning assessment, not decided
design; project-state claims reflect the repository as of the date above.

The question: does Emo fit the software category China's 15th Five-Year
Plan (2026–2030) calls *industrial software* (工业软件)?

## The conclusion

**Not today, and the bottleneck is ecosystem and timing, not language
direction.** Several parts of Emo's design genuinely rhyme with the
domain — the BEAM target's supervision story, the freestanding `riscv64`
target, strict compile-time checking — but the category the plan targets
competes against decades of accumulated C++, and Emo's FFI currently
admits three types across the boundary. The segments are not equally
distant: some are unreachable on any near horizon, and a couple of
openings are real.

## What the plan means by "industrial software"

The Central Committee's plan *Recommendations* (October 2025) name
*basic software* (基础软件) in the decisive-breakthrough sentence —
integrated circuits, industrial machine tools, high-end instruments,
basic software, advanced materials, biomanufacturing; *industrial
software* is spelled out in the outline-draft readings and local plans.
The most concrete is Shanghai's software-sector plan, which names the
core technologies outright: geometric modeling, constraint solving,
mesh generation, physical simulation.

The implied market map:

- **Design and simulation** — CAD, CAE, EDA, CAM: the chokepoint
  (卡脖子) software the plan actually wants replaced.
- **Plant control** — DCS, PLC, SCADA, and their engineering tools.
- **Business layer** — ERP and MES management modules: amply supplied
  by existing stacks, not the breakthrough target.

The competition is CATIA-class products carrying decades of accumulated
domain knowledge — kernels, solvers, process know-how — not merely other
languages.

## Fit by segment

### Design and simulation (CAD/CAE/EDA) — furthest away

The core of this software is geometry kernels and numerical solvers,
written in C and C++, requiring tight interop. Emo's `foreign def`
currently lets `Float64`, `String`, and `Bool` cross the boundary — no
pointers, structs, arrays, or callbacks — so wrapping an OCCT-class
kernel is not possible today. That is a hard gate, not a tuning
problem.

Performance runs the same direction. The native backend's
specialization ("types feed performance") is directionally right, but
the benchmarks only show specialized beating unspecialized; no
industrial-scale workload has been measured against C or Fortran, and
the probe below is a microbenchmark rather than one.
Under gradual typing, every value carries a runtime type tag and
under-annotated regions fall back to dynamic semantics — fatal for
mesh-generation inner loops. And the value semantics — immutable
arrays, classes copied on assignment — favor safety, but at
gigabyte-scale mesh data they either force a performance disaster or
push the code into process-style `Box` programming.

### Plant control and supervision — a real opening, with limits

Emo's concurrency (processes, message passing, library-level
supervision) plus the BEAM target is exactly the Erlang-proven shape
for high-availability supervision planes: SCADA hosts, MES alerting,
work orders, dashboards — many concurrent connections, per-process
crash isolation, no whole-system downtime.

Hard real-time is out of reach, though: GC, value copying, no
scheduling guarantees. The freestanding `riscv64` target with pluggable
GC and arenas (step 22, not started as of this writing) is the
theoretical path, far from product — and functional-safety
certification (IEC 61508 and friends) demands toolchain maturity and
traceability that a new language has none of.

### The business layer — closest technically, least policy value

The type checker, structural modules, packages, and direct-style HTTP
were all shaped for exactly this kind of system. But the segment is
well supplied by existing stacks, and it is not what the plan is trying
to break through.

## A performance probe (2026-10-06)

The fit-by-segment argument is directional; this section records the
first numbers behind it. The cases are committed under `benchmarks/` —
`loops_tail`, `ffi_call`, `bytes_scan`, and the existing `fib` — with C
and plain-OCaml references in `benchmarks/baselines/`; `benchmarks/run.sh`
regenerates them into `benchmarks/results.md`. The figures below are that
run on macOS arm64, with the OCaml 5.5.1-hosted native backend
(milliseconds per run, best-of-three with one warmup).

| workload | specialized | unspecialized | interpreter | baseline |
| --- | --- | --- | --- | --- |
| tail loop, 10M iterations | 1670 ms (stack overflow at 100M) | 392 ms | 5774 ms | 14 ms (OCaml) / 3 ms (C) |
| fib(30) | 17 ms | 35 ms | 910 ms | 6 ms (OCaml) |
| foreign `sqrt`, 10M calls | — (forces dynamic) | 428 ms (~43 ns/call) | — (refused) | 45 ms (~4.5 ns/call) |
| `Bytes.get`, 20M reads | — (dynamic builtin) | 1012 ms (~51 ns/byte) | — | 30 ms (OCaml) / 15 ms (C) |

Three findings bear on the FFI question:

1. **The FFI round trip is cheap; the calling convention around it is
   not.** A foreign call runs about 43 ns all-in (10M calls in 428 ms)
   versus ~4.5 ns for the same `sqrt` loop in C. The cost is that the
   caller is boxed and allocates an argument list per call — and every
   function that calls a `foreign def` is excluded from specialization,
   dragging its own callers into the dynamic world with it.
2. **No data can cross the boundary.** `Float64`/`String`/`Bool` are
   the only types (E4200); `Int64` — the default integer — is refused.
   There are no pointers, arrays, structs, or callbacks, and `String`
   marshals as a NUL-terminated `char *`, so it cannot carry a binary
   payload either. A C kernel that needs a buffer, or that must keep
   state between calls, cannot be reached. "Pack doubles through a
   `String`" fails by construction at the first zero byte, and would
   cost ~51 ns per element in accessors before any compute.
3. **The specialization path is currently slower than the dynamic path
   for the language's only loop idiom.** Emo has no `while`/`for`;
   iteration is tail recursion. The specialized emitter wraps each body
   in `try ... with Native_return`, raising a local exception on every
   `return` — which defeats OCaml's tail-call optimization and
   allocates per call. Hence the ~4x gap and the stack overflow at 100M
   depth (the loop completes at 10M). `plan/step-22-riscv64.md` already
   calls the exception an "emission convenience" and plans a
   branch-to-epilogue with guaranteed tail calls on RV64; the
   OCaml-hosted backend has not been fixed.

Taken together: through the FFI, Emo reaches scalar leaf functions at
roughly 40 ns per call, and nothing else. A matrix multiply, FFT,
solver, or any kernel over an array is not expressible today, and the
specialized numeric path that would carry an in-language kernel is
presently slower than its own fallback.

## A terminology note: what "no GC" means

"GC" is used two ways, and the difference matters for this assessment.
In the academic sense, garbage collection is any automatic reclamation,
and **reference counting is one of its two families**. Swift and
Objective-C ship automatic reference counting and advertise "no GC" in
the industrial sense, which means *no tracing collector*. The industrial
sense is the one that carries guarantees:

- no stop-the-world pauses, and reclamation at the last release
  (deterministic destruction);
- no root scanning, stack maps, or safepoints — the runtime never has to
  walk the call stack;
- no heap headroom needed for a collector to make progress;
- addresses stay stable.

Reference counting delivers those, but it is neither free nor a tracing
collector: it cannot reclaim reference cycles (weak references or a
cycle collector are owed), it debits every pointer write, and a large
object graph can still fall in one cascading release.

Why it matters here:

- **FFI.** A tracing collector must enumerate every root, and roots held
  on the C side of an FFI boundary are nearly impossible to enumerate;
  reference counting and arenas do not have that problem. This is the
  real reason "no GC" helps a language that wants to sit next to C.
- **Bare metal.** No root scanning means no precise stack maps — a far
  smaller runtime for the `riscv64` target.
- **Emo's semantics.** Immutable arrays and value-type instances make
  reference cycles rare, which is the weakness reference counting would
  otherwise inherit; `Box`, mutually referencing instances, and mailbox
  queues are where a policy is still owed.

The positioning conclusion is the one already stated: no-GC is a
**latency, predictability, and bare-metal** argument. It is not an HPC
entry ticket — the probe above shows the HPC gaps are the FFI data
channel, vectorization, and parallelism, not the collector.

## What stands between Emo and this market

In priority order:

1. **A frozen language — 1.0 and LTS.** As of October 2026, global
   renames and additions are still landing; industrial software lives
   15–30 years, and nobody builds on a language without a stability
   promise.
2. **A real FFI.** Pointers, structs, arrays, callbacks — the only
   entrance into the C world that industrial software actually
   inhabits. Nothing on the roadmap matters more for this market.
3. **A numerical benchmark against C**, to find what specialization's
   real ceiling is. The probe above is a first microbenchmark; an
   industrial-scale kernel is still missing.
4. **One real BEAM-target supervision case** in a monitoring or control
   setting.

Beyond the list: the ecosystem is empty (linear algebra, geometry,
serialization, database drivers), and there is no debugger or profiler —
while industrial software feeds on exactly those.

## Where the design does line up

- **Wasm + EmoUI** — browser-side lightweight CAD viewers and
  configuration/SCADA screens: a real, commercially valuable niche the
  existing targets already point at.
- **BEAM** — high-availability supervision planes, the telecom-proven
  territory.
- **`riscv64`, long-term** — soft-real-time industrial control on bare
  metal, once the target and its memory story exist.

## Positioning

The chokepoint in industrial software is kernels, solvers, and decades
of process knowledge — not the programming language. Switching
languages does not address it, so "Emo answers the plan" is not a
defensible pitch and should stay out of Emo's positioning. Until the
FFI matures and a 1.0 exists, the defensible formulation remains the
current one — *a general-purpose language that reaches down to bare
metal* — with industrial software kept as a possibility, not a promise.

## References

- National Development and Reform Commission, press reading of the 15th
  Five-Year Plan outline (draft), March 2026:
  <https://www.ndrc.gov.cn>
- The Central Committee's *Recommendations* for the 15th Five-Year Plan
  (October 2025, reprinted by MOFCOM): <https://www.mofcom.gov.cn>
