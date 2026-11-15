# The `toml` Package

The standard library's TOML reader and writer: TOML 1.1.0 decoded into
a `Toml` value tree that mirrors the json and yaml packages' design,
and encoded back in document form. Pure Emo over the shared runtimes;
numbers go through the `float` package's exact-decimal conversion, the
one json, yaml, and sql use, and the packages are otherwise
independent — requiring toml does not require json.

## Using the package

```emo
require "toml"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "toml"` needs `"toml" = "0.1.0"` in
the manifest's `deps` block.

## Values

A decoded document is a `Toml`: an interface over one class per TOML
kind. TOML has no null, so the tree has seven kinds: `TomlBool`,
`TomlInt`, `TomlFloat`, `TomlString`, `TomlDateTime`, `TomlArray`,
`TomlTable`, discriminated by the `TomlKind` enum. The scalar
accessors live on the interface; the wrong kind raises:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
def as_datetime() TomlDateTime
```

`TomlDateTime` is its own class with the parsed fields, one method
per part:

```emo
def datetime_kind() TomlDateTimeKind   // toffset, tlocal_datetime, tlocal_date, tlocal_time
def year() Int64                        // Int64 fields; zero where the form has no part
def month() Int64
def day() Int64
def hour() Int64
def minute() Int64
def second() Int64                      // 60 rides through: RFC 3339's leap second
def nanosecond() Int64                  // nine digits; the spec requires further digits be truncated
def offset_minutes() Int64              // rides only on toffset: 0 for Z, east positive, west negative
def to_text() String                    // the canonical text, decodable back to the same fields
```

Arrays and tables carry their containers on the concrete classes,
read through `is()` into the class:

```emo
const (R.ok, doc) = toml.decode(text)
if doc.is(toml.TomlTable) {
  println(doc.get("title").as_string())
  const ports = doc.get("ports")
  if ports.is(toml.TomlArray) {
    println(ports.items().length().to_string())
  }
}
```

- `TomlArray` holds `items Array[Toml]` and answers `items()`.
- `TomlTable` holds `entries Array[(String, Toml)]` and answers
  `entries()` in document order; `get(key)` returns the value under
  `key` and raises on a missing key.
- Keys are strings: bare `1979` and quoted `"1979"` name the same
  key, because decode refuses the second spelling of any key.
- Every accessor raises an ordinary Emo exception stating what was
  expected and what was found; `kind()` discriminates without
  guessing.

## Decode

```emo
def decode(text String) (R, Toml)
```

Strict, per TOML 1.1.0: bare, quoted, and dotted keys; all four
string forms (basic, literal, and both multi-line forms, the line
trailing `\` and the `\e`/`\xHH` escapes included, surrogate halves
required to pair); decimal, hex, octal, and binary integers with
underscores between digits; floats with a fraction and/or an exponent
(lowercase `e` — the grammar's own spelling — and digits required on
both sides of the point); all four date-time forms (seconds omittable
per 1.1, lowercase `t` and `z` as RFC 3339 permits, the space
delimiter try-and-see so a plain date followed by other text still
reads as the date); arrays with comments and trailing commas; inline
tables across lines with comments and trailing commas (both 1.1);
tables, arrays of tables, and the redefinition rules between them.

The document assembles into one root table whose entries ride in
document order. The redefinition rules are the spec's own: a key is
defined once in any spelling; a dotted key's table never reopens
under a header (`[a.b]` after `a.b = 1` refuses); an inline table
never grows after its braces close; `[[x]]` appends only to arrays;
`[x]` declares an implicit supertable at most once — `[x]` after
`[x.y.z.w]` is the spec's own exception and works.

Everything unsupported comes back as `(R.error, reason)` with the
byte offset: the `inf` and `nan` float spellings, which name values
the model cannot carry on every target the package declares;
integers outside `Int64`; malformed input of every shape. The reason
a String stating exactly what failed — `toml: key \`a\` is defined
twice at byte 6`. Floats round once, to nearest with ties to even.

## Encode

```emo
def encode(v Toml) String     // the document form; v must be a table
```

Each table renders its scalar and inline-array entries first, then
one `[a.b]` section per sub-table and one `[[a.b]]` section per
array-of-tables element — the order a table's own text can express,
since a table's entries must stay contiguous. An array whose elements
are not all tables rides inline, table items included; an empty
array rides inline too, `[[x]]` having no empty form. Keys print
bare when the bare-key grammar carries them and quoted otherwise.
Strings print as single-line basic strings with the standard escapes.
Floats use the same shortest round-trip form as the json package.
`decode(encode(v)) == v` holds at the value level; a document that
defined one table's scalar after its sub-table encodes with that
table's scalars first, the one reorder the format forces.

The tree's own `encode()` is the value literal — scalars as their
text, arrays inline `[ ... ]`, tables inline `{ k = v, ... }`,
date-times through `to_text()`.

## Building values

The factories mirror the kinds (no null in TOML, no datetime factory
— construct `TomlDateTime.new(...)` directly):

```emo
const doc = toml.table([
  ("service", toml.string("gateway")),
  ("ports", toml.array([toml.int64(8080)])),
  ("tls", toml.bool(true)),
])
println(toml.encode(doc))
```

`toml.float64(x)` raises on a non-finite input — the same refusal
`decode` makes.

## Errors

The split follows the standard library's convention. Malformed input,
unsupported values, and every redefinition the spec refuses — the
data can be anything — are the value `(R.error, reason)` from
`decode`, the reason a String stating exactly what failed (and at
what byte offset): match it, don't guess. A wrong-kind accessor and a
missing key are the caller's broken assertions about the document —
those raise, ending the process. No error codes, no nil.
