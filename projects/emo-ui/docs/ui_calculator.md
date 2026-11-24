# The `ui_calculator` Package

The calculator: the first application under `apps/`, written once and
run on every EmoUI backend. It is a package of its own —
`emo/ui_calculator`, pinned against `emo/ui` — and carries no platform.
Each platform's entry requires it and hands its functions to `ui.run`;
between backends only the backend package and that entry differ. What
the application is, how it is run on each platform and what it could not
say about EmoUI are in [`apps/calculator/README.md`](../apps/calculator/README.md).

## Using the package

```emo
require "emo/ui"
require "emo/ui_calculator"
```

The package is `emo/ui_calculator` version `0.1.0`, and it declares all
seven targets; a manifest pins both it and `emo/ui` in `deps`.

## The application

```emo
enum Op { none, add, sub, mul, div }
enum Msg { clear, back, sign, d0, d1, d2, d3, d4, d5, d6, d7, d8, d9,
           dot, add, sub, mul, div, equals }

class Model {
  def init(acc Float64, op Op, entry String, typing Bool, err Bool,
           again_op Op, again_y Float64)
  def acc() Float64
  def op() Op
  def entry() String
  def typing() Bool
  def err() Bool
  def again_op() Op
  def again_y() Float64
}

def initial() Model
def update(msg Msg, m Model) Model
def display(m Model) String
def view(reg ui.Registry, m Model) ui.Node
def view_at(reg ui.Registry, m Model, unit Float64) ui.Node
```

`Model` is what the calculator knows between two keys, and an instance
is a value: `update` answers a new one and prints nothing. `display` is
what the display shows — the entry being typed, the value reached, or
`Error` — and is the only thing an application's state is observed
through.

`view` registers the nineteen messages in the keypad's order and builds
the display above five rows of keys. Every key asks for an equal share of
its row and carries no size. `view` lays the calculator out for a
terminal, in cells; `view_at` takes the gap between keys and the margin
around them in the platform's own unit, which is why an entry — and only
an entry — calls it.

## The keypad

```emo
def keypad() Array[Array[Msg]]
def label_of(msg Msg) String
def msg_of(label String) Msg
def tag_of(label String) Int64
def tags_of(labels Array[String]) Array[Int64]
def script_of(labels Array[String]) String
```

`keypad()` is the keys row by row, top row first:

| | | | |
|---|---|---|---|
| `C` | `<` | `+/-` | |
| `7` | `8` | `9` | `/` |
| `4` | `5` | `6` | `*` |
| `1` | `2` | `3` | `-` |
| `0` | `.` | `+` | `=` |

A key's tag is its place in that order, read row by row: `tag_of("C")`
is 0 and `tag_of("=")` is 18. The tag is the same in every entry of one
run, because `view` takes the tags in that order from the loop's
`Registry` before it builds anything; an entry or a test names keys by
their labels (`msg_of`, `tag_of`) and never by a number. `msg_of`
raises when no key carries the label.

## The sessions

```emo
def session() Array[String]
def tags() Array[Int64]
def script() String
def window_length() Int64
def window_session() Array[String]
def window_tags() Array[Int64]
def window_script() String
def page_length() Int64
def page_session() Array[String]
def page_tags() Array[Int64]
```

One session, named key by key: `session()` is 159 labels, `window_session()`
its first 54 and `page_session()` its first 6. Each `*_tags()` is the
session as tags for a backend that steps its own events, and `script()`
and `window_script()` the same as one comma-separated line for a harness
or a window's shim that takes tags that way.

## The numbers

`number.emo` is the arithmetic the calculator is made of, reached from
outside as `ui_calculator.number`; every piece of it is spelled one way
on every target.

```emo
def limit() Float64
def inside(x Float64) Bool
def parse(entry String) Float64
def add(a Float64, b Float64) (R, Float64)
def sub(a Float64, b Float64) (R, Float64)
def mul(a Float64, b Float64) (R, Float64)
def div(a Float64, b Float64) (R, Float64)
def format(x Float64) String
```

`parse` reads a typed
decimal ("12", "12.", "-0.5") by byte; `format` writes twelve significant
digits in `Int64` arithmetic — plain while the plain form is short, in a
power of ten beyond it (`1e+15`, `3.33333333333e-6`) — and `Error` for a
value past the range. The four operations answer `(R.ok, value)` or
`(R.error, why)` and check before the arithmetic that could raise: a
division by zero is a failure everywhere, and so is a result outside
`limit()`, because the interpreter and `ocaml` make `x / 0.0` a runtime
error and `beam` raises on a float that overflows.

## Entries and the gate

| Entry | Backend |
|---|---|
| `apps/calculator/debug` | `ui.debug` |
| `apps/calculator/ssr` | `ui_ssr` |
| `apps/calculator/tui` | `ui_tui` |
| `apps/calculator/fb` | `ui_fb` |
| `apps/calculator/macos` | `ui_macos` |
| `apps/calculator/gtk` | `ui_gtk` |
| `apps/calculator/browser` | `ui_browser` |

All seven are gated by `apps/calculator/check.sh`, which
`projects/emo-ui/check.sh` runs with the backends' own gates. It stages
every package the entries reach into a content-named registry and pins
one `expected.txt` — the headless entry's trace, the display after every
frame of the hosted session — on every entry: whole where a frame is a
line, its first lines where a frame is a screen or a document. The
headless and server-rendered entries are byte-identical on all five
hosted targets, the terminal entry on the four that can write stdout and
the framebuffer entry on four, with its `beam` leg on the page session.
