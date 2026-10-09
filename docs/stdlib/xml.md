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

A `require` pairs strictly with the manifest: `xml` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    xml = "0.1.0"
  }
}
```

## Values

A decoded document is a `Xml`: an interface over `XmlElement` and
`XmlText`, discriminated by the `XmlKind` enum. The scalar accessor
`as_text()` answers for a text node and refuses on an element. The
containers live on the element class, read through `is()`:

```emo
const doc = xml.decode(text)
if doc.is(XmlElement) {
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
def decode(text String) Xml
```

Strict and well-formedness checking: elements nest and close in
order, closing tags must match, attributes are unique with quoted
values, and the document has exactly one root. The declaration,
comments, processing instructions, and a DOCTYPE without an internal
subset are skipped; CDATA sections decode as raw text; the five
predefined entities plus `&#ddd;` / `&#xhh;` character references
decode everywhere (text and attribute values). Names are literal — a
prefix stays part of the name, and no namespace resolution happens.
Every failure raises with the byte offset.

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

Following the standard library's convention, every failure —
malformed markup, a mismatched closing tag, a duplicate attribute, an
unknown entity, a missing element or attribute — raises an ordinary
Emo exception whose message states exactly what failed (and at what
byte offset, for decode). No error codes, no nil.
