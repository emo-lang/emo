# The `ui` Package

The portable EmoUI core: one node tree type, the typed style and its
layout vocabulary, the Elm loop with its event tags, and the backend
interface every platform package implements. It is pure Emo — no
platform, no FFI — and declares every hosted target: `ocaml`, `c`,
`typescript`, `browser`, `wasm` and `beam`.

Children are an explicit `Array[Node]`. A trailing block is for
callbacks and iteration, never for collecting children; a child list
that is not known until it is walked is built with `ArrayBuilder` and
handed over as `to_array()`.

## Using the package

```emo
require "emo/ui"
```

The package is `emo/ui` version `0.1.0`; a manifest pins it in `deps`.

## Nodes

```emo
interface Node {
  def style() Style
  def children() Array[Node]
}

def column(children Array[Node], style Style) Node
def row(children Array[Node], style Style) Node
def scroll(children Array[Node], style Style) Node
def text(body String, style Style) Node
def marked_text(body String, start Int64, len Int64, style Style) Node
def button(label String, event Int64, style Style) Node
def text_input(value String, event Int64, style Style) Node
def image(src String, style Style) Node
def spacer(style Style) Node
def keyed(key String, n Node) Node
```

The concrete classes are `Column`, `Row`, `Scroll`, `Text`, `Button`,
`TextInput`, `Image` and `Spacer`; each constructor function returns the
interface type, so a tree is one `Node` value whatever it is built from.
The classes are not invoked in a tree — every component is a lowercase
function, and `.new` never appears. `marked_text` is a `Text` whose
byte span `[start, start + len)` a backend may paint behind the body —
the framebuffer's selection highlight, the one property a backend is
allowed to ignore (a selection is the painter's concern and no layout
depends on it; every other backend paints the body plain). A leaf that
carries an event carries an `Int64` tag rather than a closure — closures
cannot cross the FFI, so the backend delivers the tag and the loop maps
it back to a typed message. `button`'s tag is a click's; `text_input`'s
is the tag its typed text delivers under, registered with `on_text`
below, and `-1` is a display-only field — the mark's convention. A
backend that owns the widget keeps a person's keystrokes across renders:
a kept field's text is written back only where it differs from the
model's value, so the model answers the delivery and nothing else
moves.

A backend narrows a node with `is()` — each backend knows the core
classes plus its own platform's classes, and that union is its dispatch
table.

## Styles

```emo
enum Align { start, center, end, stretch }

def style() Style
```

```emo
class Style {
  def init(padding Float64, gap Float64, align Align, grow Bool,
           width (R, Float64), height (R, Float64))
  def padding() Float64
  def gap() Float64
  def align() Align
  def grow() Bool
  def width() (R, Float64)
  def height() (R, Float64)

  def with_padding(p Float64) Style
  def with_gap(g Float64) Style
  def with_align(a Align) Style
  def with_grow(g Bool) Style
  def with_width(w Float64) Style
  def with_height(h Float64) Style
}
```

`style()` is the empty style; every `with_*` method returns a copy with
one property changed. There are no default parameters (E4009), so the
unstyled call is spelled with the factory: `ui.text("a", ui.style())`.

`(R, Float64)` carries "unset or a value": `(R.ok, 12.0)` is a width or
height, and `(R.error, 0.0)` — the initial state — means the platform
decides. The slot is never read on the error branch. The properties are
the portable layout vocabulary, the intersection every backend can map
onto its own native layout; the TUI and the two native backends keep a
box model that measures this style in cells or points.

## Keys and the diff

```emo
def keyed(key String, n Node) Node
def key_of(n Node) String
def same_kind(a Node, b Node) Bool

def diff(old Node, next Node) Patch
def fresh(next Node) Patch
def gone(p Patch) Array[Int64]
```

```emo
class Patch {
  def node() Node
  def old() (R, Node)
  def kept() Bool
  def was() Int64
  def path() String
  def from() String
  def kids() Array[Patch]
}
```

A tree is rebuilt on every event, and a backend that keeps its widgets —
AppKit, GTK, the DOM — has to know which old node each new one continues.
`diff` answers that once, for every backend: a `Patch` for each slot of
the new tree, beside the node that fills it. It is pure, and
[`debug`](debug.md) renders it as text, so the matching is pinned byte
for byte on every target the way the tree itself is.

**Identity is position and kind.** A child without a key continues the
unkeyed child that held its position among its unkeyed siblings — the
n-th unkeyed child of the old list — when the two are of the same class.
A key overrides position: a keyed child continues the old child with the
same key wherever it moved, and a keyed sibling arriving or leaving
leaves the unkeyed positions alone. A slot whose class changed is
*replaced*, not continued, whatever its key. Two children of one node
under one key is a mistake rather than a choice, and `diff` raises
instead of picking the first.

```emo
// Position: the first slot keeps its widget and takes the new text; the
// last child is new.
[a, b] -> [x, a, b]

// Keys: both keep theirs.
[keyed("a", …), keyed("b", …)] -> [keyed("b", …), keyed("a", …)]
```

A `Patch` reads as:

- `kept` — the widget a backend holds for `old` goes on as this node's.
- `old` — `(R.ok, node)` for a slot that keeps or replaces a node of the
  old tree; `(R.error, _)` for a new one.
- `was` — the old child's index among the old children; `-1` for a new
  child.
- `path` and `from` — the slot's address in the new tree and in the old
  one: the root is `""`, and a child appends its index (`/0/2`).
- `kids` — the new children, in order.

A slot that is not kept is *whole*: every node below it is new. `gone`
lists the old children of a kept container that no new child keeps or
replaces, ascending — a backend removes them from the last index up, so
each index still names the child it did.

