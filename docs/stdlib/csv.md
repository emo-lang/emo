# The `csv` Package

The standard library's CSV reader and writer: RFC 4180 records as
arrays of string fields, UTF-8 only. Pure Emo over the shared
runtimes — bytes and arrays — so every target that compiles the
language answers identically, byte for byte.

## Using the package

```emo
require "csv"
```

A `require` pairs strictly with the manifest: `csv` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    csv = "0.1.0"
  }
}
```

## The surface

```emo
def decode(text String) (R, Array[Array[String]])
def encode(rows Array[Array[String]]) String

def decode_delimited(text String, delimiter String) (R, Array[Array[String]])
def encode_delimited(rows Array[Array[String]], delimiter String) String
```

A decoded document is `Array[Array[String]]`: the records, each a
sequence of string fields, in document order. There is no header —
the first record is a header only when the caller reads it as one. The
value is ordinary data, so `rows.length()` is the record count,
`rows[i]` is a record, `rows[i][j]` is a field, and two documents
compare with `==`.

The two `_delimited` functions take a one-byte field delimiter — a tab
for TSV, a semicolon for the European convention. `decode`/`encode`
are the comma-separated special case of the same grammar.

```emo
require "csv"

const (R.ok, rows) = csv.decode("name,city\r\n\"Smith, John\",上海\r\n")
println(rows[0][0] + " / " + rows[0][1])      // name / city
println(rows[1][0] + " / " + rows[1][1])      // Smith, John / 上海
println(csv.encode(rows))                     // the records back as RFC 4180
```

## Decode

`decode` is strict about the CSV grammar and about UTF-8. Every
rejection is the value `(R.error, reason)`; the reason names the first
offending byte:

- A **record** ends at CRLF, LF, or a lone CR; all three are accepted
  so CRLF files, Unix files, and old CR-only files all read. (Inside a
  quoted field CR and LF are data.)
- A **final** line break ends the last record and does not open an
  extra empty record: `"a,b\n"` is one record. An empty line in the
  middle is a record of one empty field.
- An **empty input** is zero records; `"\n"` is one record of one
  empty field.
- A **field** runs to the delimiter, a line break, or end of input.
  Nothing is trimmed: `" a , b "` is `[" a ", " b "]`.
- A **quoted field** begins and ends with `"`, may hold the delimiter,
  CR, and LF, and writes a literal quote as `""`. A `"` inside an
  unquoted field is a mistake, and so is any text between a closing
  quote and the next delimiter or line break.
- Records may be **ragged** — a record's field count is its own
  business; CSV has no schema.
- A single leading UTF-8 **BOM** is the file's encoding mark and is
  removed before parsing. A BOM anywhere else is ordinary data.
- The whole input must be valid **UTF-8**, one encoding per character:
  overlong forms, surrogates, and code points past U+10FFFF are
  rejected, so `decode` accepts exactly what `encode` emits.

## Encode

`encode` is the RFC's canonical writer:

- Every record ends with **CRLF**, the last one included; zero records
  encode as the empty string.
- A field is **quoted** exactly when it holds the delimiter, a `"`,
  CR, or LF. Inside a quoted field `"` becomes `""`. Nothing else is
  escaped, no byte is invented, and no space is trimmed — so
  `decode(encode(rows))` is `rows`.
- Field bytes pass through as the **UTF-8** they are; a field that is
  not valid UTF-8 raises rather than emitting bytes the decoder would
  refuse.

## Errors

The split follows the standard library's convention. Malformed input —
the data can be anything — is the value `(R.error, reason)` from
`decode`, the reason a String stating exactly what failed and at what
byte offset:

```
csv: unterminated quoted field at byte 0
csv: unexpected quote in an unquoted field at byte 2
csv: stray text after a closing quote at byte 3
csv: invalid UTF-8 sequence at byte 0
```

The caller's own mistakes raise, ending the process: a delimiter that
is not a single ASCII byte or that is a quote or a line break
(`csv: the delimiter must be one byte, got 3`), a record with no
fields handed to `encode`, and a field `encode` cannot read as UTF-8.
No error codes, no nil.

## Targets

All five — `ocaml`, `c`, `typescript`, `wasm`, `beam` — byte-identical
on each. The golden (`examples/csv_demo`) rides every target list; the
edge matrix (`examples/csv_edge`) rides the interpreter and the native
binary.
