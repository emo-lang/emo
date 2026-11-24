# Calculator

The first application under `apps/`: a four-function calculator, written
once in Emo and run on every EmoUI backend — a terminal, a server-rendered
page, an AppKit window, a GTK 4 window, the browser DOM and the
framebuffer. EmoUI's design moves forward one application at a time, and
each is a project of its own under `projects/emo-ui/apps/`; this is the
first, and the smallest application that is still one a person uses.

It is a calculator because it needs the one event every backend already
delivers — a click on a button — so nothing in the way of input stands
between the application and seven platforms. What did stand in the way
is recorded below, in
[what the calculator could not say](#what-the-calculator-could-not-say).

```
 0
 [ C ]   [ < ]   [ +/- ]
 [ 7 ]  [ 8 ]  [ 9 ]  [ / ]
 [ 4 ]  [ 5 ]  [ 6 ]  [ * ]
 [ 1 ]  [ 2 ]  [ 3 ]  [ - ]
 [ 0 ]  [ . ]  [ + ]  [ = ]
```

## The directory

```
apps/calculator/
  package.emo  main.emo  number.emo  test.emo    the application, emo/ui_calculator
  expected.txt                                    the trace: the display after every frame
  check.sh                                        the gate
  debug/  ssr/  tui/  fb/                         entries the session is replayed into
  macos/  gtk/  browser/                          entries a person drives, and a session twin
```

The application is `emo/ui_calculator`, pinned against `emo/ui` alone.
`main.emo` is the calculator a person operates — a model, a pure `update`
and a pure `view` — and `number.emo` is the arithmetic underneath it.
Neither names a platform.

Every other directory is one platform's entry: a package of its own with
the application and that platform's backend as dependencies, so only an
entry ever names the platform. An entry is a few lines — a `require`, a
`view` that passes the platform's unit, and one `ui.run` — and the two
window packages and the browser's hold two: `main.emo`, which a person
drives, and `session.emo`, which prints each frame's display for the gate.
What the two share — the window and the unit — is `mount.emo`.

## The application

**The keys.** Nineteen messages, in the order the keypad shows them:
`clear`, `back`, `sign`, the ten digits, `dot`, `add`, `sub`, `mul`,
`div`, `equals`. A chain evaluates from left to right (`7 + 8 * 2 =` is
30); an operator pressed while another is waiting means the later one
(`5 + - 3 =` is 2); `=` repeats the operation that made the result
(`2 + 2 = = =` is 8), and with an operator waiting takes the display as
both sides (`5 + =` is 10). The sign key negates the number being typed,
starts a negative right-hand side after an operator, and flips a result.
Backspace shortens an entry and leaves a result alone. An entry takes
fifteen digits — as many as a double carries exactly.

**The display.** Twelve significant digits, rounded, trailing zeros
gone: `0.333333333333` for a third, `3.3` for `1.1 + 2.2`, `10000000000.5`
for that number and a half. A number is written in a power of ten when its
plain form would not fit — `1e+15`, `9.99e+15`, `3.33333333333e-6` — and
never with a superscript: the terminal and the framebuffer draw ASCII
certain. A failure puts `Error` on the display, and no key but `C`
reaches it.

**The range.** A result outside `1e100` is that failure, which is where a
ten-digit pocket calculator overflows too — and the bound is what keeps
the arithmetic inside what every target can do. Emo's targets disagree
about a float that leaves the finite: `x / 0.0` is a runtime error on the
interpreter and `ocaml` (E3005) and an infinity on `c`, `typescript` and
`wasm`, and a float that overflows raises on `beam`. Emo has no catch, so
one unguarded `1 ÷ 0` would end the application instead of putting a word
on its display. `number.emo` therefore checks each operation before the
arithmetic that could raise and answers `(R.ok, value)` or `(R.error,
why)`; `update` turns an error into the display's word. The digits of the
display are `Int64` arithmetic rather than `printf`, which `wasm` and
`riscv64` do not carry, or `Float64.to_string()`, which prints six
significant digits.

**The tags.** A key's tag is its place on the keypad: `view` registers
the nineteen messages in the keypad's order before it builds anything, and
`tag_of("7")` is what that order makes it. A session is named by what is
on the keys — `["7", "+", "8", "*", "2", "="]` — and never by a number,
in an entry or in the gate's scripts.

**The unit.** `view(reg, m)` lays the calculator out for a terminal. A
`Style` number is a cell there, a point in an AppKit window and a pixel on
the web, so `view_at(reg, m, unit)` takes the gap between keys and the
margin around them from the one module that knows the platform — the
entry. The keys themselves carry no size at all: each asks for an equal
share of its row (`grow`), and its height is its label's, because no
number in a `Style` is the same length on a terminal and in a window.

`test.emo` is the application's own test, eighty assertions the
interpreter runs: the display's digits, the typed decimal, the guarded
operations, what each key does, and the keypad's tags as the tree carries
them.

## Running it

The application's packages are reached through a registry staged from the
sources under test, the way every gate stages one:

```sh
scripts/stage-registry.sh <registry-dir>
cd projects/emo-ui/apps/calculator
```

| Platform | Entry | What a person can do today |
|---|---|---|
| macOS | `macos/main.emo` | Click the keys in an AppKit window |
| GTK 4 | `gtk/main.emo` | Click the keys in a GTK window |
| Browser | `browser/main.emo` | Click the keys in `index.html`'s page |
| Terminal | `tui/main.emo` | Watch the window session replay — no key source yet |
| Server-rendered | `ssr/main.emo` | Read the page and its fragments — no request loop yet |
| Framebuffer | `fb/main.emo` | Watch the window session paint a hosted canvas |

The window entries, built for `c`, and the page, built for `browser`:

```sh
EMO_REGISTRY=<registry-dir> emo build macos/main.emo --target c -o macos/calculator
EMO_REGISTRY=<registry-dir> emo build gtk/main.emo --target c -o gtk/calculator
EMO_REGISTRY=<registry-dir> emo build browser/main.emo --target browser -o browser/out.js
```

The page is `browser/index.html` with `out.js` beside it; the tree mounts
into its `#emo-root`. The application prints nothing — `./check.sh` leaves
the three built under `.emo-build/check/`, ready to run.

## The sessions and the gate

One session, 159 keys long, exercises every key and every state the
display has. The backends that print a line a frame replay it whole; the
others replay its first keys:

| Session | Keys | Replayed by |
|---|---|---|
| the hosted session | 159 | the headless entry and the page |
| the window session | the first 54 | the terminal, the framebuffer and the two windows |
| the page session | the first 6 | the server-rendered entry, and the framebuffer on `beam` |

The window session is as long as a native shim takes — at most sixty-four
tags, a click apart — and the page session is as long as a document a
frame is worth printing. Every entry prints the display once a frame, as
`display <what it shows>`, so the shorter sessions' bytes are the hosted
session's first lines and `expected.txt` — the headless entry's output on
the interpreter — is the one file every entry is pinned to.

```sh
./check.sh
```

The gate stages its own registry, then:

- the application type-checks, its eighty assertions pass, and it lowers
  for `riscv64`, the metal's target;
- the headless and server-rendered entries are byte-identical on all five
  hosted targets, the terminal entry on the four that can write stdout
  (its `wasm` refusal is pinned by name) and the framebuffer entry on
  four — on `beam` for the page session, because a frame of pixels costs
  seconds there ([below](#on-the-targets));
- the terminal, framebuffer and server-rendered goldens carry the trace
  beside their own frames, and what they carry of it is the head of
  `expected.txt`;
- the page is clicked through the hosted session by the browser backend's
  stub page, and prints `expected.txt`;
- each window replays the window session under `EMO_GUI_AUTOTEST`, prints
  its lines, and reports having made twenty widgets — the display and the
  nineteen keys — and not one more in fifty-four keys, which is the
  retained diff seen from a real toolkit.

`projects/emo-ui/check.sh` runs it with the backends' gates, so the
project keeps one entry point.

## What the calculator could not say

This is what the application was for. Each item is something a calculator
needs, EmoUI has no word for today, and the application worked around;
each is a design question for the core, not a change made here.

1. **A `Style` number has no unit.** The same gap is one cell on a
   terminal, eight points in a window and six pixels on the web.
   `view_at`'s `unit` is the workaround — the entry chooses — and it says
   what the core lacks: a length each backend resolves, the way a
   platform's own toolkits have one.
2. **A node cannot ask for an equal share.** `grow` divides what is left
   after each child's own width, so keys come out one width only where a
   label is measured in characters — the terminal, the framebuffer and
   both native box models. In a real browser a label has its font's
   width: `/` came out 40 px against a digit's 46 px. A fixed width is no
   answer, since on a terminal it would be forty cells.
3. **A leaf has no height of its own.** A key is one line tall on the
   terminal and the framebuffer, and a default button elsewhere; `height`
   in a `Style` would be the same number of cells and pixels.
4. **`Style` says layout and nothing else.** There is no color, no size of
   type, no alignment of text and no panel, so the display is the size of
   a key's label and flush left, the operators look like the digits, and
   there is no theme. On the web, `index.html`'s own stylesheet carries
   the card around the tree — the page is the backend's contract, and the
   only place left to say it.
5. **A label is bytes.** The terminal backend measures a button's label
   with `length()` and the framebuffer walks it a byte at a time, so `×`,
   `÷`, `±` and `⌫` would misplace a key on one and paint missing glyphs
   on the other. The keys are ASCII — `*`, `/`, `+/-`, `<` — and the
   display's powers of ten are `e+15`.
6. **There is no keyboard.** A window takes clicks and nothing else; the
   terminal entry replays a script because the backend has no key source,
   and the server-rendered entry prints because there is no request loop.
   The `term` package reads keys on `c`, but which key means `C` is the
   application's to say, and the core's event carries a tag and nothing
   else — the first question in
   [`docs/emo-ui-missing.md`](../../../../docs/emo-ui-missing.md).
7. **A kept widget keeps its focus.** AppKit draws the first key's focus
   ring when the window opens, which is the retained diff doing its job on
   a button nobody has tabbed to.

## On the targets

Facts about Emo the calculator met and worked with; `CHECK.md` carries
them with the probes.

- A float divided by zero and a float that overflows are not the same
  value on every target — the range and the guarded operations are the
  answer, above.
- `riscv64` does not lower `String.chars()`, so an entry is walked by
  byte; `test.emo` keeps to the same set so the whole package lowers for
  the metal.
- On `beam` a pixel store copies the canvas's whole `Bytes`: the same
  46,080 stores take 2.0 s into a 368 KB canvas and 18.7 s into one ten
  times its size. A frame of the calculator cost 8.2 s on a 384x240
  canvas there, against 0.03 s for its layout, so the framebuffer entry
  paints one of 256x148 — the size the calculator measures to — and its
  `beam` leg is the page session's seven frames.

## What is not done

- **The metal and Wayland.** The application lowers for `riscv64`, but no
  EmoOS pass runs it in a window of its own, and the Wayland client has
  no tile for it. The desktop's app window is 128 pixels tall; the
  calculator measures 148 at the type's size, its five rows of keys 116.
- **A keyboard, and a server.** The terminal entry with `term` behind it,
  a window that takes a typed digit, and the server-rendered entry behind
  a request loop — each is its own piece of work in the core or a backend.
- **The keys a larger calculator has** — percent, memory, a history — and
  a second application under `apps/`.
