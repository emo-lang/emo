# Getting started with EmoUI

EmoUI is Emo's UI framework: one declarative tree of components that
renders on a macOS/AppKit window, a GTK 4 window, a terminal, a
server-rendered page, and the browser DOM. An application is plain Emo —
a model, a pure `update`, a pure `view` — and the backend is the only
platform-specific piece.

This guide builds two applications from scratch: a window that says
Hello, World, and a counter with plus and minus buttons. Both are
complete: each example's `package.emo` and `main.emo` are shown in full.

## The pieces

- **`emo/ui`** is the portable core: the node constructors (`column`,
  `row`, `text`, `button`, ...), the typed `Style`, the loop (`ui.run`),
  and the backend seam. It is pure Emo and names no platform.
- **A backend package** paints the tree: `emo/ui_macos`,
  `emo/ui_gtk`, `emo/ui_tui`, `emo/ui_ssr`, `emo/ui_browser`, and the
  headless `ui.debug`.
- **The applications below are identical on every backend.** Changing
  the last line of `main` — and the backend in the manifest — moves the
  same window to GTK, the terminal, a web page, or the browser.

EmoUI lives in this repository under `projects/emo-ui/`; its packages
are versioned `0.1.0` and are not part of the bundled standard library.
The examples use the macOS backend and the `c` target. Stage the
repository's packages into a registry first, as the project's own gates
do:

```console
$ cd <emo checkout>
$ scripts/stage-registry.sh "$PWD/.emo-registry"
$ export EMO_REGISTRY="$PWD/.emo-registry"
```

A native window is a built program, not an interpreter run: `emo run`
refuses foreign code (E3009), so build with `emo build` and start the
binary.

## 1 · Hello, World

The first application is a window with one line of text.

```emo
// package.emo
package {
  name = "emo/hello_ui"
  version = "0.1.0"
  targets = ["c"]

  deps {
    "emo/ui" = "0.1.0"
    "emo/ui_macos" = "0.1.0"
  }
}
```

```emo
// main.emo
require "emo/ui"
require "emo/ui_macos"

def view(reg ui.Registry, model Int64) ui.Node {
  return ui.column([
    ui.text("Hello, World", ui.style())
  ], ui.style().with_padding(24.0))
}

def update(msg Int64, model Int64) Int64 {
  return model
}

def main() {
  ui.run(view, update, 0, ui_macos.backend("Hello, World", 320.0, 120.0, ""))
}

main()
```

Build and run it in the directory holding both files:

```console
$ emo build main.emo --target c -o hello
$ ./hello
```

A window titled "Hello, World" opens, 320 by 120 points, with the text
24 points in from its edges. The first build also writes
`package.lock`; keep it beside the manifest.

What each part does:

- **`ui.column([...], style)`** is the root. Children are an explicit
  `Array[ui.Node]` — never a block and never an implicit child list.
- **`ui.text("Hello, World", ui.style())`** is a leaf. `ui.style()` is
  the empty style; `with_padding` returns a copy with one property set.
- **`view`** builds the tree from the model. It is pure, and the loop
  calls it again for every frame.
- **`update`** is the loop's other half. Nothing can change in this
  window, so it returns the model unchanged — but the loop requires the
  function.
- **`ui.run(view, update, 0, backend)`** starts the loop with `0` as the
  initial model (an `Int64` here).
- **`ui_macos.backend(title, width, height, script)`** is the platform
  entry. The size is in points; the last argument is the self-driving
  input script a test uses, so a real application passes `""`.

## 2 · The loop and the backend seam

The whole framework fits in one cycle:

```text
model ──view──▶ tree ──backend──▶ window
  ▲                                 │
  └──────── update ◀── event tag ◀──┘
```

`view` receives the loop's `Registry` and the model. A button does not
carry a closure; it carries an **`Int64` tag**, because closures cannot
cross the FFI. `reg.on(msg)` registers a message and returns its tag:

```emo
const plus = reg.on(Msg.inc)
```

Take tags in statements of their own, before the tree is built: `on` is
a side effect, and the statements keep the registration order visible.
When the user clicks, the backend delivers the tag, the loop maps it
back to the message, calls `update`, and rebuilds the view. The model is
a value: `update` returns a new one rather than mutating the old.

A backend implements three methods — `mount(root, events)`,
`patch(old, next)`, and `run()` — and knows an event only as an integer.
That is why the same application runs everywhere:

| Backend | Entry the application passes to `ui.run` | Targets |
| --- | --- | --- |
| macOS / AppKit | `ui_macos.backend(title, width, height, script)` | `c` on macOS |
| GTK 4 | `ui_gtk.backend(title, width, height, script)` | `c` with GTK 4 |
| Terminal | `ui_tui.backend(width, height, input)` | `ocaml`, `c`, `typescript`, `beam` |
| Server page | `ui_ssr.backend(title)` (or `ui_ssr.page(title, root)`) | all five hosted |
| Browser | `ui_browser.backend(title)` | `browser` |
| Headless | `ui.debug.render(root)` | every hosted target |

