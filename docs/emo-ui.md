# EmoUI — an assessment and a design direction

Written 2026-10-14. This is a technical feasibility assessment and a
design direction, not decided design. Project-state claims reflect the
repository as of that date (`develop`). Decisions that get settled move
into `README.md`; this note records the evaluation, the evidence behind
it, and the open questions.

The question: **one declarative EmoUI syntax, rendering to the Web, a
terminal (TUI), macOS (AppKit), and GTK 4 — where each platform may
have its own component library, but the way components are called and
composed is identical.**

The gate checklist that got the project this far is
[`emo-ui-check.md`](emo-ui-check.md); the evidence for the two native
toolkits lives in `spike/macos-gui`, `spike/gtk`, and `spike/components`.
This note adds two more bodies of evidence: `spike/emo-ui-probe`, four
programs that pin down what the language does and does not give the
declarative tree today; and `spike/arena-scope`, which measured what a
render costs on the `c` target and ruled out the cheap fix for it.

## The conclusion

**Feasible, in tiers — and the syntax is the easy half.** The
requirement reads like a syntax problem ("same syntax, four platforms"),
but there is nothing to add to the syntax: a component tree is already
nested calls with blocks, and that is ordinary Emo. The hard half is the
**semantic contract** underneath the shared surface — layout, events,
text, lifecycle — and the fact that the four platforms are four
different kinds of program (a retained toolkit loop, a browser event
loop, a blocking terminal read, a server-side string renderer).

Four findings shape everything below:

1. **The declarative tree is not type-checked today, and its prettiest
   spelling does not work.** A parameter declared `Block` is `Unknown`
   to the checker, so a trailing block's contents are dynamically
   checked (at best); and a block whose body is a sequence of child
   calls yields `void`, so the children are silently discarded. The
   README's illustrative tree (`page(...) { navbar() { ... } }`) is not
   an executable program. Children are either an explicit
   `Array[Node]` or the block must `return` them.
2. **The four platforms are not equally ready.** macOS/AppKit and GTK 4
   are proven through `foreign def` shims; a terminal renderer is cheap
   pure Emo; the Web is the least ready — the TypeScript target is
   Node-only (`node:net`, `node:fs` imported at the top of the emitted
   runtime) and the wasm target's entire host interface is three
   imports (`println`, `abort`, `float_str`).
3. **Packaging an EmoUI backend is not expressible yet.** A package
   may carry `.c`/`.h` and link bare `-l` names only. An AppKit backend
   is Objective-C (`.m`, `-fobjc-arc`, `-framework AppKit`); a GTK
   backend needs `pkg-config --cflags --libs gtk4`. Neither fits. The
   direction is settled — the manifest grows per-package native fields,
   not app-level build scripts (`CHECK.md`) — and the field surface is
   T48.7's own work; until it lands, the native backends fall back to
   the app-level scripts the spikes use.
4. **A render's memory is not reclaimed on the `c` target, and the cheap
   fix does not exist.** A tree is built from exactly the kinds the
   arena never frees — children arrays, style maps, strings — and a UI
   rebuilds it per event. `spike/arena-scope` measured ~1 MB and ~820
   objects per render at 400 nodes, both unbounded: ~60 MB/s and
   ~49,000 objects/s at 60 fps. A region reclaims the bytes and none of
   the objects, and strands those refcounts permanently. The native
   backends are therefore **demo scale with the limit documented**, and
   refcounting the value families is scheduled as its own milestone
   (step 49, `CHECK.md`).
5. **`Array` has no O(1) append**, and `List` does not convert back to
   an indexable `Array`, so the decided children spelling — an
   `Array[Node]` grown by `.append` and rebuilt per render — is O(k²)
   in both bytes and retains. T48.1 should settle the children
   representation, or the language should gain a cheap array builder.
   **The second half of this is now answered**: the language has
   `ArrayBuilder` (T49.3), which grows an `Array[T]` by `push` in
   amortized O(1) and hands it out with `to_array()`. Building the child
   list no longer costs a copy per child, so `children_of`-style
   accumulation can be written without the nested-`.append` workaround.
   T48.1's representation question — whether children are an array at
   all — is **settled** by the portable core (2026-10-15): children
   stay an explicit `Array[Node]`, and a child list that is not known
   until it is walked is built with `ArrayBuilder`.

The recommendation: **EmoUI is a project of its own — third-party
rather than standard-library — built as a portable `ui` core plus one
package per platform, sequenced TUI and server-rendered HTML first
(pure Emo, no new toolchain), native toolkits next, in-browser DOM
last.** No new syntax. The one language ask worth weighing is a checked
block/function type, and it is a convenience, not a gate. (Where it is
hosted changed on 2026-10-15 — `projects/emo-ui/` in this repository
rather than a repository of its own; see *Packaging* below.)

## What the requirement actually demands

Stated as a contract, "same syntax, per-platform components" decomposes
into five claims. Each is evaluated on its own below.

- **C1 — Composition is one syntax.** A component tree is built the same
  way on every platform.
- **C2 — The tree is one value type.** A component returns the same kind
  of value everywhere, so components compose with components.
- **C3 — Component libraries may differ per platform.** A platform may
  ship widgets the others do not have.
- **C4 — Components are portable according to what they are built from.**
  A component written against portable primitives works everywhere; one
  built from platform extras does not.
