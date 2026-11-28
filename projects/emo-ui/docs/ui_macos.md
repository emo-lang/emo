# The `ui_macos` Package

The macOS/AppKit backend: the portable tree laid out in points by a pure
Emo box model and painted into a native window. It is a package of its
own — `emo/ui_macos`, pinned against `emo/ui` — declares the `c` target,
and links the `AppKit` framework through `frameworks` in its manifest.
`shim.m` is the project's only Objective-C outside `spike/`.

## Using the package

```emo
require "emo/ui"
require "emo/ui_macos"
```

The package is `emo/ui_macos` version `0.1.0`; a manifest pins both it
and `emo/ui` in `deps`. It builds on Darwin only.

The interpreter refuses foreign code (E3009) and the other targets
refuse the package at resolution, so `emo run` cannot execute a program
that touches it; build with `emo build` (the default target is `c`).

## The backend

```emo
def backend(title String, width Float64, height Float64, script String) ui.Backend
```

```emo
class Mac {
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
what [`ui.diff`](ui.md) keeps: `mount` lays the first tree out as a diff
in which every slot is new, and `patch` lays the diff of the tree the
backend last saw against the next one. A leaf the diff continues keeps
its widget — its focus with it — and is given the new node's text and
frame where it stands; a leaf that is new or replaced gets a fresh
widget, and the widgets no leaf keeps leave. A kept button is given the
new tag when its event changed.

`script` is the self-driving input, the counterpart of the terminal's
`Script`: a comma-separated list of steps — a bare tag is a click on the
control carrying it, `tag=text` types into the field carrying the tag.
It is
honored only when `EMO_GUI_AUTOTEST` is set, so a real application
passes `""` and a person drives the window. A `NSTimer` clicks each tag
in turn and terminates, so the gate needs no one at the keyboard and no
screenshot.

## The box model

The core's `Style` is measured in points by `box.emo`:

```emo
def layout(root ui.Node, width Float64, height Float64) Array[Draw]
def layout_of(p ui.Patch, width Float64, height Float64) Array[Frame]
```

`layout` returns the leaves that will be drawn and where; the arithmetic
runs in the interpreter without a window server, so a test can read the
frame a window would paint. A column stacks, a row lines up, `grow`
shares the leftover space, and `align` places children across the other
axis. `place` flips y, because AppKit's origin is the bottom left.

`layout_of` is the same walk for a diff: each frame comes back beside
the slot its leaf fills, as a `Frame`, which is what lets the backend
tell a leaf it already has a widget for from one it has not. `layout` is
`layout_of` of `ui.fresh`, the tree as its own diff.

The exported names `Extent`, `Draw`, `Frame`, `Kind`, `measure`, `place`
and the `place_column`/`place_row` cases are the box model's own;
`layout` and `layout_of` are the entry points.

## The native shim

`ui_macos.emo` declares ten foreign defs against `shim.m`:

```emo
foreign def ui_window_make(title String, w Float64, h Float64) Int64 = "ui_window_make"
foreign def ui_label_make(text String) Int64 = "ui_label_make"
foreign def ui_button_make(text String) Int64 = "ui_button_make"
foreign def ui_set_text(child Int64, text String) Void = "ui_set_text"
foreign def ui_place(child Int64, x Float64, y Float64, w Float64, h Float64) Void = "ui_place"
foreign def ui_remove(child Int64) Void = "ui_remove"
foreign def ui_connect(child Int64, tag Int64) Void = "ui_connect"
foreign def ui_root() Int64 = "ui_root"
foreign def ui_run(events ui.Events) Void = "ui_run"
foreign def ui_autotest_arm(script String) Void = "ui_autotest_arm"
```

The loop's sink crosses the FFI as `ui.Events`, a single-method
interface, which the C ABI hands over as a trampoline and a userdata
pair; a click carries its tag back through that pair, so the
application's types never cross the FFI. `ui_set_text` and `ui_remove`
are the verbs a kept frame needs; `ui_place` moves a view as readily as
it places a new one. The ten verbs are the native implementation detail
behind `ui.Backend`.

## The gate

`macos/check.sh` is the package's gate and runs only on Darwin. It
pins the `c` build, the box model's assertions and the convergence
corpus entry (`macos/corpus/`) driven by the `0,0,1,2` script — and,
through `EMO_GUI_COUNT`, that the window kept its widgets: the shim
writes how many it made into the named file, and the run makes the
first frame's eight and no more.

The `c` target's long-running memory was step 49; reclamation landed
there, so the render loop holds its working set flat.
