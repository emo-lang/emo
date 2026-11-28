# The `ui_gtk` Package

The GTK 4 backend: the portable tree laid out in points by a pure Emo
box model and painted into a native window. It is a package of its own —
`emo/ui_gtk`, pinned against `emo/ui` — declares the `c` target, and
names the `gtk4` pkg-config module in its manifest. The shape is the
same as `ui_macos`: `box.emo` carries the point model, `ui_gtk.emo` the
class and the foreign verbs, and `shim.c` the C side.

## Using the package

```emo
require "emo/ui"
require "emo/ui_gtk"
```

The package is `emo/ui_gtk` version `0.1.0`; a manifest pins both it
and `emo/ui` in `deps`. It builds where `pkg-config gtk4` answers.

The interpreter refuses foreign code (E3009) and the other targets
refuse the package at resolution, so `emo run` cannot execute a program
that touches it; build with `emo build` (the default target is `c`).

## The backend

```emo
def backend(title String, width Float64, height Float64, script String) ui.Backend
```

```emo
class Gtk {
  def init(title String, width Float64, height Float64, script String)
  def mount(root ui.Node, events ui.Events)
  def patch(old ui.Node, next ui.Node)
  def paint(p ui.Patch)
  def run()
}
```

`backend` is the entry point an application passes to `ui.run`. The
window is `width` by `height` points, taken as arguments; reading the
screen size and reflowing on resize is not wired yet. Every frame keeps
what [`ui.diff`](ui.md) keeps, the way `ui_macos` keeps it: a leaf the
diff continues keeps its widget — its focus with it — and is given the
new node's text and frame where it stands; a leaf that is new or
replaced gets a fresh widget, and the widgets no leaf keeps leave.

`script` is the self-driving input, the counterpart of the terminal's
`Script`: a comma-separated list of steps — a bare tag is a click on the
control carrying it, `tag=text` types into the field carrying the tag.
It is
honored only when `EMO_GUI_AUTOTEST` is set, so a real application
passes `""` and a person drives the window.

## The box model

The core's `Style` is measured in points by `box.emo`:

```emo
def layout(root ui.Node, width Float64, height Float64) Array[Draw]
def layout_of(p ui.Patch, width Float64, height Float64) Array[Frame]
```

`layout` returns the leaves that will be drawn and where; the arithmetic
runs in the interpreter without a display, so a test can read the frame
a window would paint. `place` applies x and y unchanged, because
GtkFixed's origin is already the top left — the one difference from
`ui_macos`'s box model, which flips y. `layout_of` is the walk for a
diff, each frame beside the slot its leaf fills; [`ui_macos`](ui_macos.md)
describes it, and the two box models are the same module.

The exported names `Extent`, `Draw`, `Frame`, `Kind`, `measure`, `place`
and the `place_column`/`place_row` cases are the box model's own;
`layout` and `layout_of` are the entry points.

## The native shim

`ui_gtk.emo` declares the same ten foreign defs as `ui_macos`:
`ui_window_make`, `ui_label_make`, `ui_button_make`, `ui_set_text`,
`ui_place`, `ui_remove`, `ui_connect`, `ui_root`, `ui_run` and
`ui_autotest_arm`. GTK is already C, so `shim.c` is thinner than the
AppKit shim — the signal handler and the self-driving script are what
Emo cannot name. `ui_place` moves a widget already on the canvas, and
`ui_connect` connects a button's handler once and leaves the tag to be
read as the click lands, so a kept button can take a new one between
frames. The loop's sink crosses the FFI as the same `ui.Events`
trampoline and userdata pair; a click carries its tag and an empty
text, a field's "changed" signal carries the tag and what was typed. A
kept field's text is written back only where the model's value differs,
and the programmatic write is flagged so the signal it fires delivers to
no one.

## The gate

`gtk/check.sh` is the package's gate. It builds and runs natively where
`pkg-config gtk4` answers; otherwise it compiles and runs the same
generated C in the `emo-ui-gtk-build` container (GTK 4 plus Xvfb),
which is how a macOS host checks it. With neither it says so and
passes. The run pins the corpus's bytes, and — through `EMO_GUI_COUNT`,
a file the shim writes its widget count into — that the window kept its
widgets: the first frame's eight, and no more.
