# The `ui_browser` Package

The DOM backend: the portable tree rendered into the page over the
browser runtime's `dom_*` family. It is a package of its own —
`emo/ui_browser`, pinned against `emo/ui` — and declares the `browser`
target added by the T48.10 runtime path. There is no shim and no C ABI:
the runtime's browser host owns the `document`, and a DOM node crosses
into Emo as an `Int64` handle.

## Using the package

```emo
require "emo/ui"
require "emo/ui_browser"
```

The package is `emo/ui_browser` version `0.1.0`; a manifest pins both it
and `emo/ui` in `deps`. A page is built with `emo build --target
browser`, whose bundling step needs Node >= 22.13.

## The backend

```emo
def backend(title String) ui.Backend
```

```emo
class Dom {
  def init(title String)
  def mount(root ui.Node, events ui.Events)
  def patch(old ui.Node, next ui.Node)
  def render(n ui.Node) Int64
  def container(kind String, n ui.Node) Int64
  def run()
}
```

`backend` is the entry point an application passes to `ui.run`. `mount`
sets the page title and the root declarations, installs the sink, and
appends the rendered tree. `patch` clears the root and appends a fresh
render — the old tree is an offer, and a retained DOM diff is the
reconciliation work that is still open. The listeners are rebuilt with
the elements, so the tree a click delivers from is always the tree the
loop last rendered.

`run()` returns. A page owns the event loop: `mount` installs the
listeners and hands control back, and the loop runs again when the
browser calls one of them.

## Node mapping

`render` builds one element per node:

| Node | Element |
|---|---|
| `Text` | `span` with the body as text |
| `Button` | `button` with `type="button"` and the tag in the `name="event"`/`value` pair, plus a click listener |
| `TextInput` | read-only `input type="text"` showing the model's value |
| `Image` | `img` with `src` and an empty `alt` |
| `Spacer` | `div` |
| `Column`, `Row`, `Scroll` | `div` with its children appended |

A `text_input` is read-only for the same reason `ui_ssr` renders it
that way: the core node carries no event tag, so typing has nowhere to
go until a node with an event of its own exists. A node class this
renderer does not know raises rather than guessing an element.

## Styles

```emo
def declarations(kind String, s ui.Style) Array[(String, String)]
def root_declarations() Array[(String, String)]
```

`css.emo` maps the portable `Style` onto the declarations the page's own
layout consumes; it is pure Emo, so the interpreter runs its tests. The
pair list is applied with `dom_set_style`, so the browser's layout
engine does the layout — this package carries no box model.
`root_declarations` is the page root's own set (the box model bootstrap
the document needs before a tree is appended).
