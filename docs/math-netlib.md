# Emo and netlib — an assessment

Written 2026-10-22. This is a technical feasibility assessment, not
decided design; project-state claims reflect the repository as of the
date above.

The question: what would it take to build a high-performance
numerical library for Emo on the foundation of
[netlib](https://netlib.org/liblist.html)?

## The conclusion

**Feasible — but the two halves of the goal pull apart, and the honest
plan separates them.** "Based on netlib" buys correctness breadth and
reference semantics; it does not buy speed, because what netlib ships
are reference implementations — its BLAS trails the tuned descendants
(OpenBLAS, BLIS, MKL, Accelerate) by one to two orders of magnitude on
matrix multiplication. "High performance", in turn, sits behind
compiler-grade gates in Emo today: no array crosses the FFI in any
position, arrays are boxed and value-semantic, and the C runtime runs
on a single OS thread. Meanwhile the foundation is already poured: the
`math` package 0.1.0 is on `develop`, with five-target byte-identical
transcendentals and an opt-in native fast path. The staged verdict:

| Stage | Goal | What it costs |
|---|---|---|
| 1 | All-target, byte-identical correctness library — full transcendentals, a complex FFT, BLAS1, one small dense solver — netlib as algorithm and test baseline | package work only; extends the landed `math` |
| 2 | Scalar native acceleration — QUADPACK quadrature and the special functions bound through the existing FFI | package work only; generalizes the `*_native` precedent |
| 3 | Array-class performance — BLAS2/3 and LAPACK subsets bound natively | the array FFI gate: marshaling, mutable views, an unboxed `Float64Array`, foreign thread semantics — a compiler step, the same gate the SQL-database and industrial-software assessments hit |

## What netlib actually offers

netlib is the numerical-computing community's reference repository,
assembled since the 1980s and still maintained. Its content is freely
available and overwhelmingly public-domain or permissive — LAPACK
itself ships under a BSD-style license. The catalog layers up:

- **BLAS** — the vector/matrix kernels; **LAPACK** — dense linear
  systems, least squares, eigenproblems (EISPACK and LINPACK are its
  ancestors and are effectively superseded); **ScaLAPACK/ARPACK** —
  the distributed and sparse variants.
- **FFTPACK** — Fourier transforms; **QUADPACK** — adaptive
  quadrature; **MINPACK** — nonlinear least squares; **ODEPACK** —
  initial-value ordinary differential equations.
- **Special functions** — CEPHES, fdlibm, and the ELEFUNT battery of
  Cody & Waite, the classical validation suite for elementary
  functions.
- **TOMS** — the ACM Transactions on Mathematical Software algorithm
  collection; **SLATEC** — the combined DOE library.

Everything is Fortran 77, with `f2c` as the standard translation to C,
so the sources vendor into a package tree with no license burden.

The performance caveat belongs in the same breath: these are the
reference implementations, written for clarity and portability. The
fast descendants rebuilt the kernels — SIMD, cache blocking, multicore
scheduling — and the speed lives in that work, not in the algorithms.
Building "high performance" on netlib sources in Emo means either
accepting reference-class throughput or linking the tuned libraries,
which are external binary dependencies and sit badly with the
all-local, static, three-platform release pipeline.

## Where Emo already stands

Six facts shape the whole assessment (repository state, 2026-10-22):

1. **The `math` package exists** (`stdlib/registry/math/0.1.0`, on
   `develop`). Pure Emo: scalars (`abs`, `min`, `max`, `clamp`,
   `sqrt`); `exp`, `log`, `log10`, `pow` as fixed-order series with
   range reduction over the `Float64.to_bits` / `Float64.from_bits`
   pair — the same operations in the same order on all five hosted
   targets produce the same bits, which the plot SVG goldens rely on.
   Domain violations raise `Exception`, because the beam target's
   floats cannot hold NaN or infinity at all.
2. **The native fast path has a settled shape**: opt-in
   `exp_native` / `log_native` / `log10_native` / `pow_native` as
   `foreign` defs pinned to `c` and `ocaml`. Everywhere else the
   definitions are inert — `require "math"` works and only a call is
   refused (E3009 in the interpreter, a lower error in the emitters) —
   and the output follows the host libm, so it is not byte-identical.
3. **The FFI admits no array in any position.** Scalar parameters are
   `Float64`/`String`/`Bool` (plus `Int64` and `Void` returns on c);
   struct shapes and single-method-interface callbacks work over the
   same scalars. An `Array[T]` parameter, field, or callback argument
   is E4200 — and on the typescript, wasm, beam, and riscv64 targets
   even a scalar call is refused at lowering.
4. **Arrays are boxed and value-semantic.** In the C runtime an array
   is a vector of tagged words with each element boxed; indexing is
   bounds-checked; there is no unboxed flat float array (`Bytes`, u8,
   is the only unboxed store). A LAPACK-style in-place update would
   deep-copy across any future marshaling boundary.
5. **One OS thread.** Emo processes are ucontext fibers on a single
   thread with a run queue; there is no native parallelism, and a long
   foreign call occupies the only thread, stalling every process.
6. **The packaging machinery for native-only code is proven**: a
   manifest declares `targets = [...]`, enforced at load with E5007;
   `os` ships as ocaml+c, `sqlite3` and `term` as c-only, each with
   its native sources riding in the package tree.

The verification side is likewise ready: the golden discipline, the
`float` package's exact decimal conversion as a test oracle, and
`plot` for eyeballing results.

## The advantages

- **The hardest problem is already solved.** Cross-platform libm
  divergence is the classical reason deterministic numerical libraries
  are hard; `math` answered it with fixed-order series over bit-level
  operations, at the cost of hand-written algorithms. That cost is now
  amortized machinery, not an open question.
- **netlib's best-matched layer is the special functions** — scalar
  in, scalar out, with ELEFUNT as a ready-made validation suite. That
  is exactly the shape the existing FFI and the `*_native` pattern
  already handle.
- **Scalar-shaped components bind today with zero compiler work.**
  QUADPACK's adaptive quadrature is scalar in, scalar out, with the
  integrand supplied as a callback — within the existing callback
  contract. ODE right-hand sides are the same shape.
- **Distribution is frictionless.** Public-domain and permissive
  Fortran, translated once by `f2c`, vendored as package native
  sources, statically linked — the release pipeline is untouched.
- **The language surface has real assets for numerical code**:
  explicit `Float64`/`Int64` widths, strict checking with no implicit
  conversions, and bit-level conversion builtins — the raw material
  the series code already proves out.

## The disadvantages

1. **The array FFI gate is the hard one.** Every BLAS, LAPACK,
   FFTPACK, and MINPACK entry point is arrays in, arrays out; today
   that is E4200 in every position. Crossing it takes marshaling, an
   unboxed `Float64Array`, and mutable (aliased) views — the Fortran
   convention is in-place in-out and Emo arrays are value-semantic, so
   a deep copy per call would eat the entire win. The same gate the
   SQL-database and industrial-software assessments found, and a
   compiler step, not package work.
2. **The pure-Emo performance ceiling is low for array work.** Boxed
   elements, bounds-checked indexing, no SIMD, one thread: BLAS1 and
   small BLAS2 are tolerable; matrix multiplication and large FFTs sit
   one to two orders of magnitude off tuned-library numbers.
3. **The consistency discipline amplifies with surface area.** Any
   libm- or netlib-bound function is c/ocaml-only and ULP-different
   from its pure-Emo twin, so its goldens must be per-target or
   native-only. `math` carries that tension on four functions; a
   numerical library spreads it across the package.
4. **No parallelism to offer.** Tuned-BLAS numbers come as much from
   SIMD kernels, cache blocking, and multicore scheduling as from the
   algorithms; Emo's runtime offers none of the three, and a long
   foreign call blocks every process while it runs.
5. **The API surface is design work, not translation work.** No
   operator overloading (by philosophy), value-semantic arrays, and
   exceptions instead of in-band error codes: the Fortran signatures
   translate wrong directly, and the package needs an immutable,
   Emo-native API designed on purpose.

## The recommended shape

- **Stage 1 — the correctness library, all targets.** Complete the
  transcendental surface (`sin`/`cos`/`tan`, the inverses, the
  hyperbolics — same series discipline), port FFTPACK's radix-2
  complex transform, write BLAS1 in pure Emo, and add one small dense
  solver (Gaussian elimination, gesv-shaped). Deliverable per step,
  byte-identical goldens throughout, netlib as algorithm and test
  baseline.
- **Stage 2 — scalar native acceleration.** Bind QUADPACK and the
  special functions as opt-in `*_native` variants through the existing
  FFI, with ELEFUNT as the acceptance suite. This also measures
  whether the opt-in pattern pays on a wider surface before stage 3 is
  scheduled.
- **Stage 3 — the array gate, as its own compiler step.** Array
  marshaling with mutable views, an unboxed `Float64Array`, and
  explicit thread-occupancy semantics for foreign calls. After that
  lands, a LAPACK subset ships as a c-only package on the
  `os`/`sqlite3` pattern. OpenBLAS-class performance stays parked
  until the unboxed-array floor is measured.

Positioning follows from the staging: the deliverable is a
correctness-first numerical library with a native fast lane, not
"high-performance" — that word stays out of the pitch until stage 3
has a measured number behind it.

## References

- netlib library list: <https://netlib.org/liblist.html>
- LAPACK: <https://www.netlib.org/lapack/>
- QUADPACK: <https://www.netlib.org/quadpack/>
- FFTPACK: <https://www.netlib.org/fftpack/>
- f2c: <https://www.netlib.org/f2c/>
- ELEFUNT: <https://www.netlib.org/elefunt/>
- OpenBLAS: <https://www.openblas.net/>
