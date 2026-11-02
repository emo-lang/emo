# The `rand` Package

Entropy, and a reproducible stream: the target's own source of random
bytes for keys, nonces, and seeds, and a deterministic generator for
everything that must answer the same bytes every time — fixtures,
goldens, test keys. The answers are `Bytes`, because bytes are what
entropy is and a String cannot carry them on every target. The package
depends on `crypto`, whose HMAC the deterministic stream rides.

## Using the package

```emo
require "rand"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "rand"` needs `"rand" = "0.1.0"` in
the manifest's `deps` block (and `crypto` comes through `rand`'s own
manifest).

## The surface

```emo
def bytes(n Int64) (R, Bytes)
def drbg_sha256(seed Bytes, length Int64) Bytes
```

## The source: `bytes`

`bytes(n)` answers `n` bytes from the operating system's entropy
source as `(R.ok, bytes)`, or `(R.error, reason)` when the source
refuses — the reason begins `rand:` and names the source's own error
(`rand: getentropy: …`, `rand: randomBytes: …`). A negative `n` is the
caller's mistake and raises. Every call is a fresh draw: two draws
differ, and nothing is cached.

The source is bound per target through one runtime implementation,
and the package's `targets` list names exactly the targets that can
honestly serve it:

| Target | Source |
|---|---|
| interpreter (`emo run`), `ocaml` | `/dev/urandom`, read to the count |
| `c` | `getentropy`, in 256-byte calls |
| `typescript` | Node's `crypto.randomBytes` |
| `beam` | `crypto:strong_rand_bytes` |
| `wasm` | **refused by the target list** — the WasmGC host supplies no entropy, so a build of a program that requires `rand` for `wasm` is refused at resolution time, not surprised at run time |

A key is the draw, and nothing more is needed:

```emo
case rand.bytes(32) {
  (R.ok, seed) -> {
    const public = crypto.sign.ed25519_public(seed)
    // …
  }
  (R.error, why) -> { println(why) }
}
```

## The stream: `drbg_sha256`

`drbg_sha256(seed, length)` answers `length` bytes that depend on
`seed` alone: the same seed answers the same bytes on every target,
forever. It is SP 800-90A's HMAC-DRBG with HMAC-SHA-256, in its
one-shot shape — instantiate over the seed, then one Generate of
`length` bytes; no reseed, no additional input, no counter carried
between calls. The caller concatenates whatever the construction
would call entropy, nonce, and personalization into the one `seed`.
The stream is one stream: the first 32 bytes of a 64-byte request are
the 32-byte request's answer. An empty seed is a valid seed (and
answers the same bytes every time, like any other). A negative
`length` raises.

This is the generator for test keys and reproducible fixtures — the
goldens' own shape — and not a source of secrets: a secret seed makes
the output unpredictable to anyone without it, but the seed has to
come from `bytes` first.

```emo
const key = rand.drbg_sha256("fixture: tcp echo".to_bytes(), 32)
```

## The error split

| Call | Raises | Answers a value |
|---|---|---|
| `bytes(n)` | `n < 0` | `(R.error, "rand: …")` when the source refuses |
| `drbg_sha256(seed, length)` | `length < 0` | — |

## The vectors

`examples/rand_demo` pins the stream — the empty seed, a seed at 32,
33, and 64 bytes (the prefix property), a different seed, a zero
length — each line verified against the formula written out
independently in Python before freezing, and smoke-tests the source:
32 bytes answered, two draws differing, a zero count answering zero
bytes. Byte-identical on the interpreter, `ocaml`, `c`, `typescript`,
and `beam`.

## Targets

`ocaml`, `c`, `typescript`, `beam`, and the interpreter. `wasm` is
refused by the manifest for the reason above; the deterministic stream
is pure Emo and would run there, but a package's target list is one
list, and a declared refusal is the honest shape.
