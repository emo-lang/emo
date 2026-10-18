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
def button(label String, event Int64, style Style) Node
def text_input(value String, style Style) Node
def image(src String, style Style) Node
def spacer(style Style) Node
```

The concrete classes are `Column`, `Row`, `Scroll`, `Text`, `Button`,
`TextInput`, `Image` and `Spacer`; each constructor function returns the
interface type, so a tree is one `Node` value whatever it is built from.
The classes are not invoked in a tree — every component is a lowercase
function, and `.new` never appears. `button` is the only leaf that
carries an event, and it carries an `Int64` tag rather than a closure:
closures cannot cross the FFI, so the backend delivers one integer and
the loop maps it back to a typed message.

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

## The loop

```emo
interface Events {
  def deliver(tag Int64) Void
}

class Registry {
  def init()
  def index_of(msg Block, i Int64) Int64
  def on(msg Block) Int64
  def dispatch(tag Int64) Block
}

class App {
  def init(view Block, update Block, model Block, backend Backend)
  def deliver(tag Int64) Void
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
every render. A message that carries a value is a distinct message per
value, so a message built from a changing string allocates a tag per
render. `dispatch` raises on a tag that was never registered: an
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
the old tree. `run` is the backend's own loop: the TUI pulls a scripted
or terminal input and delivers each tag, the native backends enter the
toolkit loop, and the debug, SSR and DOM backends return immediately
because the caller or the page owns the loop.
