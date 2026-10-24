# The `math` Package

The float functions the rest of the standard library builds on, with no
package dependencies: the scalars, the powers of two, the
transcendentals, the error function and its complement, the gamma pair,
the complex arithmetic, the radix-2 FFT, the BLAS1 kernels, and the
dense solver.

The plain functions are pure Emo over the scalar operations all five
hosted targets share, so each answers byte-for-byte: the
transcendentals use fixed-order series and range reduction with their
coefficients written into the source as literals, and the same
operations in the same order produce the same bits everywhere — the
property the plotting goldens rely on. The host's faster tier is the
separate `fastmath` package, pinned to `c` and `ocaml`; everything in
this package stays byte-identical on all five targets.

## Using the package

```emo
require "math"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "math"` needs `"math" = "0.1.0"` in
the manifest's `deps` block.

## Constants

```emo
const e = 2.718281828459045
const pi = 3.141592653589793
```

## Scalars

```emo
def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def hypot(a Float64, b Float64) Float64
```

`abs` answers the magnitude, `min`/`max` the smaller/larger of two
values (a `NaN` comparison is false, so `min`/`max` return the second
argument), and `clamp(x, lo, hi)` bounds `x` to `[lo, hi]`. `sqrt` is
the core method in function form. `hypot` rescales both magnitudes by
the larger's exponent before any squaring, so neither overflow nor
underflow can disturb the answer; an argument that is not finite
raises.

## Powers of two

```emo
def pow2(n Int64) Float64
```

`pow2(n)` writes `n` straight into the exponent field, so the scaling
`exp` performs is exact and free of a multiply loop. The reachable
range is `[-1074, 1023]`: an exponent above `1023` raises, one below
`-1074` underflows to zero.

## Exponentials and logarithms

```emo
def exp(x Float64) Float64
def exp2(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def log2(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
```

`exp` range-reduces to `2^k * exp(r)`, with `k` the nearest integer to
`x / ln2` and `|r| <= ln2 / 2`, then evaluates a short Taylor series
and scales by an exact power of two. Past `x ≈ 709.78` the answer
leaves the exponent range and raises; below `x ≈ -745` it underflows to
zero. `exp2` splits at the floor — `pow2` carries the integer part,
`exp`'s series the fraction — and raises past `1024`.

`log` splits its argument into `x = m * 2^e` with `m` in
`[sqrt(1/2), sqrt(2))` and evaluates the atanh series
`2 * (z + z^3/3 + z^5/5 + ...)`, `z = (m-1)/(m+1)`; subnormal
arguments scale up first and subtract the scaling's own logarithm.
`log10` multiplies `log` by `1 / ln10`. `log2` reuses `log`'s
decomposition — its exponent part answers alone, so every power of two,
down through the subnormals, answers exactly.

`pow(base, exponent)` is `exp(exponent * log(base))` for a positive
base; a zero base answers its limit (`0^0` is `1`), and a negative base
has no real answer here — Emo has no complex result — so it raises.

## The trigonometric functions

```emo
def sin(x Float64) Float64
def cos(x Float64) Float64
def tan(x Float64) Float64
def atan(x Float64) Float64
def atan2(y Float64, x Float64) Float64
def asin(x Float64) Float64
def acos(x Float64) Float64
```

`sin` and `cos` run a split-π/2 range reduction — exact up to
`|x| <= 2^20`, beyond which, and for a non-finite argument, the call
raises — then fixed-order Taylor series over the reduced pair. `tan` is
the quotient of the two reduced series with the quadrant's sign and
reciprocal switch; its poles are unreachable in binary floating point,
so it has no domain raise of its own.

The inverse pair folds its argument into the range of a fixed-order odd
series: the reciprocal identity above `|x| = 1` and the `tan(π/12)` fold
below, into the series' heart. `asin` builds its root from the exact
factors `(1 − x)` and `(1 + x)` so it does not cancel as `x` nears one;
`acos` shares that core. `|x| > 1` raises for both. `atan2` assembles
the quadrant around `atan`: its axes are the signed zeros — each keeps
its sign — and the origin, both arguments zero, raises, the one point
where no angle exists.

## The hyperbolic functions

```emo
def sinh(x Float64) Float64
def cosh(x Float64) Float64
def tanh(x Float64) Float64
```

Compositions over `exp`. `sinh` takes a short odd series below one
half, where the difference `(e^x − e^−x)/2` would cancel; `cosh` only
ever adds its two terms. `sinh` and `cosh` raise once `e^x` leaves the
exponent range, the `exp` rule. `tanh` saturates to ±1 at `|x| = 20` —
the formula's distance from one is already below half an ulp there — so
no argument reaches `exp`'s overflow on its way into the quotient. A
non-finite argument raises for all three.

