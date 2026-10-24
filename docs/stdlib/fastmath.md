# The `fastmath` Package

The host's math functions, bound directly to the platform `libm`: the
performance tier of the numerical surface, the same scalar surface as
`math` answers at the host library's speed. No package dependencies.

A call here is a plain per-call `libm` binding — no reassociation, no
relaxation of the floating-point rules — so it is fast, and on a good
host library typically at least as accurate as a portable series. The
bits follow the host, though: they are not byte-identical across
platforms. Programs that need reproducible bits require `math`;
programs that need the speed require this package.

## Using the package

```emo
require "fastmath"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "fastmath"` needs
`"fastmath" = "0.1.0"` in the manifest's `deps` block.

## Constants

```emo
const e = 2.718281828459045
const pi = 3.141592653589793
```

Identical to `math`'s, so the two packages mix freely.

## The functions

`math`'s whole scalar surface, unsuffixed — the package qualifier
itself says native. The four the fast lane opened with (`exp`, `log`,
`log10`, `pow`), the trigonometric trio and its inverses, the
hyperbolic trio, the base-two pair with the overflow-safe hypotenuse,
the error function and its complement, and the gamma pair:

```emo
foreign def exp(x Float64) Float64 = "exp"
foreign def log(x Float64) Float64 = "log"
foreign def log10(x Float64) Float64 = "log10"
foreign def pow(base Float64, exponent Float64) Float64 = "pow"

foreign def sin(x Float64) Float64 = "sin"
foreign def cos(x Float64) Float64 = "cos"
foreign def tan(x Float64) Float64 = "tan"
foreign def asin(x Float64) Float64 = "asin"
foreign def acos(x Float64) Float64 = "acos"
foreign def atan(x Float64) Float64 = "atan"
foreign def atan2(y Float64, x Float64) Float64 = "atan2"

foreign def sinh(x Float64) Float64 = "sinh"
foreign def cosh(x Float64) Float64 = "cosh"
foreign def tanh(x Float64) Float64 = "tanh"

foreign def exp2(x Float64) Float64 = "exp2"
foreign def log2(x Float64) Float64 = "log2"
foreign def hypot(a Float64, b Float64) Float64 = "hypot"

foreign def erf(x Float64) Float64 = "erf"
foreign def erfc(x Float64) Float64 = "erfc"

foreign def tgamma(x Float64) Float64 = "tgamma"
foreign def lgamma(x Float64) Float64 = "lgamma"
```

`sqrt` is not here: it is a `Float64` method on every target already,
one hardware instruction. `math`'s non-scalar surface — the complex
arithmetic, the FFT, BLAS1, the dense solver — has no native tier in
this milestone; stage 3 of the netlib assessment owns it.

## The contract differs from `math`

`math` raises on overflow and at its domain edges because five-target
byte-identity cannot produce NaN or infinity. This package has no
guards: the host libm's behavior is the contract, and an out-of-range
argument returns whatever the host returns — infinity, NaN, a
subnormal. The caller filters its data before the call.

## Targets

`ocaml` and `c`, the two targets that bind a host symbol. A `require`
on any other target fails at load (E5007); under the interpreter, which
has no foreign implementation to bind, a call raises E3009.

## The accuracy record

The native tier's own battery lives in `examples/fastmath_elefunt`, a
c-only companion running the same identities and the same sample stream
as `math`'s battery over these bindings, printing each row's verdict
against a stated loss budget in bits instead of the raw number — so
the golden holds across host libms. The budgets sit far above what a
reasonable host library loses and far below what a broken function
loses; the cancellation-dominated rows carry their identity's own
floor, stated in the source.

Reference: [`docs/stdlib/math.md`](math.md) (the pure twin surface) ·
Demos: `examples/fastmath_demo`, `examples/fastmath_elefunt`.
