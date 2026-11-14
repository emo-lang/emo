# The `dom` Package

The read-only DOM: strict HTML parsed into a `Node` tree, queried
with CSS selectors — the shape of Go's goquery, written in pure Emo
over the shared runtimes, so every hosted target answers alike.

## Using the package

```emo
require "dom"
```

with the manifest pinning the exact version:

```emo
deps {
  "dom" = "0.1.0"
}
```

## Parsing: strict, with no synthesized skeleton

```emo
def parse(text String) (R, Document)
def encode(n Node) String
```

Parsing is strict, the xml.decode direction: malformed input answers
`(R.error, reason)` with the byte position, never a repaired tree.
The package does not synthesize `html` / `head` / `body` — the tree
mirrors the source, so a fragment parses into exactly the elements it
names, and `doc.roots()` holds whatever top-level nodes the input
names (typically a doctype, the `html` element, and the text and
comments around them).

The rules a document must satisfy:

- Every element opened must be closed, honestly nested: a close tag
  names the element the stack says is open, or the parse fails
  naming both sides (`</i>` does not close the open `<b>` from byte
  0`).
- The fourteen void elements (`br`, `img`, `input`, `meta`, ...)
  take no close tag, and only they may self-close: `<br>` and
  `<br/>` parse; `<div/>` refuses.
- Tag and attribute names fold to lowercase (the HTML rule);
  `script`/`style` and `title`/`textarea` hold raw text and
  character-references-only text respectively, ending at the
  case-insensitive close tag — markup inside does not parse.
- Attributes are double- or single-quoted, unquoted, or valueless
  (`checked`); a duplicate name on one element refuses.
- Text decodes `&amp;`-style character references: the six common
  named ones (`amp`, `lt`, `gt`, `quot`, `apos`, `nbsp`) plus
  `&#ddd;` and `&#xhh;`. A bare `&` or a raw `<` in text refuses —
  write `&amp;` / `&lt;`. A well-formed but unknown name (`&copy;`)
  passes through literally: that is what the source says.
- Comments and a `<!doctype ...>` ride the tree as nodes; CDATA
  sections and processing instructions refuse.
- Nesting deeper than 512 refuses.

## The node model

```emo
enum NodeKind { element, text, comment, doctype }

interface Node {
  def kind() NodeKind
  def id() Int64                    // the document-order serial
  def is_element?() Bool
  def as_element() Element          // the caller's assertion; raises otherwise
  def tag() String                  // elements; other nodes refuse
  def attrs() Array[(String, String)]
  def attr(name String) (R, String)
  def children() Array[Node]
  def parent() (R, Node)
  def text() String
  def encode() String
}
```

`Element`, `TextNode`, `CommentNode`, and `DoctypeNode` implement
the face; non-elements refuse the element accessors, the xml rule.
`id()` is the parser's document-order serial — the identity two
nodes compare by, stable across every selection. `parent()` answers
`(R.error, reason)` on a document root. `text()` on an element is
its descendant text; on a text or comment node, its own; a doctype's
is the text between `<!` and `>`.

`Document` adds:

```emo
def roots() Array[Node]
def all() Selection        // every node, document order
def find(sel String) (R, Selection)
def encode() String
```

`encode` writes canonical HTML — attributes double-quoted, `&` `<`
`>` escaped, void elements bare — so `parse(encode(x))` reproduces
the tree; it is not byte-identical to the source.

## The selection

A `Selection` is an ordered set of nodes; every operation answers a
fresh one and nothing mutates the tree. The faces follow goquery:

```emo
sel.length() Int64
sel.nodes() Array[Node]
sel.at(i) (R, Node)
sel.eq(i) Selection        // negative counts from the end; out of range is empty
sel.first() Selection
sel.last() Selection
sel.slice(start, end) Selection   // end exclusive; ends clamp, jQuery's slice

sel.attr(name) (R, String)       // the first node; strict
sel.attr_or(name, fallback) String
sel.text() String                // every node's text, in order
sel.html() String                // the first node's inner markup
sel.outer_html() String

sel.find(sel) (R, Selection)     // descendants that match
sel.children() Selection          // element children
sel.children_filtered(sel) (R, Selection)
sel.contents() Selection          // text and comments included

sel.parent() Selection
sel.parents() Selection           // nearest first
sel.parents_filtered(sel) (R, Selection)
sel.closest(sel) (R, Selection)   // nearest ancestor-or-self

sel.next() Selection
sel.next_all() Selection          // document order
sel.next_filtered(sel) (R, Selection)
sel.prev() Selection
sel.prev_all() Selection          // nearest first
sel.prev_filtered(sel) (R, Selection)
sel.siblings() Selection
sel.siblings_filtered(sel) (R, Selection)

sel.filter(sel) (R, Selection)    // the nodes that match
sel.not(sel) (R, Selection)       // those that do not (non-elements stay)
sel.has(sel) (R, Selection)       // those with a matching descendant
sel.is?(sel) (R, Bool)            // any node matches

sel.each(f Block) Selection       // f(i Int64, one Selection); chains
sel.each_with_break(f Block) Bool // f answers false to stop; answers
                                  // whether the walk ran to the end
```

Every door taking a selector compiles it first; a selector that does
not compile answers the error from that door. Traversals
de-duplicate by node id and keep document order (`parents` and
`prev_all` keep their natural nearest-first order, as goquery's do).
`each` rides a trailing block:

```emo
sel.each() -> (i Int64, one dom.Selection) {
  println(i.to_string() + " " + one.text())
}
```

## Selectors

The engine compiles a selector once per door, right-to-left matching
over the tree:

- Compounds: type (`div`, folded to lowercase), `*`, `.class`
  (case-sensitive, several allowed: `.a.b`), `#id`
  (case-sensitive), and attribute tests — `[attr]`, `[attr=v]`,
  `^=`, `$=`, `*=`, `~=`, `|=`, values quoted or bare.
- Combinators: descendant (whitespace), `>`, `+`, `~`; comma
  separates groups (`h1, h2`).
- Pseudo-classes: `:first-child`, `:last-child`, `:only-child`,
  `:nth-child(an+b)` (also `odd`, `even`, `2`, `-n+3`),
  `:nth-last-child(...)`, `:first-of-type`, `:last-of-type`,
  `:only-of-type`, `:nth-of-type(...)`, `:not(compound)`,
  `:empty`, `:root`, and goquery's `:contains("text")` — a
  case-sensitive substring test over the element's text. A root
  element reads as the first child, as browsers read `html`.

Everything else refuses with the position: pseudo-elements
(`::before`, and the single-colon names), unknown pseudo-classes,
selector string escapes, malformed attribute tests, dangling
combinators. A refusal is a value from the door that took the
selector — `find` never silently matches nothing.

## Errors

Expected failure is a value throughout, the xml shape:

```emo
case dom.parse(page) {
  (R.error, why) then { println(why) }   // "dom: ... at byte 84"
  (R.ok, doc)    then { ... }
}
```

Parse reasons carry the byte position and both sides of a nesting
mistake; selector reasons carry the byte position within the
selector. The accessors a node cannot honestly answer (`tag()` on a
text node) raise — the caller's assertion, json's rule.

## Example

[`examples/dom_demo`](../../examples/dom_demo/) walks the page
through find, slicing, attributes, pseudo-classes, traversal,
filtering, `each`, and the encode round trip;
[`examples/dom_edge`](../../examples/dom_edge/) walks the strict
refusals, the character-reference corners, raw text, attribute
shapes, fragments, and the selector compiler's refusals. Both run
byte-identically on the interpreter and the compiled targets.

## Limitations

- No DOM mutation: the package reads and queries; building or
  reshaping a tree is not its business.
- No HTML5 tree construction: no `html`/`head`/`body` synthesis, no
  implied end tags (`<li>a<li>b` refuses), no foster parenting — a
  strict reader of what the source names.
- The six common named character references only; the full HTML5
  entity table is not carried. Unknown but well-formed names pass
  through literally.
- Selector escapes (`\.`), namespaces, `:has(...)` as a
  pseudo-class, and case-insensitivity flags are not carried;
  pseudo-elements refuse. `has` exists as the `Selection` method.
- `Add` / `AddBack` / `End` (the selection-stack doors) are not
  carried.
