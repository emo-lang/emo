# EmoUI — what is still missing

Written 2026-11-24. This is an assessment, not decided design. It records
what the tree has and what it lacks, as of `feat/emo-ui` at `4d0088fa` (on
`develop` `b053a766`), measured against one question: **what would it take
to build complex, robust, cross-platform GUI software on EmoUI?** It
decides nothing and proposes no syntax. The architecture and the evidence
behind it are [`emo-ui.md`](emo-ui.md), what each package really implements
is its reference under `projects/emo-ui/docs/`, and the code is the
authority for every claim below — each names where it was read.

## The short answer

EmoUI has proved one thing: a single declarative tree renders on a
terminal, a server-rendered page, an AppKit window, a GTK 4 window, the
browser DOM, and the EmoOS framebuffer, and compares byte for byte wherever
bytes can be compared. It has not yet been asked to do much more. Against
the question above, six groups of capability are missing, and most of the
first four trace back to one line in the core — the backend hands the
application one integer per event:

```emo
interface Events {
  def deliver(tag Int64) Void
}
```

A text edit, a key press, a pointer position and a new window size are all
events, and none of them is an integer. The rest of the input model follows
from that.

## What "complex and robust" is taken to mean

The bar the gaps are measured against, stated so that it can be argued
with:

- **Complex** — many screens built from components the application defines;
  data-driven lists; forms that take typed text; real typography and a
  visual identity; sessions that run for hours.
- **Robust** — one bad event does not end the process; the same input means
  the same thing on every platform; a long session holds its memory; a
  mistake is refused where it is made, not silently rendered.

## What the tree has

The portable core (`projects/emo-ui/ui.emo`): eight node classes —
`Column`, `Row`, `Scroll`, `Text`, `Button`, `TextInput`, `Image`,
`Spacer` — a `Style` of six layout properties (`padding`, `gap`, `align`,
`grow`, `width`, `height`), the Elm loop (`run`, and `run_raw` for messages
that are already integers), the `Registry` that turns a message into a
tag, the retained diff (`ui.diff`, landed 2026-11-24), and the backend seam
(`mount`/`patch`/`run`). What the backends make of it:

| Backend | How it renders | What it can really build | What input it really takes |
|---|---|---|---|
| `ui_tui` | a cell grid written as ANSI | the grid | a scripted list of tags (`Script`); the `term` package is not wired in |
| `ui_ssr` | HTML and an interned stylesheet | the page | none — a request steps one event by hand |
| `debug` | a text log | the log | none — stepped by hand |
| `ui_macos` | AppKit through `shim.m` | a window, labels, buttons | button clicks |
| `ui_gtk` | GTK 4 through `shim.c` | a window, labels, buttons | button clicks |
| `ui_browser` | the DOM over `dom_*` | `span`, `button`, `input` (read-only), `img`, `div` | button clicks |
| `ui_fb` (`projects/emo-desktop/fb`) | pixels and Strike fonts | the painted surface | a stream of tags: the seat's keys, and a pointer click resolved to a `Button`'s rectangle |
| `ui_fb` on Wayland (`projects/emo-desktop/wayland`) | the framebuffer on a compositor's surface | the painted surface, several toplevel windows | the seat's keys and pointer, decoded outside the core |

Every row renders the same convergence corpus
(`projects/emo-ui/corpus/`), which is what the gates pin. What the rows do
not share is the subject of the rest of this note.

## 1. The input model

**Text input.** *The payload half landed 2026-11-28 (`feat/emo-ui`); the
keyboard-and-focus half below is still open.* `TextInput` now carries an
event, and `deliver(tag, text)` carries what was typed: the web and
native backends own editable widgets and deliver each field's text
through the tag `Registry.on_text` registered for it, a kept field's
text survives the renders in between, and the SSR field posts its value
under `emo-<tag>`. The registry's one-tag-per-value limit went with it
(the name-keyed factory replaced the per-value tag). What the field
still does not have is a key event of its own — no focus, no caret the
application sees, no Tab traversal — which is the paragraph below.

Before that landing: `TextInput` showed the model's value and carried
no event, so it was read-only on every backend: `ui_ssr` emitted
`readonly`, `ui_browser` set `readOnly`, and the native backends made it
a label. No application could take a line of typed text through the
core, on any platform.

**Keyboard and focus.** *The keys half landed 2026-11-28, the same day
(`feat/emo-ui`): an event is `deliver(tag, text, key)`, a field registers
one `on_input` tag for both its text and its keys, and the backend
forwards what its toolkit does not consume — Enter everywhere a field
owns a key, Escape on GTK and the DOM — to the focused field's tag.
Focus itself stays toolkit-internal, decided: routing keys needs the
focused widget and the toolkit knows it; the focus *model* — events,
steering, the caret an application can see, Tab traversal in the core —
is the next input-model round, and until it lands the application still
cannot ask which control has the keyboard.* Through the rest of the
core's seam the only event any backend delivers is a button's click — the three that keep their widgets connect
exactly that one (`projects/emo-ui/macos/shim.m`,
`projects/emo-ui/gtk/shim.c`, `projects/emo-ui/browser/ui_browser.emo`'s
`dom_connect`) — or, on the terminal, a scripted list. Real keys and real
pointer positions arrive only where the desktop project decodes them
itself, the framebuffer's seat and the Wayland client's `LiveInput`, and
reach `update` through the raw loop as integers the application interprets.
There is no focus in the core: no focused node, no focus order, no Tab
traversal, and no way for an application to ask which control has the
keyboard.