`fresh` is a tree as its own diff, every slot new: what a first render is
laid out against. `keyed` is the node it is given, prop for prop, carrying
the key; `key_of` reads it back, `""` when there is none. Both know the
core's classes and no others — `keyed` raises on any other class, since a
platform's own node has no key to set — and `same_kind` is false for a
node the core does not know, so no diff ever continues one: a backend
rebuilds it every frame.

## The loop

```emo
interface Events {
  def deliver(tag Int64, text String) Void
}

class Registry {
  def init()
  def index_of(msg Block, i Int64) Int64
  def on(msg Block) Int64
  def on_text(name String, make Block) Int64
  def message_for(tag Int64, text String) Block
  def dispatch(tag Int64) Block
}

class App {
  def init(view Block, update Block, model Block, backend Backend)
  def deliver(tag Int64, text String) Void
  def root() Node
}

def run(view Block, update Block, model Block, backend Backend) Void
```

An application is a model, a pure `update`, a pure `view`, and a
backend. `view` takes the loop's `Registry` and then the model, and
`update` takes the message and then the model:

```emo
def update(msg Msg, m Model) Model { ... }

def view(reg ui.Registry, m Model) ui.Node {
  const inc = reg.on(Msg.inc)
  return ui.button("+", inc, ui.style())
}

def main() {
  ui.run(view, update, Model.new(0), backend)
}
```

`view`, `update` and the initial model arrive as `Block` because the
core cannot name an application's types; typing resumes at the
application's own signatures.

A tag is the index of the message it stands for, and `on` returns the
tag a message already has — the same message value always maps to the
same tag, so a backend does not see a new widget for the same button on
every render. Equality on class instances is structural, so a field-less
message class (a click's) dedups to one tag like an enum's member does.

A message that carries a value cannot be `on`'d — it is a distinct
message per value, so a message built from a changing string would
allocate a tag per render. `on_text` is the shape for it: the
application registers a *factory*, a block that builds the message from
the typed text, under a name of its choosing, and every later call with
that name returns the same tag. Delivery calls the factory with what was
typed, so `update` receives a message of the application's own class:

```emo
class Typed {
  def init(text String) { self.text = text }
}

def view(reg ui.Registry, m Model) ui.Node {
  const draft = reg.on_text("draft", -> (t String) {
    return Typed.new(text: t)
  })
  return ui.text_input(m.draft(), draft, ui.style())
}
```

The messages of a loop that takes typed text are classes rather than an
enum: `is()` raises on an enum member, so `update` (taking its messages
as `Block`) tells them apart with `is()` chains over class instances.
The registry cannot compare two blocks for equality, so a name already
registered answers its tag and the factory stored first is the one every
delivery goes through — the view passes the same factory each render,
and the name is the contract. An empty name is refused. `message_for`
raises when text rides a tag no field registered: a click tag carries no
text, and a backend that sends some is a wiring mistake, refused where
it is made. `dispatch` raises on a tag that was never registered: an
unregistered tag is a backend bug, not data.

The registry is an object the loop owns and hands to `view`, not a
module-level table: a module-level `const` re-runs its initializer on
every read on the compiled targets, so a table kept there would be
fresh and empty on every read. Two loops in one process keep two
registries.

Take tags in statements of their own before building the tree, as the
corpus and the goldens do: `on` is a side effect, so a statement of its
own keeps the registration order visible at the call site. Operand order
is no longer a cross-target variable — the language states left to
right and every target obeys it (`CHECK.md`, `probe/eval_order`).

### The raw loop

```emo
class RawApp {
  def init(view Block, update Block, model Block, backend Backend)
  def deliver(tag Int64, text String) Void
  def root() Node
}

def run_raw(view Block, update Block, model Block, backend Backend) Void
```

`run_raw` is the loop without the tag table: the backend's tag is the
message, handed to `update` as it arrives. It exists for applications
whose messages are already integers — a text editor's keys, one per
byte and one per editing op — where a table of a hundred entries
deduplicated linearly on every render would cost more than the frame
paints on the metal. `view` still receives a `Registry`, so both loop
shapes keep one application signature; an application that adds a
button under `run_raw` registers it as `run`'s does. The delivery's
text parameter is refused when it is not `""` — the raw loop's message
is the tag itself, and a payload has no integer to be; a field's typed
text belongs to the tagged loop. The key
vocabulary the raw loop's backends and applications share — the
printable bytes, the control chords, and the arrows' numbers above 255
— is the core's: `key_backspace`, `key_tab`, `key_enter`, `key_quit`,
`key_delete`, `key_left`, `key_right`, `key_up`, `key_down`, `key_home`
and `key_end`, and the selection's extension keys `key_shift_left`,
`key_shift_right`, `key_shift_up`, `key_shift_down`, `key_shift_home`
and `key_shift_end` — a seat that tracks Shift answers these in place
of the movement's own number, so an application tells an extending move
from a collapsing one without seeing the modifier.

`run` builds the `App`, hands the first tree and the loop's `Events`
sink to `backend.mount`, and then calls `backend.run()`.

## The backend seam

```emo
interface Backend {
  def mount(root Node, events Events) Void
  def patch(old Node, new Node) Void
  def run() Void
}
```

`mount` receives the first tree and the sink; `patch` receives the tree
the backend last saw and the next one, so a backend may diff or ignore
the old tree: AppKit, GTK and the DOM call `diff` in `patch` and keep
what it keeps, and a backend that repaints whole — the terminal, the
framebuffer, the debug log, a one-shot HTML render — ignores it. `run`
is the backend's own loop: the TUI pulls a scripted or terminal input
and delivers each tag, the native backends enter the toolkit loop, and
the debug, SSR and DOM backends return immediately because the caller or
the page owns the loop.
