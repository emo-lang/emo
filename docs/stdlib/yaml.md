# The `yaml` Package

The standard library's YAML reader and writer: YAML 1.2 (core schema)
decoded into a `Yaml` value tree that mirrors the json package's
design, and encoded back in block style. Pure Emo over the shared
runtimes; the packages are independent — requiring yaml does not
require json.

## Using the package

```emo
require "yaml"
```

A `require` pairs strictly with the manifest: `yaml` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    yaml = "0.1.0"
  }
}
```

## Values

A decoded document is a `Yaml`: an interface over one class per YAML
kind — `YamlNull`, `YamlBool`, `YamlInt`, `YamlFloat`, `YamlString`,
`YamlArray`, `YamlObject` — discriminated by the `YamlKind` enum. The
scalar accessors live on the interface; the wrong kind raises:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
```

Arrays and objects carry their containers on the concrete classes,
read through `is()` into the class:

```emo
const doc = yaml.decode(text)
if doc.is(YamlObject) {
  println(doc.get("service").as_string())
  println(doc.get("ports").items().length().to_string())
}
```

- `YamlArray` holds `items Array[Yaml]` and answers `items()`.
- `YamlObject` holds `entries Array[(String, Yaml)]` and answers
  `entries()`; `get(key)` returns the value under `key` — when a key
  repeats, the last one wins — and raises on a missing key.
- Mapping keys are strings (a plain `8080:` key keeps the text).
- Every accessor raises an ordinary Emo exception stating what was
  expected and what was found; `is_null?()` and `kind()` discriminate
  without guessing.

## Decode

```emo
def decode(text String) Yaml
```

Strict and line-oriented, per YAML 1.2's core schema: block mappings
and sequences (nested, the compact `- key: value` form, and
same-indent sequences under a key), flow collections (`[a, b]`,
`{k: v}`), single and double quoted scalars (the YAML escape set,
including `\xXX`, `\uXXXX`, `\UXXXXXXXX`, and surrogate pairs),
comments, literal `|` and folded `>` block scalars with `+`/`-`
chomping, and an optional leading `---`. Plain scalars resolve per
the core schema: `null`/`~`, `true`/`false` (and the cased forms),
decimal integers, `0x`/`0o` integers, floats with `.inf`/`.nan`;
everything else is a string. Integers outside Int64 refuse; floats
round once, to nearest with ties to even.

Everything unsupported raises with the byte offset: anchors and
aliases, tags, multi-document input, multi-line plain or quoted
scalars, multi-line flow, tabs in indentation.

## Encode

```emo
def encode(v Yaml) String
```

Block style with two-space indentation, no trailing newline. Strings
print plain when no reader could misread them (never resolvable as
`null`, a boolean, or a number; no leading or trailing spaces; no
indicator characters, no `: ` or ` #` inside); everything else goes
out double-quoted with the standard escapes. Mappings and sequences
print `{}` / `[]` when empty. Floats use the same shortest round-trip
form as the json package; a non-finite float raises.

## Building values

The factories mirror the kinds:

```emo
const doc = yaml.object([
  ("service", yaml.string("gateway")),
  ("ports", yaml.array([yaml.int64(8080)])),
  ("tls", yaml.object([("enabled", yaml.bool(true))])),
])
println(yaml.encode(doc))
```

## Errors

Following the standard library's convention, every failure —
malformed input, a missing key, a wrong-kind accessor, an unsupported
construct — raises an ordinary Emo exception whose message states
exactly what failed (and at what byte offset, for decode). No error
codes, no nil.
