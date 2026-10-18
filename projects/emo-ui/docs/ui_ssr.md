# The `ui_ssr` Package

The server-rendered backend: the portable tree turned into HTML plus the
stylesheet its styles intern into. It is a package of its own —
`emo/ui_ssr`, pinned against `emo/ui` — and declares all five hosted
targets: `ocaml`, `c`, `typescript`, `wasm` and `beam`.

## Using the package

```emo
require "emo/ui"
require "emo/ui_ssr"
```

The package is `emo/ui_ssr` version `0.1.0`; a manifest pins both it
and `emo/ui` in `deps`.

## Nodes this backend adds

```emo
def form(action String, children Array[ui.Node], style ui.Style) ui.Node
def link(href String, label String, style ui.Style) ui.Node
def field(name String, value String, style ui.Style) ui.Node
```

Three nodes live here rather than in the core, because only a server
round trip has anywhere to put them.

A `form` is the round trip: its children submit together, a `ui.button`
inside it contributes its event tag under the name `event`, and every
`field` contributes its own name and value. The method is POST, because
a form changes state.

A `link` is the other interaction: a GET to another page, carrying
nothing back.

A `field` is a named control. The core's `text_input` shows the model's
value and has no name, so the control a submitted body carries is this
one.

## Rendering

```emo
def page(title String, root ui.Node) String
def fragment(root ui.Node) String
def stylesheet(root ui.Node) String
```

`page` is a whole document, titled. The title is the one prop not
carried by the tree — a document has exactly one, and it is not a node —
so it is an argument. The document carries the stylesheet in a `<style>`
element in the head.

`fragment` is a tree's markup alone, for a server that swaps a region of
a page in place of the whole document.

`stylesheet` is the CSS for a tree alone, with the page's base rules in
front of the interned classes.

All three walk the tree pre-order through the same sheet, so the classes
a page's markup carries are the ones its stylesheet defines. A node's
class comes from interning on its base declarations and its `Style`:
equal styles share one rule, while a `row` and a `column` stay distinct.
Every prop reaching markup is escaped byte by byte.

## Escaping

```emo
def escape(s String) String
```

The five entities `&`, `<`, `>`, `"` and `'` are replaced as `&amp;`,
`&lt;`, `&gt;`, `&quot;` and `&#39;`; `&` is replaced first, so an
entity's own ampersand is never produced twice. Escaping works byte by
byte through `substring(i, 1)`, so a multi-byte character rides through
unchanged instead of being split or re-encoded.

## The backend

```emo
def backend(title String) Ssr
```

```emo
class Ssr {
  def init(title String)
  def mount(root ui.Node, events ui.Events)
  def patch(old ui.Node, next ui.Node)
  def run()
  def deliver(tag Int64)
}
```

`mount` prints the whole document and `patch` prints the fragment the
browser swaps in. `run()` returns without driving anything — a server
has no input source; the request is what delivers an event, through
`deliver`.

A node class this renderer does not know raises rather than guessing
markup.