The app code below does not change when the backend does; only the
last line of `main` and the manifest's `deps`/`targets`.

## 3 · Counter

The second application holds a number and changes it: two buttons, plus
and minus, and a line showing the count.

```emo
// package.emo
package {
  name = "emo/counter_ui"
  version = "0.1.0"
  targets = ["c"]

  deps {
    "emo/ui" = "0.1.0"
    "emo/ui_macos" = "0.1.0"
  }
}
```

```emo
// main.emo
require "emo/ui"
require "emo/ui_macos"

enum Msg {
  inc,
  dec
}

def update(msg Msg, count Int64) Int64 {
  case msg {
    Msg.inc then { return count + 1 }
    Msg.dec then { return count - 1 }
  }
}

def view(reg ui.Registry, count Int64) ui.Node {
  const plus = reg.on(Msg.inc)
  const minus = reg.on(Msg.dec)
  return ui.column([
    ui.text("${count}", ui.style().with_width(60.0).with_grow(true)),
    ui.row([
      ui.button("+", plus, ui.style().with_grow(true)),
      ui.button("-", minus, ui.style().with_grow(true))
    ], ui.style().with_gap(8.0))
  ], ui.style().with_padding(16.0).with_gap(16.0))
}

def main() {
  ui.run(view, update, 0, ui_macos.backend("Counter", 260.0, 160.0, ""))
}

main()
```

Build and run it the same way:

```console
$ emo build main.emo --target c -o counter
$ ./counter
```

A 260-by-160 window opens with `0` at the top and the two buttons below
it. Clicking `+` sends the `inc` tag, `update` returns `count + 1`, and
the loop rebuilds the view; the backend keeps the existing text widget
and changes only its body, so the window does not flicker. Clicking `-`
does the same in the other direction.

What each part does:

- **`enum Msg { inc, dec }`** is the message type. A message can be an
  enum, a tuple, or any value; here two members are enough.
- **`update`** matches the message with `case` and returns the next
  model. The model is an `Int64`; there is no mutable state to update.
- **`reg.on(Msg.inc)`** turns each message into the tag its button
  carries. The tags are taken before the tree, in their own statements.
- **`ui.text("${count}", ...)`** renders the model, because `view` sees
  the current one on every frame.
- **`ui.row([...], style)`** lines the two buttons up horizontally;
  `with_grow(true)` gives each button an equal share of the row, and
  `with_gap(8.0)` separates them.
- **`ui.run(view, update, 0, ...)`** starts the count at zero.

The counter can go below zero, and nothing stops it — a product rule
would live in `update`, not in the buttons. That is the point of the
loop: `update` owns the policy, `view` owns the picture, and the backend
owns the platform.

## 4 · Layout and styles in one page

- **Containers** are `ui.column`, `ui.row`, and `ui.scroll`; each takes
  an `Array[ui.Node]`. A list known only at runtime is built with
  `ArrayBuilder` and handed over as `to_array()`.
- **Leaves** are `ui.text`, `ui.button`, `ui.text_input`, `ui.image`,
  and `ui.spacer`. `ui.button` is the only leaf that carries an event.
- **Styles are immutable values.** `ui.style()` is empty; every
  `with_*` returns a copy with one property set: `with_padding`,
  `with_gap`, `with_align`, `with_grow`, `with_width`, `with_height`.
  There are no default parameters, so the unstyled call spells the
  factory out: `ui.text("a", ui.style())`.
- **Widths and heights are `(R, Float64)`**: `(R.ok, 12.0)` is a size,
  `(R.error, 0.0)` lets the platform decide. The counters above use
  `grow` rather than fixed widths, because a `Style` number is a point
  on macOS and GTK, a character cell on the terminal, and a pixel in the
  browser — a fixed size is not portable between them.
- **Keys** (`ui.keyed("id", node)`) keep a child's identity when a list
  reorders. Without a key, identity is position and class.

## 5 · Where next

- [`projects/emo-ui/apps/calculator/`](../../projects/emo-ui/apps/calculator/)
  — the complete worked application: a model, a pure update, a pure
  view, and seven backend entries (debug, TUI, SSR, macOS, GTK,
  browser, framebuffer) sharing one app module.
- [`projects/emo-ui/docs/ui.md`](../../projects/emo-ui/docs/ui.md) — the
  core reference: nodes, styles, the diff, and the loop.
- The backend references beside it:
  [`ui_macos`](../../projects/emo-ui/docs/ui_macos.md),
  [`ui_gtk`](../../projects/emo-ui/docs/ui_gtk.md),
  [`ui_tui`](../../projects/emo-ui/docs/ui_tui.md),
  [`ui_ssr`](../../projects/emo-ui/docs/ui_ssr.md),
  [`ui_browser`](../../projects/emo-ui/docs/ui_browser.md), and
  [`debug`](../../projects/emo-ui/docs/debug.md).
- [`emo-ui.md`](../emo-ui.md) — why the framework is shaped this way,
  and what the evidence for it was.
- [`projects/emo-ui/README.md`](../../projects/emo-ui/README.md) — the
  package map, the convergence corpus, and the gates.
