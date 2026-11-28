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
  def update(el Int64, p ui.Patch)
  def place(el Int64, p ui.Patch)
  def build(n ui.Node) Int64
  def run()
}
```

`backend` is the entry point an application passes to `ui.run`. `mount`
sets the page title and the root declarations, installs the sink, and
appends the rendered tree. `patch` keeps what [`ui.diff`](ui.md) keeps:
a continued node's element stays in the page — its focus, its selection
and its scroll position with it — and takes the new node's props and
styles where it stands; a new or replaced node gets the element its node
builds, and the elements no node keeps leave. `update` does that for one
continued slot; `place` is a container's children under it — read by the
index each had, removed from the last old index up, and set left to right
where the new tree has them; `build` is a node's element with everything
below it. Only a root that is not continued is rebuilt whole.

A button is the same button only while it raises the same event: the
listener an element carries is the one it was given, so a continued
button whose tag changed is replaced. A declaration the old style had and
the new one drops — a width or a height — is taken off the element,
because a style set inline stays until something clears it.

`run()` returns. A page owns the event loop: `mount` installs the
listeners and hands control back, and the loop runs again when the
browser calls one of them.

## Node mapping

`make` gives one element per node, and `paint` gives it the node's own
props and styles:

| Node | Element |
|---|---|
| `Text` | `span` with the body as text |
| `Button` | `button` with `type="button"` and the tag in the `name="event"`/`value` pair, plus a click listener |
| `TextInput` | `input type="text"` showing the model's value; with an event it is editable, its tag rides the `name="emo-<tag>"` pair, its `input` events deliver what was typed, and its `keydown`s deliver Enter and Escape as the key |
| `Image` | `img` with `src` and an empty `alt` |
| `Spacer` | `div` |
| `Column`, `Row`, `Scroll` | `div` with its children appended |

A `text_input` without an event is read-only; one with an event is
editable, and a kept field's value is written back only where the
model's differs — the browser fires no `input` event for a programmatic
write, so the keystrokes typed since the last frame stay. A node class this
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

## The doors

The backend stands on the browser host's `dom_*` calls. Three of them
are the retained patch's own:

- `dom_child(parent, index)` answers the child at an index as its
  handle — `0` when the parent has none there.
- `dom_remove(parent, child)` takes one child away.
- `dom_insert_before(parent, child, before)` puts a child ahead of
  another, at the end when `before` is `0`, and moves it when it already
  sits under the parent.

A node's handle is handed out once and answered again for as long as the
node lives, so two references to one element compare equal and two
elements never do: that is what the patch tells them apart by.

## The gate

`browser/check.sh` is the package's gate. It pins the style mapping's
assertions and the corpus run in `page.mjs` — the stub page, clicking
`0,0,1,2` — and then the backend's own golden, `retained/`: the backend
driven by hand, a frame at a time, and the page read back through
`dom_child`, each element marked `=` when the frame before already had it
and `+` when the frame made it.
