# The `json` Package

The standard library's JSON reader and writer, written in pure Emo over
the shared runtimes — bytes, interfaces, and the `float` package's
exact-decimal conversion. No per-target runtime work: every target that
compiles the language answers identically, byte for byte.

## Using the package

```emo
require "json"
```

A `require` pairs strictly with the manifest: `json` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    json = "0.1.0"
  }
}
```

## Values

A decoded document is a `Json`: an interface over one class per JSON
kind — `JsonNull`, `JsonBool`, `JsonInt`, `JsonFloat`, `JsonString`,
`JsonArray`, `JsonObject` — discriminated by the `JsonKind` enum. The
scalar accessors live on the interface, so a payload is one call away
without asking what it is; the wrong kind raises:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
```

Arrays and objects carry their containers on the concrete classes,
read through `is()` into the class:

```emo
const (R.ok, doc) = json.decode(text)
if doc.is(JsonObject) {
  println(doc.get("name").as_string())
  println(doc.get("tags").items().length())
}
```

- `JsonArray` holds `items Array[Json]` and answers `items()`.
- `JsonObject` holds `entries Array[(String, Json)]` and answers
  `entries()`; `get(key)` returns the value under `key` — when a key
  repeats, the last one wins — and raises on a missing key.
- Every accessor raises an ordinary Emo exception stating what was
  expected and what was found; `is_null?()` and `kind()` discriminate
  without guessing.

## Decode

```emo
def decode(text String) (R, Json)
```

Strict, byte-level, RFC 8259: duplicate keys last-win in `get`,
leading zeros and trailing commas refuse, `\uXXXX` escapes decode with
surrogate pairs into UTF-8. Every malformed input — and every number
out of `Int64`'s or the float's range, nesting deeper than 512
included — comes back as `(R.error, reason)` instead of inventing a
value: the reason a String stating exactly what failed and at what
byte offset, `json: expected array element at byte 3`. Integers that
fit `Int64` decode as `JsonInt`; anything with a fraction or exponent
decodes as `JsonFloat`, rounded once, to nearest with ties to even —
the same answer `strtod` gives.

## Encode

```emo
def encode(v Json) String
def encode_pretty(v Json) String
```

`encode` is compact; `encode_pretty` uses two-space indentation.
Strings escape `"`, `\`, and control characters (short forms for
`\b \f \n \r \t`, `\u00xx` otherwise); everything else rides through
as the UTF-8 it already is. Integers print through `Int64.to_string`.
Floats print in the shortest decimal form that reads back to the same
bits — `0.1`, `3.141592653589793`, `5.0e-324` — and always stay
visibly floats (`1.0`, never `1`), so encode → decode → encode is the
identity, value and kind. A non-finite float raises: JSON has no
spelling for one.

## Building values

The factories mirror the kinds; object keys and values go in as
explicit arrays:

```emo
const doc = json.object([
  ("name", json.string("王晓明")),
  ("age", json.int64(28)),
  ("tags", json.array([json.string("a"), json.null()])),
])
println(json.encode_pretty(doc))
```

## Errors

The split follows the standard library's convention. Malformed input —
the data can be anything — is the value `(R.error, reason)` from
`decode`, the reason a String stating exactly what failed (and at what
byte offset): match it, don't guess. A wrong-kind accessor, a missing
key, and a non-finite float handed to `encode` are the caller's broken
assertions about the document — those raise, ending the process. No
error codes, no nil.
