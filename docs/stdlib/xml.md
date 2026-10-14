# The `xml` Package

The standard library's XML reader and writer: well-formed XML decoded
into a `Xml` value tree — one interface, an element class and a text
class — and encoded back. Pure Emo over the shared runtimes. XML is
all text: nothing is coerced to numbers or booleans, and all text
children (including whitespace-only ones) are kept, so
encode(decode(x)) reproduces the tree.

## Using the package

```emo
require "xml"
```

The standard library ships with the compiler: `require "xml"` needs no
`package.emo` entry.

## Values

A decoded document is a `Xml`: an interface over `XmlElement` and
`XmlText`, discriminated by the `XmlKind` enum. The scalar accessor
`as_text()` answers for a text node and refuses on an element. The
containers live on the element class, read through `is()`:

```emo
const (R.ok, doc) = xml.decode(text)
if doc.is(xml.XmlElement) {
  println(doc.name())
  println(doc.attr("id"))
  println(doc.get("title").text())
}
```

- `XmlElement` holds `name String`, `attrs Array[(String, String)]`,
  and `children Array[Xml]`. Accessors: `name()`, `attrs()`,
  `attr(name)` (raises on a missing attribute), `children()` (all
  child nodes in document order), `get(name)` (the first child
  element named so; raises when missing), and `text()` (all text in
  the subtree, concatenated in document order).
- `XmlText` holds its characters; `as_text()` answers them.
- Every accessor raises an ordinary Emo exception stating what was
  expected and what was found; `is_text?()` and `kind()` discriminate
  without guessing.

## Decode

```emo
def decode(text String) (R, Xml)
```

Strict and well-formedness checking: elements nest and close in
order, closing tags must match, attributes are unique with quoted
values, and the document has exactly one root. The declaration,
comments, processing instructions, and a DOCTYPE without an internal
subset are skipped; CDATA sections decode as raw text; the five
predefined entities plus `&#ddd;` / `&#xhh;` character references
decode everywhere (text and attribute values). Names are literal — a
prefix stays part of the name, and no namespace resolution happens.
Every failure — a mismatched closing tag, a duplicate attribute, an
unknown entity, an unterminated construct — comes back as
`(R.error, reason)`, the reason a String stating exactly what failed
and at what byte offset: ``xml: closing tag `a` does not match `b` at
byte 8``.

## Encode

```emo
def encode(v Xml) String
```

Elements print `<name a="v">children</name>`, self-closing
(`<name/>`) when childless. Text escapes `&`, `<`, `>`; attribute
values also escape `"`. Everything else rides through as the UTF-8
it already is — the tree round-trips exactly.

## Building values

The factories mirror the kinds; attributes and children go in as
explicit arrays:

```emo
const note = xml.element("note", [], [
  xml.text("hello "),
  xml.element("b", [("k", "v")], []),
])
println(xml.encode(note))
```

## Errors

The split follows the standard library's convention. Malformed markup —
the data can be anything — is the value `(R.error, reason)` from
`decode`, the reason a String stating exactly what failed (and at what
byte offset): match it, don't guess. A missing element or attribute is
the caller's broken assertion about the document — those raise, ending
the process. No error codes, no nil.