- **C5 — The platform difference is confined to the backend.** The
  language layer and the application code know no platform details.

C1 is free (it is plain Emo). C2 needs the recursive node type, which
now works. C3–C5 are where the design work is.

## What is already settled and proven

This note does not re-open what earlier work closed.

- **Reachability.** A native window with working callbacks is reachable:
  AppKit through a vocabulary shim (`spike/macos-gui`), GTK 4 largely
  through direct `foreign def` calls (`spike/gtk`).
- **The component model.** `spike/components` runs one React/Elm-style
  application — defs as components, the update/view loop in Emo, styles
  as maps with a child-overrides-parent cascade, layout computed in Emo
  — byte-identically through AppKit and GTK 4 behind a nine-verb `ui_*`
  shim contract.
- **Cross-module types.** Settled 2026-10-14 as module-qualified paths:
  `ui.VNode`, `sync.WaitGroup`; two modules may declare the same short
  name as two distinct types. This is what lets the library and the
  application be separate modules and packages.
- **Recursive nodes.** Both shapes the tree needs now check:
  `class Node { def init(kind String, children Array[Node]) }` and an
  interface naming itself in a signature (`def kids() Array[VNode]`).
  The spike's E4005 workaround (interface + separate concrete
  containers) is no longer forced — probe 2 in `spike/emo-ui-probe`.
- **The C→Emo callback contract.** Settled 2026-10-11: a single-method
  structural interface is the callback type; the `c` target emits a
  trampoline plus an opaque userdata handle, and the pair lands in
  `.emo-build/emo_defs.h`.
- **The README's commitments.** No template language (the UI is plain
  Emo); components are lowercase defs, `.new` never appears in a tree;
  props checked by the gradual checker; reactivity primitives are
  explicit; UI events are process messages; backends consume the tree
  and its updates; the language layer knows no platform.

## The four platforms

| Platform | Route | Status | The gap |
|---|---|---|---|
| macOS (AppKit) | `c` target + Objective-C shim via `foreign def` | **proven** (`spike/macos-gui`, `spike/components`) | packaging: `.m`, `-fobjc-arc`, `-framework` |
| GTK 4 | `c` target + C shim via `foreign def` | **proven** (`spike/gtk`, `spike/components`) | packaging: `pkg-config gtk4` |
| TUI | pure Emo, ANSI escape output | **not built, cheap** | terminal input (raw mode, key events) |
| Web | HTML/CSS (SSR) → DOM (browser TS) → wasm + DOM | **least ready** | TS target is Node-only; wasm host has 3 imports |

### macOS and GTK 4

Both are `foreign def` over a C ABI, and both worked in the spikes. What
differs is the shim size, not the architecture: a C toolkit needs no
vocabulary translation (GTK's shim is roughly a third of AppKit's,
because GTK names are already C-shaped). The nine-verb `ui_*` contract
(`window_make`, `label_make`, `button_make`, `place`, `clear`,
`connect`, `root`, `run`, `autotest_arm`) is the portable seam the
spike proved, and the per-platform delta is a ~100-line painter.

The real blocker is packaging, and it is a manifest gap, not a
toolchain gap:

- `docs/intro/package-management.md` (and `docs/c-backend.md`'s
  "Package-carried native code") allow `.c`/`.h` files in a package and
  a `link` field of **bare library names** only.
- AppKit needs an Objective-C translation unit compiled with
  `-fobjc-arc -framework AppKit` (or `-framework Cocoa`); a bare `-l`
  name cannot say that, and a `.m` file is not collected.
- GTK 4 needs the `pkg-config gtk4` cflags and libs; a bare `-lgtk-4`
  is not enough (glib, gobject, gio, pango, gdk, and include paths).

Until the manifest gains a per-package compile/link flag mechanism (or a
`pkg_config = ["gtk4"]` field), the native backends cannot be ordinary
consumable packages. The spikes sidestep this with app-level build
scripts that pass `--cclib="$PWD/shim.o"` and `--cclib="-framework
AppKit"`. That works, but it makes every EmoUI-for-macOS app carry a
build script instead of a `require`. This is the single most concrete
piece of toolchain work the requirement implies.

**Settled 2026-10-14: manifest fields are that mechanism and the
build-script path is not** (`CHECK.md`). A native backend stays an
ordinary package a program reaches with a `require`, so what AppKit and
GTK 4 need is declared in the manifest rather than restated in each
consumer's script. The field surface — `pkg_config` versus explicit
compile/link flag lists, and whether `.m` joins the collected `.c`/`.h`
— is T48.7's own work.

### TUI

The cheapest of the four, and the best first target. Rendering is
`printf` with ANSI escapes — pure Emo, on any target that can write to
stdout, needing no FFI and no new package machinery. The cell grid is a
layout in its own right (columns/rows/width/height in character cells),
and it is exactly the kind of format-agnostic surface `plot`'s terminal
renderer already plans (`docs/visualization.md`, Layer 5). A terminal
backend is also the best test that the core really is decoupled from
the toolkit: if the node model and the update loop run on a cell grid,
they are genuinely backend-neutral.

