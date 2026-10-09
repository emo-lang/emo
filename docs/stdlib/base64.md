# The `base64` Package

The standard library's RFC 4648 base64 codec: bytes in, padded base64
text out, and back. Pure Emo over the shared runtimes, so every target
answers with the same bytes — the golden rides all five lists, the
first standard-library package that does.

## Using the package

```emo
require "base64"
```

A `require` pairs strictly with the manifest: `base64` must be pinned
in `package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    base64 = "0.1.0"
  }
}
```

## The surface

```emo
def encode(data String) String
def decode(text String) String
```

`encode` always emits the standard alphabet (`A-Z a-z 0-9 + /`) with
`=` padding, in groups of four characters per three bytes. `decode`
answers the exact bytes the text names.

## Strictness

The decoder accepts exactly what the encoder produces — anything else
is a mistake and raises, with the offending byte offset:

- the standard alphabet only, `=` padding only in the final quantum;
- the final quantum holds two or three data characters (never one,
  never four, and an unpadded non-multiple of four is short);
- the padding bits the RFC requires to be zero really must be zero —
  `QR==` is a mistake, not a synonym of `QQ==`.

There is no whitespace tolerance and no line-wrap acceptance: a
wrapped message is joined by the caller before it is decoded. Every
rejection raises an ordinary Emo exception —
`base64: non-zero padding bits at byte 1` — no error codes, no nil.

## Errors

```emo
def err: base64: <what> at byte <offset>
```

The offset names the first byte where the input stops being valid
base64 — the offending character, the first misplaced `=`, or the
position where the final quantum runs out.

## The vectors

The golden (`examples/base64_demo`) rides the RFC 4648 section 10
vectors — `""`, `f`, `fo`, `foo`, `foob`, `fooba`, `foobar` encoded
and decoded back — plus a multi-byte UTF-8 payload, byte-identical on
the interpreter, ocaml, c, typescript, wasm, and beam.
