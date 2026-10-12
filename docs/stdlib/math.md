# The `math` Package

The elementary float functions the rest of the standard library builds
on, with no package dependencies. Everything is pure Emo over the
scalar operations all five hosted targets share, so each function
answers byte-for-byte: the transcendentals use fixed-order series and
range reduction, and the same operations in the same order produce the
same bits everywhere — the property the plotting goldens rely on.

## Using the package

```emo
require "math"
```

A `require` pairs strictly with the manifest: `math` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    math = "0.1.0"
  }
}
```

## Constants

```emo
const e = 2.718281828459045
const pi = 3.141592653589793
```

## The surface

```emo
def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def exp(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
```

`abs` answers the magnitude, `min`/`max` the smaller/larger of two
values (a `NaN` comparison is false, so `min`/`max` return the second
argument), and `clamp(x, lo, hi)` bounds `x` to `[lo, hi]`. `sqrt` is
the core method in function form.

## The transcendental functions

`exp` range-reduces its argument to `2^k * exp(r)`, with `k` the
nearest integer to `x / ln2` and `|r| <= ln2 / 2`, then evaluates
`exp(r)` with a short Taylor series and scales by an exact power of two
written into the exponent field.

`log` splits its argument into `x = m * 2^e` with `m` in
`[sqrt(1/2), sqrt(2))` and evaluates `log(m)` with the atanh series
`2 * (z + z^3/3 + z^5/5 + ...)`, `z = (m-1)/(m+1)`. `log10` multiplies
`log` by `1 / ln10`. `pow(base, exponent)` is `exp(exponent * log(base))`.

## Domains are contract violations

The functions have domains, and an out-of-domain argument is a
programming error, not data: it raises `Exception` rather than
returning a special value.

- `log` of a non-positive number, and `log10` likewise;
- `exp`'s overflow (an argument above about 709.78);
- `pow` of a negative base, or of zero to a negative exponent.

Returning NaN or infinity is not an option here: the beam target's
Erlang floats cannot represent either one at all, so a package that
answers byte-for-byte on every target cannot produce them. The caller
filters its data before the call — a log scale drops non-positive
values, and a kernel density estimate keeps its exponent in range.

## Targets and performance

Targets: all five (`ocaml`, `c`, `typescript`, `wasm`, `beam`).

The package deliberately carries no native fast path. Calling the host
`libm` through `foreign def` would refuse the wasm/typescript/beam
targets and pin output to a platform, which is exactly what this
package exists to avoid. A native path, if one is ever wanted, belongs
in a separate native-only package under distinct `*_native` names, so
the choice is visible at the call site.

See also: `examples/math_demo`.