**Pointer and scrolling.** The core has no pointer event of any kind — no
move, drag, wheel, hover or context menu; where the pointer reaches an
application at all, it is a click on a `Button`'s rectangle
(`projects/emo-desktop/fb/ui_fb.emo`'s hit table). `Scroll` is not a
viewport: on the framebuffer it "measures and places exactly like a column"
(`ui_fb.emo`), and `projects/emo-ui/tui/ui_tui.emo` says of it "not yet a
viewport with an offset"; on the native backends it is a column at a fixed
height, and only the Web backends scroll it, through CSS `overflow: auto` —
without telling the application, because a scroll offset is an event the
seam cannot carry.

**Window events.** The core has no window of its own. A window is the
backend's, one per native backend (`shim.m` and `shim.c` each hold a single
window), and its size is an argument — `backend(title, width, height,
script)`; "reading the screen size and reflowing on resize is not wired
yet" (`projects/emo-ui/docs/ui_macos.md`). There is no resize event and no
scale factor.

## 2. The widget vocabulary

Eight nodes are the whole portable vocabulary. Missing are the controls a
complex application is made of — a toggle, a checkbox, a radio group, a
slider, a drop-down, a list, a table, tabs, a menu, a dialog, a progress
indicator, a tooltip — and the containers that organize a screen: nothing
stacks or overlays, nothing is placed at an explicit position, and there is
no separator and no multi-line text.

On the native backends the vocabulary is thinner still. `ui_macos.emo`'s
`make` builds a button for a `Button` and a label for everything else, so a
`Text`, a `TextInput`, an `Image` and a `Spacer` are all labels — an
`Image` shows its `src` string. Only the Web backends can show one.

A component has no state of its own. The loop has one model, and whatever a
widget would keep to itself — a caret, a scroll position, an open or closed
menu — goes into that model or into a `Box` the application manages by
hand ([`emo-ui.md`](emo-ui.md), Layer 5). For a screen with forty controls
that is forty pieces of bookkeeping the application writes.

## 3. Style and typography

`Style` is layout and nothing else. There is no color, font, size, weight,
border, corner, visibility or opacity, so there is no theme and no dark
mode: a palette exists only in the metal desktop's skin layer
(`projects/emo-desktop`, M30–M31), which the portable core never sees.

Text is one line. There is no wrapping, no selection, no clipboard and no
input method in the core or any hosted backend; the clipboard the metal
desktop grew is its own (`projects/emo-desktop/docs/TASKS.md`, M34). Fonts
exist only as the framebuffer's `raster.Strike` and the browser root's
`system-ui`.

