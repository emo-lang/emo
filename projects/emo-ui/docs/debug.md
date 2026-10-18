# The `debug` Module

The headless backend and the stable text form the goldens are written
in. It is a module of the `emo/ui` package — `debug.emo` sits beside
`ui.emo` — rather than a package of its own, because it carries no
platform and no native code.

## Using the module

```emo
require "emo/ui"
```

The module is reached through the package's module path:
`ui.debug.render`, `ui.debug.Debug`.

## Rendering a tree

```emo
def render(n ui.Node) String
def render_at(n ui.Node, depth Int64) String
```

`render` turns a whole tree into stable text: one node per line, two
spaces per level, the node's own props first and then a style summary in
a fixed field order. `render_at` is the same walk for a subtree that
already has a depth. There is no overloading to lean on — a def name
carries one signature — so the two are separate names.

The format is:

```text
Column pad=0.0 gap=0.0 align=start grow=false w=auto h=auto
  Text "Inbox" pad=0.0 gap=0.0 align=start grow=false w=auto h=auto
  Button "inc" #0 pad=0.0 gap=0.0 align=start grow=false w=auto h=auto
```

A string prop is quoted verbatim, not escaped; a value carrying a
newline therefore spans lines. Only `String`, `Int64`, `Bool` and
`Float64` are interpolated, because printing an enum or a tuple is not
the same bytes on every target — the style summary destructures the
`Align` and the `(R, Float64)` slots instead. A node class the walk does
not know prints as `Unknown ${n}`, which is a diagnostic, never golden
material.

## The backend

```emo
class Debug {
  def init()
  def mount(root ui.Node, events ui.Events)
  def patch(old ui.Node, next ui.Node)
  def run()
  def deliver(tag Int64)
  def log() Array[String]
}
```

`Debug` implements `ui.Backend` by rendering every tree the loop hands
it into a log instead of printing it, so the caller decides when the
text reaches stdout. `log()` returns the rendered trees in delivery
order.

`run()` drives nothing: the backend has no input source, which is what
headless means here. An event is stepped by hand through `deliver`, on
the sink `mount` was given.

## Helpers

```emo
def align_name(a ui.Align) String
def extent(slot (R, Float64)) String
def brief(s ui.Style) String
```

The pieces the summary is built from, exported because the module's own
walk uses them: the `Align` name, the `(R, Float64)` slot as a number or
`auto`, and the whole fixed-order summary line.