## The error function and its complement

```emo
def erf(x Float64) Float64
def erfc(x Float64) Float64
```

`erf` sums the Maclaurin terms smallest first for `|x| < 2` — thirty of
them, truncation far below an ulp at the crossover — and rides
`1 − erfc` beyond it, where the subtraction cannot cancel because the
complement is already small. `erfc` is its own function rather than
`1 − erf`: above the crossover the tail is carried by the continued
fraction for the complementary gamma, which answers the tail without a
`1 −` in sight; below it, it is `1 − erf`'s series. Past `x ≈ 27.7` the
tail underflows to zero, the `exp` rule at the bottom of the range. A
non-finite argument raises for both.

## The gamma pair

```emo
def tgamma(x Float64) Float64
def lgamma(x Float64) Float64
```

The Lanczos approximation with one fixed coefficient set — `g = 7`,
nine terms — written into the source as literals, byte-identical by
construction. The positive half above one half runs the series
directly; the negative half-line and the sliver below it fold through
the reflection formula `Γ(x) = π / (sin(πx)·Γ(1−x))` onto `1 − x`,
where the series lives.

The non-positive integers are the poles — Γ has no value there — and
both functions raise on them. `tgamma` answers directly only while the
answer fits `Float64`: past `x ≈ 171.62` above zero, and beside the
poles where the magnitude passes the ceiling, it raises, the `exp`
rule. `lgamma` answers there — its form is the logarithm of the same
product, no intermediate ever leaves the range — carrying `ln|Γ|`, the
signless magnitude, in the C tradition's shape; it is exactly zero at
the two unit points.

## Complex arithmetic

```emo
def complex_add(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_sub(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_mul(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_div(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_abs(z (Float64, Float64)) Float64
def complex_conj(z (Float64, Float64)) (Float64, Float64)
def complex_scale(z (Float64, Float64), f Float64) (Float64, Float64)
def complex_from_polar(r Float64, theta Float64) (Float64, Float64)
```

A complex value is a `(re, im)` pair of `Float64`. Division goes by
Smith's algorithm, so the quotient cannot overflow where the answer
does not; the magnitude takes the rescaled `hypot`; the polar
construction rides the package's own `sin` and `cos`. A zero divisor
raises.

The array form of a complex vector is **interleaved**: one flat
`Array[Float64]` holding `re, im, re, im, ...`, which is the layout the
FFT takes and answers without a transposing copy.

## The FFT

```emo
def fft(v Array[Float64]) Array[Float64]
def ifft(v Array[Float64]) Array[Float64]
```

The radix-2 complex FFT after FFTPACK's `cfftf`/`cfftb`: an iterative
Cooley–Tukey over the interleaved array, the bit-reversal permutation
in front, and twiddles from the package's own `sin` and `cos` — the
table is byte-identical rather than the host libm's. `ifft` scales by
`1/n`, so `ifft(fft(v))` answers `v`. A length that is not a power of
two raises — mixed radix is later work, not a silent fallback.

## BLAS1

```emo
def dot(x Array[Float64], y Array[Float64]) Float64
def nrm2(x Array[Float64]) Float64
def asum(x Array[Float64]) Float64
def iamax(x Array[Float64]) Int64
def scal(a Array[Float64], f Float64) Array[Float64]
def axpy(a Float64, x Array[Float64], y Array[Float64]) Array[Float64]
```

The BLAS1 kernels after the reference BLAS. The accumulation order is
fixed — every kernel walks the array front to back — which is what
makes them answer byte-for-byte. The arrays are values, so `scal` and
`axpy` answer fresh arrays and never write in place, and mismatched
lengths raise. `nrm2` carries the reference BLAS's scaled accumulation,
so no square can overflow. `iamax` answers the index of the first
element of largest magnitude; an empty array has no such index and
raises.

## The dense solver

```emo
def lu(a Array[Float64], n Int64) (Array[Float64], Array[Int64])
def solve(a Array[Float64], n Int64, b Array[Float64]) Array[Float64]
```

After LAPACK's `getrf`/`getrs`. A matrix is a **flat row-major**
`Array[Float64]` with its dimension spelled out — no nested arrays, one
matrix one allocation — the representation the FFT's flat vector
already uses and every target indexes in the same order.