Layout has no stacking, no absolute placement, no overflow rule and no
minimum or maximum size, and the native backends estimate a text's width at
eight points per character (`projects/emo-ui/macos/box.emo`, and the GTK
package's copy). One style number is not one length: `box.emo` measures it
in points, `ui_tui` in cells and `projects/emo-ui/browser/css.emo` in CSS
pixels. The assessment promises nothing here: "no layout parity guarantee"
is on its list of what v1 does not give ([`emo-ui.md`](emo-ui.md), Risks).

## 4. Application architecture

**Effects and asynchronous work.** `update` and `view` are pure, and nothing
else is allowed to happen during an event: a timer, a network reply, a file
read or a message from another process has no modeled way into the tree.
The assessment names the cause — the toolkit's loop blocks in `ui_run()`
while Emo's scheduler does not own that thread — under "Two event loops"
([`emo-ui.md`](emo-ui.md), Layer 5), and it is as open today as it was
then.

**Recovering from a mistake.** "A raise cannot be caught — Emo has no catch
construct" ([`intro/syntax.md`](intro/syntax.md)), and an unhandled error
ends the process it happens in
([`intro/concurrency.md`](intro/concurrency.md)). The event loop runs in one
process, so an exception in one event handler ends the application. The
isolation the language offers is the process, and a UI built from many
processes is exactly what the two-event-loop question has not answered.

**Scale.** A tree is rebuilt on every event, and the registry finds a
message's tag by walking its table (`Registry.index_of`). As `ui.emo` says
of its own table, "a message that carries a value is a distinct message per
value, so a message built from a changing string (a text field's own
contents) allocates a tag per render". There is no virtualized list and no
lazy view. The retained diff
is the first step, not the last; the compiler's targeted refresh that the
README promises remains, in the assessment's words, the long-term form.

**Long sessions.** The `c` target reclaims what a render allocates (step
49). The metal does not: its `Bytes` are permanent bump cells (`CHECK.md`,
the crypto verification round), so a framebuffer application that
allocates per event grows for as long as it runs.

## 5. Platform coverage

EmoUI reaches macOS, Linux through GTK 4 and through Wayland, the browser,
the terminal and EmoOS. It does not reach Windows natively — the toolchain
itself supports WSL2 only
([`toolchain-distribution.md`](toolchain-distribution.md)) — nor any mobile
platform. There is no accessibility: no role, label or focus state reaches
a platform's accessibility tree, and the one mention of accessibility in
the tree is the GTK gate switching it off. Text
is bytes to the core; right-to-left layout and input methods appear nowhere.
And there is no packaging story: "No packaging/app-store story" is what
[`emo-ui-check.md`](emo-ui-check.md) lists as deliberately out.

## 6. What the language gives, and withholds

Facts about Emo rather than requests, listed because they set the price of
everything above.

- No generics and no default parameters ([`emo-ui.md`](emo-ui.md), Risks):
  each of the eight node classes repeats `style()`, `children()` and
  `key()`, and the key the diff matches on cost an edit in all eight.
- An enum is a closed set of named values and carries no data
  ([`intro/syntax.md`](intro/syntax.md)): a message with a payload is a
  class instance or an `(R, value)` tuple, which is why text input is a
  design question and not an afternoon.
- `Block` is the unknown tier: `view`, `update` and every callback are
  unchecked ([`emo-ui.md`](emo-ui.md), the remaining question of a checked
  function type).
- A module-level binding re-runs its initializer on every read, so state
  lives in objects (`ui.emo`, on the registry).

## What one platform has and the core does not

The metal desktop outruns the core. Under `projects/emo-desktop/fb/`:
`pointer.emo`, `raster.emo` with two faces, the motion vocabulary
(`desktop/emo_motion.emo`), an icon family, a skin palette (M30–M31),
window chrome and notifications. Each is proven on one backend and portable
to none. They are the evidence that the capability can be built in Emo, and
the measure of how far the portable core is behind what the project already
runs.

## What is on the record, and what is not

Already named in the project's records: the two event loops and a checked
function type ([`emo-ui.md`](emo-ui.md), remaining questions), the
compiler's targeted refresh, a canvas, accessibility, animation and layout
parity ([`emo-ui.md`](emo-ui.md), Risks; `docs/visualization.md`), and
packaging.

Not on any list before this note: text input and events that carry a
payload; keyboard events and focus; pointer and scroll events; resize;
color and typography in `Style`; widget-local state; recovering from a
failed event; Windows.

## What the first application confirmed (2026-11-24)

The calculator, the first application under `apps/` — its README is
[`apps/calculator/README.md`](../projects/emo-ui/apps/calculator/README.md)
— is the smallest application a person uses, and it needs only the one
event every backend delivers.
Writing it confirmed two items above and found four that were on no
list.

Confirmed: a window takes clicks and nothing else, the terminal entry
replays a script because the backend has no key source (§1); and a
`Style` says layout and nothing else, so the display has no size, color
or alignment (§3).

New, with what the calculator did instead:

1. **A `Style` number has no unit.** One gap is a cell on a terminal, a
   point in a window and a pixel on the web; the application takes its
   gaps as an argument, and each entry passes its platform's number.
2. **A node cannot ask for an equal share.** `grow` divides what is left
   after each child's own width, so keys come out one width only where a
   label is measured in characters. In a browser an operator's key came
   out 40 px against a digit's 46.
3. **A label is bytes.** The terminal measures a button's label and the
   framebuffer paints it a byte at a time, so no key can read `×`, `÷`,
   `±` or `⌫`.
4. **A leaf has no height of its own.** A key is one line tall wherever a
   cell grid or a glyph's line box is the unit, and a `height` in a
   `Style` would be the same number of cells and pixels.

Its README carries each with its evidence. None is decided here.

## What follows

**Decided and landed, 2026-11-28 (`feat/emo-ui`).** The event carries
`deliver(tag, text, key)` — one method, the payloads as the method's own
marshaled parameters, because the C→Emo callback contract names a
single-method interface and `String` and `Int64` are in its marshaling
tier. A message that carries a value is the application's own class,
built by a factory the registry stores under a name (`on_input` — one
tag per field for its text and its keys), which retires the
one-tag-per-value limit in the same pass. A backend that owns an
editable widget keeps the keystrokes across renders by writing a kept
field back only where the model's value differs, and forwards the keys
its toolkit does not consume to the focused field's tag. Two facts of
the language decided the message shape: `is()` raises on an enum member,
so a loop that takes one payload takes every message as a class instance
(a field-less class still dedups — equality on instances is structural);
and the raw loop refuses a payload of either kind, because its message
is the tag itself. The shape is in [`emo-ui.md`](emo-ui.md), Layer 5.

What the decision carried is the text and the key. After it, in the
order the dependencies allow: the focus model (events, steering, the
caret — the keys' routing already rides the toolkit's); pointer, scroll,
resize; a `Style` that can say a color; the effect model, with the
two-event-loop question it has always been; and only then a wider widget
vocabulary — widgets are cheap to add once input and style can serve
them.
