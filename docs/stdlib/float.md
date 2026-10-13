# The `float` Package

The exact conversion between an IEEE binary64 value and its decimal
text, with no host formatting primitive in the way: a decimal literal
becomes the bits nearest to it, and a `Float64` becomes the shortest
decimal text that reads back to exactly it. Both directions are plain
`Int64` arithmetic — ASCII digit buffers one way, base-256 limbs the
other — in the package's `internal` subtree, so all five hosted targets
answer byte-for-byte. No `strtod`, no `printf`.

The format packages are its callers: `json`, `sql` and `yaml` read and
write numbers through this one implementation, so a literal parses to
the same bits whichever format carries it, and the algorithm has one
home to fix.

## Using the package

```emo
require "float"
```

A `require` pairs strictly with the manifest: `float` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    float = "0.1.0"
  }
}
```

## The surface

```emo
def parse_exact(neg Bool, digits Bytes, n Int64, e10 Int64) Int64
def finite_bits(bits Int64) Bool
def to_text(x Float64) String
```

## Decoding

`parse_exact(neg, digits, n, e10)` answers the bit pattern of
`(-1)^neg * 0.digits * 10^e10`, correctly rounded: to nearest, ties to
even, the same answer `strtod` gives. `digits` holds the ASCII digit
bytes of the significand and `n` counts them; `e10` is the decimal
exponent. A scanner hands over what it read, with no normalization of
its own — leading zeros shift the exponent, trailing zeros after the
point change nothing — and digits past the cap of 800 significant ones
only steer sticky rounding. The cap is sized past every exact tie: a
tie needs at most 768 significant digits, so no tie ever loses its tail
to the cap.

The answer is a bit pattern whatever the value. Above binary64's range
it is the infinity pattern; below it, the value underflows — to the
smallest denormal, or to zero when it rounds there. `finite_bits` says
whether a pattern is a value at all: an all-ones exponent spells
infinity or NaN, and BEAM has neither — its `from_bits` refuses such a
pattern outright.

## The range check belongs to the caller

Decode answers instead of raising because only the caller knows what an
out-of-range number means: to `json` and `sql` it is malformed input, a
number no binary64 can hold, so they check `finite_bits` and answer
`(R.error, …)` rather than build the value. The check comes first for a
reason on BEAM: a value that cannot exist there cannot be built and
then discarded.

## Encoding

`to_text(x)` prints the shortest decimal text that reads back to
exactly `x`. The digits of the value are exact — integers scaled by a
power of five, not a rounded approximation — and the shortest width is
found by trying one significant digit, then two, and so on until a
candidate round-trips through `parse_exact`; seventeen digits always
do. A zero prints as `0.0` (`-0.0` with the sign bit), and a
non-finite value has no decimal text at all, so `to_text` raises.

## Targets and performance

Targets: all five (`ocaml`, `c`, `typescript`, `wasm`, `beam`).

Nothing here calls a host float formatter, so no target's behavior can
leak into the answer. Every helper is a pure tail recursion — no
reassignment anywhere — so the specialized backends take the package
whole.

## Where it is exercised

The package has no demo of its own: it is a building block, and the
format packages' demos are where it runs — `examples/json_demo`,
`examples/sql_demo`, `examples/yaml_demo`.