`lu` answers the packed factors — the L multipliers below the diagonal
(L's unit diagonal never stored), U from the diagonal up — and the
pivot vector, each entry the row swapped into that step's pivot
position, zero-based. An exactly zero pivot raises, the matrix analogue
of division by zero; the threshold is exact zero, no tolerance.
`solve` is the `gesv` shape: factor, permute the right-hand side by the
same swaps, then substitute through the two factors; a right-hand side
that is not `n` long raises. Neither call writes in place; the arrays
are values, and the answers are fresh.

## Accuracy: the battery record

The battery in `examples/math_elefunt` runs Cody & Waite's identity
tests across this surface — `sin` against its triple angle, `exp`
against the shifted product, `log` against the sum form, the gamma
recurrence, and so on — over arguments drawn from a linear
congruential generator fixed in the example, so the sample is the same
on every target. Each function prints its maximum and root-mean-square
loss in bits against its identity; the golden's `expected.txt` is the
accuracy record, and a regression is a diff.

The record as landed (512 identities per row, seed 42):

```text
pow2 max 0.0 rms 0.0
sqrt max 0.994448 rms 0.32572
hypot max 0.0 rms 0.0
exp max 3.37783 rms 1.45827
exp2 max 3.3107 rms 1.43898
log max 2.86954 rms 0.623192
log2 max 1.42286 rms 0.348296
log10 max 1.52026 rms 0.397249
pow max 2.86016 rms 1.22208
sin max 7.72716 rms 2.01304
cos max 2.77636 rms 0.747501
tan max 1.98934 rms 0.506548
atan max 1.95692 rms 0.463365
atan2 max 1.29474 rms 0.110757
asin max 7.58068 rms 2.18379
acos max 4.45091 rms 1.23883
sinh max 3.51371 rms 1.41474
cosh max 8.0 rms 3.56214
tanh max 2.51866 rms 0.534811
erf max 14.5575 rms 12.3683
erfc max 29.4069 rms 25.3946
tgamma max 8.56078 rms 5.24082
lgamma max 4.55075 rms 0.838315
```

Reading it: the identities are self-consistency checks, not oracles, so
each row sits where its identity's own roundings put it. The
power-of-two and `hypot`-rescale rows measure arithmetic that is exact
and answer zero. Most rows lose a bit or two to the composition — `pow`
and the hyperbolics inherit `exp`'s and `log`'s few ulps, and the rows
that approach a zero of the function (`sin` near π, the `cosh² − sinh²`
subtraction) amplify honestly. The `erf` and `erfc` rows carry
Simpson's rule over the defining integral, so their floors — about
fifteen and thirty bits below the ceiling — are the quadrature's, not
the functions'. The `tgamma` row records the Lanczos form's own
thinning as the argument grows, the inheritance the series carries at
large `x`.

## The fast tier is `fastmath`

The host-libm bindings are not in this package. The `fastmath` package
carries the same scalar surface bound directly to the platform `libm`
on `c` and `ocaml` — a plain per-call binding, so it is faster, but the
bits follow the host and are not byte-identical across platforms.
Programs that need reproducible bits require `math`; programs that need
the speed require `fastmath`.

## Domains are contract violations

The functions have domains, and an out-of-domain argument is a
programming error, not data: it raises `Exception` rather than
returning a special value.

- `log`, `log2`, and `log10` of a non-positive number;
- `exp` past `x ≈ 709.78` and `exp2` past `1024`;
- `pow` of a negative base, or of zero to a negative exponent;
- the trigonometric functions at a non-finite argument, and beyond the
  `|x| <= 2^20` reduction bound;
- `asin` and `acos` at `|x| > 1`; `atan2` at the origin;
- `sinh` and `cosh` where `e^x` leaves the exponent range; `tanh`,
  `erf`, and `erfc` at a non-finite argument;
- the gamma pair at the poles — the non-positive integers — and
  `tgamma` where the answer leaves the exponent range;
- `lu` on a singular matrix or a dimension mismatch, `solve` on a
  right-hand side of the wrong length, `fft` on a length that is not a
  power of two, and the BLAS1 kernels on mismatched lengths.

Returning NaN or infinity is not an option here: the beam target's
Erlang floats cannot represent either one at all, so a package that
answers byte-for-byte on every target cannot produce them. The caller
filters its data before the call — a log scale drops non-positive
values, and a kernel density estimate keeps its exponent in range.

## Targets and performance

Targets: all five (`ocaml`, `c`, `typescript`, `wasm`, `beam`). The
whole package is pure, so importing it costs nothing anywhere and every
answer is byte-identical.

Demos: `examples/math_demo` (scalars and transcentals),
`examples/math_trig`, `examples/math_inverse_trig`,
`examples/math_hyperbolic`, `examples/math_complex`, `examples/math_fft`,
`examples/math_blas1`, `examples/math_solve`, `examples/math_special`
(`erf`/`erfc`/`tgamma`/`lgamma`), and `examples/math_elefunt` (the
accuracy battery).