The gap is **input**, not output. The runtime implements no raw mode and
no key events: the `os` package gives fd-level `read`, `os` is
native-only, and there is no termios binding. Reading a line is possible
today; arrow keys, resize events, and Ctrl-C-as-a-message want raw mode,
which is a small `foreign def` to `termios` (c/ocaml) or a terminal
runtime implementation. Bounded, but it must be scheduled, not assumed.
**Settled 2026-10-15** — scheduled as a standard-library package in the
`sqlite3` shape (ask 7 below).

### Web

The honest answer is that "the Web" is three different products, and
only one of them is close.

- **T0 — server-rendered HTML/CSS.** A pure-Emo renderer that turns the
  node tree into HTML and a stylesheet, byte-identically on all five
  hosted targets. No DOM, no JavaScript, no browser runtime — the same
  architectural move `plot` made when it chose SVG: the viewer owns
  rendering, the library owns the scene. Interactivity is forms, links,
  and server round-trips (the htmx shape), or a later SSE/WebSocket
  channel. This is cheap, testable, and gives "Web" immediately for
  content and form UIs. It is the right T0.
- **T1 — the DOM backend.** An Emo program compiled by the TypeScript
  target, running in the browser against `document`/`Element`. This is
  where real interactivity lives, and it is not ready: the emitted
  runtime imports `node:async_hooks`, `node:net`, `node:dgram`,
  `node:tls`, `node:dns`, and `node:fs` at the top (`ts_runtime.ts`),
  so it does not load in a browser; step 17's scope explicitly lists
  "browser embedding (`fetch`/WebSocket bridging)" as out; and browsers
  cannot execute `.ts`, so an output-bundling step enters the toolchain.
  Getting there means a DOM capability layer (a `dom_*` family in the TS
  runtime, or a browser-only runtime variant), a browser-safe
  entry, and a build step. All are real work, none is architecturally
  blocked.
- **T2 — wasm + DOM.** The `wasm` target's module imports exactly
  `println`, `abort`, and `float_str`; a DOM backend on wasm means new
  host imports and a JS glue layer. Later, and only if T1 proves
  insufficient.

There is a further semantic point specific to the Web and to native
toolkits: **the platform owns the event loop.** A browser page or an
AppKit app cannot hand Emo a blocking `ui_run()` and then let Emo's own
cooperative scheduler own the thread. The `c` target's toolkit loops do
block in `ui_run`, and events re-enter through callbacks; the browser
does not. This matters for the state design below.

## The architecture

Six layers, each depending only on the ones below. Everything above the
backend is pure Emo and platform-free.

### Layer 0 — the node model

A node is immutable data: a kind, its typed props, a `Style`, an event
identity, and children. The tree type is the recursive node:

```emo
// ui.emo — the portable core
interface Node {
  def style() Style
  def children() Array[Node]
}

class Column {
  def init(style Style, children Array[Node]) {
    self.style = style
    self.children = children
  }
  def style() Style { return self.style }
  def children() Array[Node] { return self.children }
}

class Text {
  def init(body String, style Style) { self.body = body; self.style = style }
  def style() Style { return self.style }
  def body() String { return self.body }
}

class Button {
  def init(label String, event Int64, style Style) {
    self.label = label; self.event = event; self.style = style
  }
  def style() Style { return self.style }
}
```

The interface is the tree spine (so `Array[Node]` holds anything) and it
names itself, which the checker accepts (probe 2, and the recursive-interface
finding above). Concrete classes carry typed props, checked at construction.
A backend narrows with `is()` — `ui.Text`, `ui.Button`, and the platform's
own classes. Because a backend is paired with a platform library, it knows
the union of the core classes and its platform's classes; that is the
dispatch table.

Two alternatives were weighed and are rejected for the core:

- **One universal node class with a `kind` string and an untyped prop
  map.** This is what the spike used, and it is the fastest to build,
  but it is exactly the stringly, unchecked surface Emo's strictness
  rejects; the style-key validation problem is already flagged in
  `emo-ui-check.md`.
- **One node class per platform, with no portable core.** Then no
  component is portable and C4 fails outright.

The recommended shape keeps the spike's proven spine (interface +
concrete classes) and uses the cross-module types that now exist to put
the spine in a library module.

### Layer 1 — composition

The tree is nested calls. For iteration, a component takes a block and
calls it per element; the block **returns** the node for that element,
and the component collects the returns:

```emo
def each_from(xs Array[String], i Int64, into Array[Node],
              f Block) Array[Node] {
  if i == xs.length() { return into }
  const head = f(xs[i])
  return each_from(xs, i + 1, into.append(head), f)
}

def each_users(xs Array[String], f Block) Array[Node] {
  return each_from(xs, 0, [], f)
}

const rows = each_users(users) -> (u String) { return card(u) }
```

The accumulator is load-bearing. **`Array.append` appends one element,
not an array** (`src/emo_eval/emo_eval.ml:2055`), so the tempting
`[head].append(each_from(xs, i + 1, f))` builds `[n0, [n1, [n2, []]]]`
— nested — and still type-checks at `Array[Node]`, because the element
arrives through a `Block` and `Block` is `Unknown`. Nothing reports it,
and the wrong length looks like a plausible one. `spike/emo-ui-spelling`
measures the idiom, shows it on a real screen, and shows that the
hand-written `List` → `Array` conversion has the same quadratic shape.

This works (probe 3), but it exposes the finding at the top of this
note. **Emo has no implicit child collection, and a `Block` parameter
is `Unknown`.** Probe 1 shows both halves:

- A block that returns an array delivers the children
  (`card() { return [text("a"), text("b")] }` — the component receives
  the array).
- A block that is a sequence of child calls delivers `void`
  (`card() { text("a"); text("b") }` — the component receives nothing;
  the child values are discarded expression statements).

So the README's illustrative tree cannot work as written. There are only
four ways to make a block-bodied tree real, and three are wrong:

1. **Children are an explicit `Array[Node]` argument.** Checked, ordered,
   and needs nothing new. This is what `docs/visualization.md` chose for
   plot (decision 14, "array-only declarative tree, no trailing-block
   spelling"). It is the recommendation here too.
2. **The block `return`s the children** (`{ return [a, b] }`). Works and
   composes with trailing-block syntax, but adds a `return` to every
   leaf and changes the spelling between one child and many.
3. **A builder the block appends into** (`card(user) { children.push(a) }`).
   Works, but puts mutation and an ambient collector into the tree —
   implicit state, against the design philosophy. This is still rejected:
   the objection is to a collector the block reaches without being told
   about it, and the language's own `ArrayBuilder` does not supply one —
   a builder is a value passed in and named at the call site, so this
   option would only become acceptable by being written as option 1 with
   a builder in place of the array.
4. **An implicit "last expression is the value" rule for blocks.** This
   is a template language mechanism and contradicts the explicit-`return`
   rule (`docs/intro/syntax.md`). Reject.

The design therefore says: **the child list is an explicit
`Array[Node]`; trailing blocks are for callbacks and iteration, and
where a block produces a value it returns it.** The README's EmoUI
example should be revised to this spelling, or the block form should be
defined as requiring `return`. This is the one place where the
requirement's "declarative syntax" is really an API convention rather
than syntax, and the convention must be spelled out.

The related language gap: `Block` being `Unknown` means a block argument
is not checked. A **checked function type** would let a component declare
the shape its callback must have (`def each(xs Array[T], f (T) Node)`)
and let a tree block be verified against it. Emo has `Block` as the only
spelling today, and `Block` is deliberately `Unknown`. Adding a checked
block/function type is a language change of real size (syntax,
unification, every backend's closure representation); it is worth
weighing because it is the difference between a checked and an unchecked
component API, but it is not a gate for a first package.

The full argument behind this section — the three ways a discarded block
value could be given a destination, the prior-art survey, the three
shapes a template language can take, and the one question it leaves open
(a tree literal form in Emo's own grammar, versus an external translator
to `.emo`) — is in [`emo-ui-composition.md`](emo-ui-composition.md).

### Layer 2 — component libraries

The requirement explicitly wants per-platform component libraries. The
design gives that a precise boundary:

- **`ui` — the portable core.** The node spine, the portable primitives
  (column, row, text, button, text input, image, spacer, scroll), the
  style vocabulary, the app loop, and the backend interface. Pure Emo,
  every hosted target.
- **`ui-<platform>` — one package per platform.** A backend plus the
  platform's component library. Each declares its `targets` and carries
  its native code where it has any.
- **Convergent names.** Equivalent components share a name across
  platform libraries (`text`, `button`, `row`, `column`, …), so two
  platform apps read the same and a component written against the core
  compiles on all of them. A platform library may add names the others
  lack — that is C3.

The portability rule (C4) falls out: a component built only from core
primitives is portable; a component built from `ui-macos.table` is not.
The framework should make that boundary visible rather than paper over
it — the platform package's name at the call site is the signal.

### Layer 3 — layout

The spike computed layout in Emo, so both toolkits placed identical
pixels. That was the right choice for a two-backend demo and the wrong
choice for a real framework, because computing layout in Emo throws away
everything the platform's layout engine gives you: the browser's reflow,
Dynamic Type and accessibility, GTK's size negotiation, and — on every
platform — text measurement, which Emo cannot do without a font engine
(`docs/visualization.md`, gap 5).

The design is therefore a **portable layout vocabulary mapped to each
platform's native layout**, not a portable layout engine:

- Containers: `row`, `column`.
- Layout properties: `padding`, `gap`, `align` (start/center/end/stretch),
  `grow`, an optional fixed `width`/`height`.
- Everything is a value on the node's `Style`.

The mapping is direct: CSS flexbox on the Web, `GtkBox`/`GtkGrid` on
GTK, `NSStackView`/Auto Layout on AppKit, and an Emo box model on the
TUI grid (where the cell is the unit). The set is deliberately small:
the intersection that all four can honor, so a portable component looks
right everywhere. A platform library may add its own layout props (CSS
`grid`, a GTK size group) as platform style, not core style.

The TUI is the exception that proves the rule: it has no native layout
engine, so the core ships a small Emo box model for the terminal (and
for anything else that wants explicit positions, e.g. a future canvas).
That engine is the spike's, kept for the backends that need it — not
imposed on the ones that do not.

### Layer 4 — style

Style is a typed value with a factory and `with_*` copy methods, exactly
the shape `docs/visualization.md` settled for plot (decisions 2 and 20),
because Emo has no default parameters (verified: `hello("a")` for
`def hello(name String, count Int64)` is E4009; probe 4). The core
`Style` carries the portable layout vocabulary; platform-specific style
is a platform class:

```emo
class Style {
  def init(padding Float64, gap Float64, align Align, grow Bool,
           width (R, Float64), height (R, Float64)) { ... }
  def with_padding(p Float64) Style { ... }
  def with_gap(g Float64) Style { ... }
  def with_align(a Align) Style { ... }
  // …
}

def style() Style { return Style.new(padding: 0.0, gap: 0.0, align: Align.start, ...) }

text("Hello", style().with_padding(12.0))
```

`(R, Float64)` carries "unset or a value" — the README's own idiom for
an optional scalar (the `R` enum in a tuple) — so "auto" is explicit
rather than a magic sentinel. The spike's `Map[String, Float64]` cascade
is gone: it was stringly, and it accepted any key silently. If a
cascading theme is wanted later, it is a `Theme` value passed down, not
a hidden merge.

### Layer 5 — state and the app loop

The README commits to Elm (a UI process, a model, `update`, `view`) with
explicit reactivity primitives. The design takes that literally:

```emo
enum Msg { increment, decrement }

class Model {
  def init(count Int64) { self.count = count }
}

def update(msg Msg, model Model) Model {
  case msg {
    Msg.increment -> { return Model.new(count: model.count + 1) }
    Msg.decrement -> { return Model.new(count: model.count - 1) }
  }
}

def view(model Model) Node {
  return column(
    text("clicked ${model.count} time(s)"),
    button("+", event: ui.on(Msg.increment)),
    button("-", event: ui.on(Msg.decrement))
  )
}
```

The event identity is the FFI seam. A node carries an `Int64` tag, never
a closure (closures cannot cross the FFI, E4200). Building the tree
registers the typed message in an Emo-side table and stamps the node
with its index, so `update` stays typed (`Msg`) while the backend only
ever sees an integer:

```emo
def on(msg Msg) Int64      // registers msg, returns its tag
def dispatch(tag Int64) Msg // the driver's lookup
```

This preserves the README's promise that events are messages, keeps the
typed update, and respects the callback tier. Local mutable state that
is not part of the model uses the language's own primitives — `Box` for
one cell, `List`/`Map` for collections — read during `view`; the
README's "reactivity primitives live in the standard library" is
satisfied by these, and the "compiler optimizes to targeted refreshes"
promise is a later pass over exactly those reads, not a hidden graph.

Two integration facts bound this layer, and they are honest caveats, not
design choices:

- **Two event loops.** On AppKit/GTK, `ui_run()` blocks in the toolkit's
  loop and events re-enter through the callback contract. Emo's own
  cooperative scheduler (processes, mailboxes) does not own that thread.
  A UI process with a mailbox and a toolkit loop need an integration
  story (the toolkit loop pumping the scheduler, or events delivered as
  messages into a process). The synchronous Elm loop the spike used
  sidesteps it and is the right v1: processes and supervision arrive
  after the loop is proven.
- **Backend consistency.** The `c` target's `raise` ended the process
  rather than the offending process, and `send` shared rather than
  snapshotted — both closed 2026-10-15 (`CHECK.md`, step 50). A GUI was
  the consumer that made both visible; a UI that raises while holding
  the toolkit must not take the window down silently, and now it does
  not. The `typescript` target's share-on-send is the same gap on the
  Web path.
- **Long-running memory.** The `c` target does not reclaim the value
  families a render allocates, and a UI re-renders per event, so this is
  the caveat that bounds the platform rather than the design:
  `spike/arena-scope` measured ~1 MB and ~820 objects per render at 400
  nodes, both unbounded. A region does not fix it — it reclaims the
  bytes and none of the objects, and strands those refcounts — so the
  native backends are demo scale and refcounting the value families is
  scheduled as its own milestone (step 49, `CHECK.md`).

### Layer 6 — the backend seam

The backend is an Emo-level contract, not a C ABI. The nine-verb `ui_*`
contract was the spike's macOS+GTK implementation; the general seam has
to also admit a pure-Emo terminal writer and a browser DOM:

```emo
interface Backend {
  def mount(root Node) Void
  def patch(old Node, new Node) Void
  def run() Void
}
```

Each platform implements it:

- **macOS / GTK:** an Emo class whose methods call `foreign def` shims.
  The shims implement the primitives (`window_make`, `label_make`,
  `place`, `connect`, …); the Emo side walks the tree and maps nodes to
  native handles.
- **TUI:** a pure-Emo class that lays the tree out on a cell grid and
  writes ANSI; `run()` reads input and dispatches tags.
- **SSR:** a pure-Emo class that serializes the tree to HTML/CSS;
  `run()` is one render.
- **DOM (later):** an Emo class over the runtime's `dom_*` calls;
  `run()` hands control to the browser and returns.

`patch` is the growth edge. The spike did a full rebuild per event
(`clear` plus re-place), which is fine for a terminal and a static HTML
render but wrong for a retained toolkit (it loses focus, selection, and
scroll position) and wasteful for the DOM. v1 can start full-rebuild for
TUI/SSR and retained for native/DOM; reconciliation with keys is a
follow-up, and the compiler's "statically decidable targeted refresh" is
the long-term form of it.

## Evaluating the requirement

**C1 — one composition syntax: holds, and costs nothing.** The tree is
nested calls with explicit parentheses, named arguments for props, and
an attached block for callbacks and iteration. That is existing Emo
(`docs/intro/syntax.md`); the README's "calls with explicit parentheses,
single-form blocks, named arguments" is the whole syntax. No construct
is earned here, and none should be added.

**C2 — one tree value type: holds, and is now unblocked.** Cross-module
types plus the workable recursive node give one `ui.Node` that every
component returns and every backend consumes. This is the piece the
2026-10-10 and 2026-10-14 decisions existed to unlock; the probe
confirms the self-referential class now checks.

**C3 — per-platform component libraries: holds by design.** The core is
the portable set; each platform package adds native widgets. Nothing
forces the sets to match, which is what the requirement asks for.

**C4 — portability by construction: holds with a visible boundary.** A
component built from core primitives is portable; one built from a
platform's extras is not, and the platform name at the call site says
so. This is the honest reading of "the same syntax": the syntax is the
same, the available nouns are not, and pretending otherwise would be the
implicit magic the design rejects.

**C5 — the platform difference is confined to the backend: holds only if
layout and events are backends too.** The spike confined *painting* to
the backend while computing layout in the shared layer. The design here
moves layout into the backends (via the portable vocabulary) and events
into a tag contract, so the shared layer is genuinely platform-free.
This is a change from the spike, and the reason is that the spike's
shared layout could not scale to the Web or honor native metrics.

**What the requirement understates.** "Same syntax, different component
libraries" is necessary but not sufficient. Two programs that share a
syntax can still diverge completely in *behavior*: a Web form posts, a
macOS button fires a callback, a TUI reads a key. The design's job is
the **semantic contract** the four backends implement — the portable
layout vocabulary, the component-name convergence, the event-tag
protocol, the update loop. The syntax is the least of it.

**Where it can fail.** The failure mode is not "the syntax does not
work"; it is a platform package that quietly implements a core component
with different semantics (a `row` that wraps on the Web and does not on
AppKit), or a component library that grows a platform-specific verb that
users then build on, fragmenting the portable set. The defenses are the
convergent-name rule, a conformance corpus (the same app on every
backend), and keeping platform extras visibly namespaced.

## A worked shape

The architecture's practical result is one shared application module and
a thin per-platform entry module, which is exactly the spike's split
generalized:

```emo
// app.emo — portable: components, update, view. No platform name.
def view(model Model) ui.Node { ... }

// main_macos.emo
require "ui_macos"
ui_macos.run(app.view, app.update, Model.new(0))

// main_web.emo
require "ui_web"
ui_web.run(app.view, app.update, Model.new(0))

// main_tui.emo
require "ui_tui"
ui_tui.run(app.view, app.update, Model.new(0))
```

A bare def is a value — locally and module-qualified (probe 5) — so
`app.view` and `app.update` can be passed directly. They land in `Block`
parameters, which are `Unknown`, so the entry's wiring is the same
unchecked-callback boundary as Layer 1.

`app.emo` is the same file for all three; only the entry module differs,
and it is a handful of lines. A platform-specific app that wants
`ui_macos.table` writes it in its entry or in a macOS-only component
module; the portable components never mention it. This is the direct
answer to the requirement: **same composition, per-platform libraries,
the delta isolated to a small entry module and a package dependency.**

## Packaging: standard library or third-party

Both were on the table. The recommendation is **third-party, its own
repository** (`github.com/emo-lang/emo-ui`, the link already in the
README), with the portable core as an ordinary Emo package.

**Revised 2026-10-15:** its own *repository* became its own *project
directory* — `projects/emo-ui/` in this repository, named after the
repository it can still be split out into (`CHECK.md`). The
standard-library half of the question is untouched: the portable core
stays an ordinary package, not a stdlib one. What the in-tree move
does cost is the decoupling the separate repository would have bought —
UI releases now ride the compiler's repository and CI — accepted for
now in exchange for not maintaining a second repository in step.

Reasons for third-party:

- **The standard library ships inside the compiler as embedded data**
  (step 24, `CHECK.md`); a UI framework with per-platform native shims
  would bloat that binary and couple UI releases to compiler releases.
- **The native backends need manifest features the stdlib convention
  does not use** (frameworks, `pkg-config`), and a third-party package
  can grow those without changing the compiler's bundled registry.
- **The stdlib is the portable, byte-identical tier.** `plot` earns its
  place there because it is pure Emo on all five targets. EmoUI's
  backend packages are target-specific and native; only the core is
  stdlib-shaped.
- The README already positions EmoUI as a separate project, which is
  itself a decided statement.

The counter-argument — that a stdlib `ui` core would be discovered by
every user and get the UI-driven compiler work the language already paid
for — is real, and the resolution is a **possible later split**: the
portable core (`ui`) and the pure-Emo backends (TUI, SSR) could move
into the stdlib once they are stable, leaving the native/DOM backends
third-party. That is a decision to revisit after v1, not now.

## Language and compiler asks

Made explicit so they are decided deliberately rather than discovered
mid-implementation:

1. **A checked block/function type (optional).** `Block` is `Unknown`, so
   the component API's callbacks and tree blocks are unchecked. A typed
   block would let `each(xs, f: (T) Node)` be verified. Convenience, not
   a gate; the array-child form keeps the tree checked without it.
2. **No implicit child collection — by design.** Do not add a construct
   that collects a block's expression statements. That is a template
   language, and the array argument already expresses the tree
   explicitly.
3. **Package native-input extension (a real gate for native backends).**
   `.c`/`.h` plus bare `-l` cannot express AppKit (`.m`, frameworks) or
   GTK (`pkg-config`). Add a per-package compile-flags / `pkg_config`
   mechanism — **settled 2026-10-14 to this route, not the documented
   app-level build-script route** (`CHECK.md`); the field surface is
   T48.7's own work.
4. **Memory reclamation on the `c` target — settled 2026-10-14 to
   refcounting the value families.** The region route was tested and
   ruled out (`spike/arena-scope`, `CHECK.md`); it is scheduled as its
   own milestone (step 49) and is explicitly **not** a gate for the
   native backends, which ship at demo scale with the limit documented.
5. **`raise` and `send` on the `c` target — settled 2026-10-15 to the
   promise already made** (`CHECK.md`, step 50). A UI must not die
   wholesale on one bad event, and event payloads crossing processes must
   not be silently shared — both are what `docs/intro/concurrency.md`
   and `docs/intro/syntax.md` already say. The `c` target was the one
   implementation that diverged; a child's `raise` now ends only that
   child and `send` snapshots. The `typescript` target's share-on-send is
   the same gap on the Web path below.
6. **A browser path for the Web (T1) — settled 2026-10-15 to the split
   route:** a browser-safe subset of the TypeScript runtime, a `dom_*`
   family, and a bundling step, rather than new wasm host imports
   (`CHECK.md`). Where the bundling step lives in the toolchain is
   T48.10's own work. Not needed for SSR (T0).
7. **Terminal input.** Raw mode and key events for the TUI (a small
   termios binding, or a terminal runtime implementation). **Settled
   2026-10-15: a standard-library package, shipped the `sqlite3` way**
   (`CHECK.md`) — package-carried `.c`/`.h` sources reached through
   `foreign def`, gated by the manifest's `targets`, embedded with the
   rest of the stdlib. Raw mode is a capability any TUI program needs,
   so it belongs beside `os` and `file` rather than inside the UI
   framework that happens to be its first consumer.
8. **No new syntax.** The tree is already expressible; if it is not, the
   gap is a type or a library function, not a construct.

## Risks

- **Semantic drift across backends.** The syntax converging does not
  make a `row` mean the same thing everywhere. Mitigation: a small,
  declarative layout vocabulary, a convergent-name rule, and a
  conformance corpus (one app, every backend).
- **Text.** Portable automatic layout needs text metrics; the design
  avoids needing them by delegating layout to the platform (and the TUI
  counts cells). A future canvas or a pixel-identical mode reintroduces
  the font-metrics problem `docs/visualization.md` declined.
- **Native packaging.** Until the manifest grows flags, macOS/GTK apps
  carry build scripts; that is friction on the requirement's "just
  download and use". The manifest-field route is settled (T48.7), so the
  risk is the schedule, not the direction.
- **Two event loops** (Emo scheduler vs. toolkit/browser), as above.
- **Scope.** A UI framework is unbounded. The tier table is the defense:
  portable core + TUI + SSR first, native toolkits next, DOM last; no
  layout parity guarantee, no animation, no accessibility story in v1
  beyond what the native widgets give.
- **No generics and no default parameters.** Node arrays are `Array[Node]`
  (fine — the interface is the element type), but style factories carry
  `N` copy methods, exactly as `plot` accepted. Bounded boilerplate.
- **Long-running memory on the `c` target.** A UI allocates a tree per
  event, and the value-semantic half of that is never freed; a region
  reclaims the bytes and not the identity leak (`spike/arena-scope`).
  v1's mitigation is scope — native backends at demo scale — with
  refcounting the value families scheduled as its own milestone
  (step 49). The quadratic `Array` build is the same finding's second
  edge; `ArrayBuilder` answers it (T49.3), and the portable core takes
  it up — a child list is grown with `push` rather than rebuilt per
  child (T48.1).

## Prior art, and what to borrow

Mechanisms may be borrowed; no single language's look may be copied.

- **Elm** — the model/update/view architecture, effects as messages.
  Take the loop; do not take a new `Msg`-heavy vocabulary beyond Emo's
  own enum and tuple idiom.
- **React / Solid** — the component-as-function, the tree value, and
  reconciliation. Take reconciliation as a backend concern; Solid's
  fine-grained signals are close to the README's explicit reactivity,
  but its implicit tracking graph is the "hidden dependency graph" the
  README rejects.
- **SwiftUI / Compose** — declarative trees and the modifier idea.
  Take the tree; reject the modifier chain (the spike deliberately used
  an unordered style value, and `docs/visualization.md` uses `with_*`
  copies — same reason).
- **GTK / AppKit** — the native widgets and layout engines EmoUI maps
  onto. They are the platform, not a model to copy.
- **Textual / Ratatui** — the terminal backend: a cell grid, a widget
  tree, key events. Borrow the grid, not the widget vocabulary.
- **htmx / server-rendered HTML** — the T0 Web: the server owns state,
  the page is a render. Borrow the model; Emo's own renderer already
  exists in `plot`'s SVG shape.
- **Iced / egui / Druid** — the retained-vs-immediate split in Rust's
  lineage. Worth reading for the reconciliation decision; not a
  stylistic source (and Rust specifically is the design's negative
  reference).

## Recommendation

The defensible direction, stated as a product:

**A third-party EmoUI project — a portable `ui` core (node model,
portable layout vocabulary, typed style, Elm loop, event tags, backend
interface) plus one package per platform. Sequence: (1) the core and the
TUI backend (pure Emo, no toolchain, it proves backend-neutrality);
(2) the SSR HTML/CSS backend (pure Emo, byte-identical goldens); (3)
macOS and GTK 4 backends over the proven `foreign def` shims, with the
packaging question settled first and the `c` target's memory limit
documented — demo scale until value-family reclamation lands as its own
milestone (step 49); (4) the browser DOM backend on the
TypeScript target, which needs a browser-safe runtime, a `dom_*`
capability layer, and a bundling step. Children are an explicit
`Array[Node]`; trailing blocks are for `each`/callbacks and return their
value. No new syntax.**

The requirement is achievable, but it should be judged on the semantic
contract, not the syntax — the syntax already works, and the four
backends are four different programs.

## Decisions recorded (2026-10-14)

1. **EmoUI is a project of its own**, not a standard-library package; a
   stdlib move for the portable core and the pure-Emo backends is a
   possible later split, not v1. **Revised 2026-10-15:** it is hosted in
   this repository under `projects/emo-ui/`, not in a separate
   repository created up front (`CHECK.md`, the in-tree project
   layout). The not-a-standard-library-package half stands unchanged —
   the stdlib embed walks `stdlib/registry` alone, so an in-tree
   `projects/emo-ui` never enters the compiler binary.
2. **The tree type is a multi-module `ui.Node`** (interface spine +
   concrete classes with typed props), not a single stringly-tagged
   class and not one class per platform with no core.
3. **Children are an explicit `Array[Node]`.** Trailing blocks are for
   callbacks and iteration and must `return` their value; no implicit
   child collection, and the README's illustrative tree is revised to
   this spelling.
4. **Layout is a portable vocabulary mapped to the platform's native
   layout**, not a shared Emo layout engine. The TUI keeps a small Emo
   box model because it has no native engine.
5. **Style is a typed value with a factory and `with_*` copies**, no
   stringly map and no default parameters.
6. **State is Elm** (model, `update`, `view`) over explicit language
   primitives (`Box`/`List`/`Map`); events are typed messages registered
   Emo-side and exposed to the backend as `Int64` tags.
7. **The backend is an Emo interface** (`mount`/`patch`/`run`); the
   nine-verb `ui_*` contract is the native implementation detail.
8. **Platform libraries share convergent names** for equivalent
   components; platform-specific components carry the platform package's
   name at the call site.
9. **Sequencing: TUI and SSR first, native toolkits next, DOM last.**
10. **No new syntax.** The one language ask worth weighing is a checked
    block/function type; it is not a gate.
11. **The probe findings are evidence** (`spike/emo-ui-probe`): a `Block`
    parameter is `Unknown`; a Void block yields `void`; recursive node
    classes and self-naming interfaces now check; iteration blocks that
    return work; a bare def (local or module-qualified) is a value that
    satisfies a `Block`; default parameters are refused (E4009).
12. **The `c` target's long-running memory is not a region problem.**
    Settled 2026-10-14 by the arena-scope spike: a region reclaims 100%
    of the arena's bytes and 0% of the identity leak, and strands those
    refcounts permanently; the fix is refcounting the value families.
    T48.8/T48.9 therefore proceed at demo scale with the limit
    documented, and reclamation is its own milestone — **not** a
    prerequisite for the native backends (`CHECK.md`,
    `spike/arena-scope/`).

Decisions 1–11 are tracked as **M15 — EmoUI (step 48)** in
[`TASKS.md`](TASKS.md), with the full step spec in
[`plan/step-48-emo-ui.md`](../plan/step-48-emo-ui.md); decision 12 is
tracked as **M16 — Value-family reclamation (step 49)**, spec in
[`plan/step-49-value-reclamation.md`](../plan/step-49-value-reclamation.md).

## Remaining open questions

1. **The native packaging mechanism** — direction settled 2026-10-14 to
   per-package manifest fields, superseding the app-level build-script
   alternative; the field surface (`pkg_config`, compile/link flags,
   whether `.m` is collected) is T48.7's own work. This gates item 3 of
   the sequencing.
2. **Reconciliation** — when the retained backends get a keyed diff
   instead of a full rebuild, and whether the compiler's targeted
   refresh lands with it.
3. **The two-event-loop integration** — how a UI process and a toolkit
   loop coexist, and whether events become real process messages in v1
   or later.
4. **The checked block/function type** — whether the component API
   earns it after a first package shows the friction.
5. **The Web T1 boundary** — route settled 2026-10-15: a browser-safe
   subset of the TypeScript runtime plus a `dom_*` family, not a
   browser-specific runtime variant (`CHECK.md`). What stays open is
   mechanical: where the bundling step lives in the toolchain, which is
   T48.10's own work. The `typescript` target's share-on-send
   (`CHECK.md`, cross-target invariants) is on this path too.
6. **The tree spelling** — whether the array child form gets a literal
   spelling at all, and if so whether it belongs in Emo's own grammar or
   in an external translator that emits `.emo`. The mechanisms that are
   *closed* (emission, self-rebinding, an ambient collector, and a
   template engine with its own evaluation) are recorded in
   [`emo-ui-composition.md`](emo-ui-composition.md), which also names
   the evidence that would settle this one.
