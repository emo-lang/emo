# The `quad` Package

QUADPACK's adaptive quadrature, vendored from netlib behind the one
shape today's FFI admits — a scalar callback. The integrand is a
single-method interface, the workspace is the C shim's (a fixed limit
of 500 subintervals), and a convergence failure comes back as a value,
not a violation. No package dependencies.

The vendored translation is f2c's C rendering of the original Fortran
(`dqags`, `dqagse`, `dqk21`, `dqelg`, `dqpsrt`, and the infinite-range
trio `dqagi`, `dqagie`, `dqk15i`), with QUADPACK's `d1mach` machine
constants rewritten as the IEEE-754 binary64 literals they are and no
libf2c left. The original Fortran is netlib QUADPACK (R. Piessens, E.
de Doncker, K.U.Leuven), freely distributable with acknowledgment.

## Using the package

```emo
require "quad"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "quad"` needs `"quad" = "0.1.0"` in
the manifest's `deps` block.

## The integrand

```emo
interface Integrand {
  def at(x Float64) Float64
}
```

A class with an `at` method integrates directly — the callback contract
carries the instance across the C ABI, and any state it holds rides
with it:

```emo
class CircleQuarter {
  def at(x Float64) Float64 {
    return 4.0 / (1.0 + x * x)
  }
}
```

An integrand must not call `quad.integrate` again; a nested integration
is refused with its own reason before it could corrupt the callback.

## The finite range

```emo
def integrate(f Integrand, a Float64, b Float64, epsabs Float64,
  epsrel Float64) (R, (Float64, Float64))
```

Integrates `f` over `[a, b]` to `max(epsabs, epsrel·|i|)` accuracy:
QUADPACK's globally adaptive 21-point Gauss–Kronrod rule
(`dqags`/`dqagse`), with the ε-algorithm (`dqelg`) extrapolating the
error across the subdivision history. On success the answer is
`(R.ok, (value, abserr))` — the estimate and its error bound. An
endpoint singularity is this pair's home ground: `∫₀¹ ln x dx`
extrapolates to −1 with the requested tolerance while a plain adaptive
rule grinds.

## The infinite ranges

```emo
enum InfiniteRange { from_bound, to_bound, whole_line }

def integrate_infinite(f Integrand, range InfiniteRange, bound Float64,
  epsabs Float64, epsrel Float64) (R, (Float64, Float64))
```

The three ranges past the finite, named rather than spelled with
infinite bounds: `from_bound` integrates `[bound, +∞)`, `to_bound`
integrates `(−∞, bound]`, `whole_line` integrates the whole real line
and ignores `bound` (pass `0.0`, QUADPACK's own convention). The
transformed 15-point rule (`dqagi`/`dqagie`/`dqk15i`) maps each range
onto (0, 1] before the same adaptive machinery takes over.

## The error-code mapping

Every QUADPACK failure code answers `(R.error, reason)` in netlib's own
wording; a convergence failure is an expected outcome of integration,
and the caller decides:

| `ier` | The reason |
|---|---|
| 1 | the maximum number of subdivisions (500) has been reached — split the interval at the difficulty and integrate the subranges |
| 2 | roundoff error prevented the requested tolerance from being reached; the error may be underestimated |
| 3 | extremely bad integrand behaviour at interior points of the integration interval |
| 4 | the algorithm does not converge — roundoff error was detected in the extrapolation table, and the returned result is the best obtainable |
| 5 | the integral is probably divergent, or slowly convergent |
| 6 | the input is invalid — `epsabs <= 0` and `epsrel < max(50·machine epsilon, 0.5e-28)` |
| 7 | an integrand called `integrate` again — nested integration is not supported |

Code 6 is QUADPACK's validity test: with `epsabs = 0`, `epsrel` must
reach `1.11e-14` — fifty machine epsilons — or the call refuses.

## Targets and reproducibility

`c` only — the vendored translation and the shim are native code the
build compiles and links. A `require` on any other target fails at load
(E5007); under the interpreter a call raises E3009, so `emo run` cannot
execute a program that touches this package — build it with
`emo build --target c`.

The solver's own arithmetic is exact IEEE-754 per operation (the build
compiles with `-ffp-contract=off`; the vendored code uses no
transcendental function — its one fractional power is spelled
`x*sqrt(x)`, and `sqrt` is exact by IEEE-754), so the subdivision walk
lands on the same intervals on every host. The bits of an answer are
the integrand's own arithmetic plus that walk: an integrand of plain
arithmetic or `math`'s pure series answers byte-identically everywhere;
an integrand calling libm makes the answer the host's — the same rule
`fastmath` states.

Reference: [`docs/stdlib/math.md`](math.md) (the pure numerical
surface) · Demo: `examples/quad_demo`.
