# The `yaml` Package

The standard library's YAML reader and writer: YAML 1.2 (core schema)
decoded into a `Yaml` value tree that mirrors the json package's
design, and encoded back in block style. Pure Emo over the shared
runtimes; numbers go through the `float` package's exact-decimal
conversion, the one json and sql use, and the packages are otherwise
independent — requiring yaml does not require json.

## Using the package

```emo
require "yaml"
```

The standard library ships with the compiler: `require "yaml"` needs no
`package.emo` entry.

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
const (R.ok, doc) = yaml.decode(text)
if doc.is(yaml.YamlObject) {
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
def decode(text String) (R, Yaml)
```

Strict and line-oriented, per YAML 1.2's core schema: block mappings
and sequences (nested, the compact `- key: value` form, and
same-indent sequences under a key), flow collections (`[a, b]`,
`{k: v}`), single and double quoted scalars (the YAML escape set,
including `\xXX`, `\uXXXX`, `\UXXXXXXXX`, and surrogate pairs),
comments, literal `|` and folded `>` block scalars with `+`/`-`
chomping, and an optional leading `---`. Plain scalars resolve per
the core schema: `null`/`~`, `true`/`false` (and the cased forms),
decimal integers, `0x`/`0o` integers, and finite floats; everything
else is a string.

Everything unsupported comes back as `(R.error, reason)` with the byte
offset: anchors and aliases, tags, multi-document input, multi-line
plain or quoted scalars, multi-line flow, tabs in indentation — as do
malformed input, integers outside `Int64`, and every float that is not
finite: a decimal rounding past binary64's range, or the core schema's
`.inf`/`-.inf`/`.nan`, which name values the model cannot carry on
every target the package declares. The reason a String stating exactly
what failed — `yaml: bad indentation in a mapping at byte 21`. Floats
round once, to nearest with ties to even.

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
form as the json package; a non-finite float — which `decode` never
produces — raises.

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

The split follows the standard library's convention. Malformed input
and unsupported constructs — the data can be anything — are the value
`(R.error, reason)` from `decode`, the reason a String stating exactly
what failed (and at what byte offset): match it, don't guess. A
wrong-kind accessor and a missing key are the caller's broken
assertions about the document — those raise, ending the process. No
error codes, no nil.
