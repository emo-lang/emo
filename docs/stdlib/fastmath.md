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

```emo
foreign def exp(x Float64) Float64 = "exp"
foreign def log(x Float64) Float64 = "log"
foreign def log10(x Float64) Float64 = "log10"
foreign def pow(base Float64, exponent Float64) Float64 = "pow"
```

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

Reference: [`docs/stdlib/math.md`](math.md) (the pure twin surface) ·
Demo: `examples/fastmath_demo`.
