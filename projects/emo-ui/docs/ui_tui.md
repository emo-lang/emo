# The `ui_tui` Package

The terminal backend: the portable tree measured in character cells and
painted as ANSI. The terminal has no native layout engine, so this
package carries its own box model. It is a package of its own —
`emo/ui_tui`, pinned against `emo/ui` — and declares the four hosted
targets that can write stdout: `ocaml`, `c`, `typescript` and `beam`.
`wasm` has no `printf` and is not a target.

## Using the package

```emo
require "emo/ui"
require "emo/ui_tui"
```

The package is `emo/ui_tui` version `0.1.0`; a manifest pins both it
and `emo/ui` in `deps`.

## The backend

```emo
def backend(width Int64, height Int64, input Input) ui.Backend
```

```emo
class Tui {
  def init(width Int64, height Int64, input Input)
  def mount(root ui.Node, events ui.Events)
  def patch(old ui.Node, next ui.Node)
  def run()
}
```

`backend` is the entry point an application passes to `ui.run`. The
frame is `width` by `height` character cells; `mount` and `patch` both
paint the current tree from scratch — the old tree is an offer a
terminal never needs. `run` pulls event tags from the input and hands
each one to the loop's sink until the input says there are no more.

## Input

```emo
interface Input {
  def next() (R, Int64)
}

def script(tags Array[Int64]) Input
```

`Input` is the backend's event source: `next` answers `(R.ok, tag)` for
an event or `(R.error, _)` when the source is exhausted. `script` is
the deterministic source the gates run on — a fixed list of tags,
consumed once, then `(R.error, _)` forever. A real terminal source
reads raw-mode keys through the standard library's `term` package;
wiring it in replaces the source, not the seam.

## The frame as data

```emo
def screen(root ui.Node, width Int64, height Int64) Array[String]
def paint(root ui.Node, width Int64, height Int64)
```

`screen` returns the painted grid as `height` strings of `width`
columns, so the layout arithmetic is testable without bytes. `paint`
writes the same frame to stdout as ANSI — clear, home, one row per line
— with the escape byte emitted through `printf("%c", [27])`.

## The box model

The model is in cells. A column stacks its children downward inside its
padding, one `gap` apart; a row lines them up left to right. `grow`
takes an equal share of the space left over, and the last growing child
takes the remainder so the box stays flush. `align` places children
across the other axis, `width` and `height` fix an extent, and `padding`
insets the whole box.

`Scroll` is a vertical box for now — the terminal has no viewport
offset yet, so it stacks like a column.

The exported helpers — `Extent` and `Draw`, `measure`, `place` and the
`place_column`/`place_row` cases, plus `blank`/`fit`/`splice`/`with_row`
— are the box model's own names. They are reachable, but the supported
surface is `backend`, `screen`, `paint`, `Input` and `script`.
