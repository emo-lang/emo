# The `hash` package

The digests' own package: SHA-256 and SHA-224 — one-shot or streaming —
the constant-time comparison, and the lowercase hex rendering. Pure Emo
over `Int64` and `Bytes`, so every target answers the same bytes, and
the RFC vectors pin the engine.

It began as the machine's twin of the [`crypto`](crypto.md) package's
SHA-2: the engine carried here word for word, because crypto's error
surface (its guards raise) refused the `riscv64` target whole — the
compiler had no raise to lower there — and the machine's lock needed
the digest without the rest of the crypto world. The raise gap closed
(step 91) and crypto rides the metal now; this package **stays** — the
decision, not a wall: the lock's surface is a digest, a compare, and a
hex rendering, and a program that needs exactly that should not pull
the ciphers and the signature scheme in with it. The two packages pin
the same vectors, and the pins are the twin's proof: any byte this
engine answers, crypto's answers too.

Chinese translation: [`docs/zh-CN/stdlib/hash.md`](../zh-CN/stdlib/hash.md).

A root module and a SHA-2 module, called by their qualified names:

```emo
def constant_time_compare(a Bytes, b Bytes) Bool
def hex_encode(data Bytes) String

// hash.sha2:   sha256, sha224, sha512, sha384, sha512_224, sha512_256,
//              and the streaming Digest and Wide classes
```

Bytes in, Bytes out; the compare's verdict is the bytes' whole answer,
branching on nothing a secret could steer. `sha256("noctalia")` is
`721ee3c57b31edacf3bede6867f93ebaa5c46857ef633b972903f911cac0da14` —
the vector the desktop's lock golden pins, the same bytes crypto's
sha256 answers.
