# EmoUI

The component-based UI framework written in Emo: one declarative tree rendering
on a terminal, a server-rendered page, a macOS/AppKit window, a GTK 4 window,
and the browser DOM. Emo's syntax is shaped to serve
it, and the principle is **no template language — the UI is plain Emo code**,
the same philosophy as configuration.

A component tree is nested calls over an explicit `Array[ui.Node]`:

```emo
def card(user User) ui.Node {
  return ui.row([
    ui.image(user.avatar(), ui.style().with_width(32.0)),
    ui.text(user.name(), ui.style())
  ], ui.style().with_gap(8.0))
}

def inbox(users Array[User]) ui.Node {
  const rows = ArrayBuilder.new()
  for var i = 0; i < users.length(); i = i + 1 {
    rows.push(card(users[i]))
  }
  return ui.column([
    ui.text("Inbox", ui.style()),
    ui.column(rows.to_array(), ui.style().with_padding(12.0))
  ], ui.style())
}
```

Children are an argument, never a block: a trailing block is for callbacks and
iteration, and where it produces a value it returns it. A child list that is not
known until it is walked is built with the language's `ArrayBuilder` and handed
over as `to_array()` — which is the container question the two-screen
measurement settled (`docs/emo-ui.md`, decision 3; `spike/emo-ui-spelling`).
Whether the array form later earns a literal spelling of its own is still open
(`docs/emo-ui-composition.md`).

## Status

The portable **`ui` core** (T48.1), the **Elm loop** (T48.2), the headless
**`debug` backend with its golden** (T48.3), the **terminal `ui_tui` backend
with its scripted-input golden** (T48.4), the **server-rendered `ui_ssr`
backend** (T48.6), the **native `ui_macos` backend with its self-driving
corpus** (T48.8), the **GTK 4 `ui_gtk` backend** (T48.9) and the **browser
`ui_browser` backend with its DOM corpus** (T48.10, T48.11) have landed. So
has terminal input itself (T48.5), as the
standard-library **`term` package** in `stdlib/` — line reads, raw mode,
decoded key events, and the terminal's size, in the `sqlite3` shape and
reached by an ordinary `require`.
`ui.emo` is the node spine — a `Node` interface plus the `Column`, `Row`, `Text`,
`Button`, `TextInput`, `Image`, `Spacer` and `Scroll` classes with their
positional lowercase constructors — the typed `Style` with its `style()` factory
and `with_*` copies, the layout vocabulary (`Align`, and padding, gap, grow,
width and height on the style), the `Backend` interface (`mount`/`patch`/`run`),
and the loop: `App`, plus the `Registry` an event is tagged in. It is pure Emo,
with no platform and no FFI, and it declares all five hosted targets.

An application is a model, a pure `update`, a pure `view`, and a backend:

```emo
def update(msg Msg, m Model) Model { ... }

def view(reg ui.Registry, m Model) ui.Node {
  return ui.button("+", reg.on(Msg.inc), ui.style())
}

def main() {
  ui.run(view, update, Model.new(0), backend)
}
```

The tag table is the loop's own object, not the module-level `ui.on(msg)` table
`docs/emo-ui.md`'s Layer 5 sketches: a module-level `const` re-runs its
initializer on every read on the compiled targets, and a module-level `var` is
`ocaml`-only, so a table kept there would hand every read a fresh, empty one
(`CHECK.md`, module-level bindings). The table belongs to one running loop, and
`view` is handed it. The tags are taken in statements before the tree is built
rather than inside the arguments the tree is made of: `on` is a side effect, and
operands are evaluated in the target's order — `ocaml`'s is the reverse of every
other target's — so a tag taken from an argument position is a different tag per
target (`CHECK.md`, operand evaluation order).

The loop compiles and runs on all five hosted targets. A bare def name is the
only expression that yields the `Block` value `ui.run` takes, and `c` had no
def-as-value (`Global`); T48.8 gave it one — every def gets a dynamic thunk,
and a def named as a value becomes an empty-capture closure over it — so the
`c`-hosted backends compile the same loop as the rest. `wasm` had refused the
shape until T48.6, when its closures grew any arity: `Call_value`, `Closure`
and a `Global`'s lifted function allocate a function/struct type pair per
arity (`closure_type`), so a `Block` value is first-class however many
parameters it takes. `probe/` keeps both shapes as a minimal pair —
`def_shape/` is the landed spelling and now builds on all five targets,
`handler_shape/` is the same loop with the application's two functions behind a
`Handler` interface, and it prints what `emo run` prints on `c` and `ocaml`
(`CHECK.md`, the Elm loop's shape). The decision went to growing the target:
def-as-value was a backend gap rather than new syntax, and it kept the landed
`ui.run` spelling. On `beam` the loop built but did not run until T48.4: a bare
def became a remote fun to a non-exported function, which `erlc` accepted and
the loader left uncallable; that is fixed, and the TUI golden is what proves
it.

`debug.emo` is the headless backend (T48.3): `render(node)` turns a tree into
stable text — one node per line, two spaces per level, the node's own props then
a style summary in a fixed field order — and the `Debug` class implements
`Backend` over that text, logging every tree the loop hands it instead of
printing it, so the caller decides when text reaches stdout. Its `run()` drives
nothing, because headless means there is no input source: an event is stepped by
hand through `deliver`, on the sink `mount` was given.

`golden/` is what the text form is for: the harness the core and every later
backend are measured against. It is a package in the consumer's position —
`deps { "emo/ui" = "0.1.0" }` and a `require`, reached through a registry the
gate stages from the sources under test — and it holds one screen that carries
every primitive, both `w=`/`h=` branches, all four `Align` values, an empty
string prop and nested containers. `expected.txt` is the interpreter's own
output; `./check.sh` builds and runs that screen on every target and requires
those bytes exactly, so a backend that renders a tree differently fails here
rather than in a screenshot.

The text form is narrower than it looks, and the targets are why: it
interpolates only `String`, `Int64`, `Bool` and `Float64`, because interpolating
an enum or a tuple does not produce the same bytes on every target — `typescript`
qualifies the name and `beam` has no conversion for the kind at all — so the
style summary destructures (`align_name`, `extent`) and spells the names it
prints itself. That divergence is recorded, with a minimal pair, in `CHECK.md`
(`probe/enum_print`). The golden also takes its event tags in statements before
it builds a tree, never inside the argument list the tree is made of: `on` is a
side effect, and the statements keep the registration order visible at the call
site. Operand order itself is no longer a cross-target variable — the language
states left to right, and every target obeys it — and `probe/eval_order` pins
the rule.

`./check.sh` is the gate: the package type-checks, the loop's seventeen
assertions run, every target's build — and every refusal — is pinned there, and
the golden's bytes are compared on all five hosted targets (the `wasm`
artifact under the host boundary in `wasm-runner.mjs`). It ends by running
`tui/check.sh`, `ssr/check.sh`, `macos/check.sh`, `gtk/check.sh` and
`browser/check.sh`, so the project keeps one entry point.

`tui/` is the terminal backend (T48.4), a package of its own — `emo/ui_tui`,
pinned against `emo/ui` — because it carries a platform the core does not. The
terminal has no native layout engine, so the box model lives here: the core's
`Style` measured in character cells, a column stacking, a row lining up, and
`padding`/`gap`/`align`/`grow`/`width`/`height` placing each child.
`screen(root, w, h)` returns the grid as `Array[String]`, so the arithmetic is
testable without bytes; `paint(root, w, h)` writes a frame as ANSI — clear, home,
one row per line — with the escape byte reaching stdout through
`printf("%c", [27])`, because a string literal's escapes are the minimal set and
0x1b is not one of them. `Tui` implements `ui.Backend` over that, and
`Input`/`Script` are the scripted event source: `run()` pulls tags from the input
and hands them to the loop's sink until the input says there are no more. The
`term` package (T48.5) supplies raw-mode terminal reads for a real source;
adopting it replaces that source, not the seam — both are `Input`. The package declares the four hosted targets that can write stdout;
`wasm` has no `printf`, so it is not one. `tui/golden/` is a consumer of both
packages, holding one screen driven by a script that clicks Add, Add, Sub, and
its `expected.txt` is the interpreter's output, identical on `ocaml`,
`typescript` and `beam` — `c` refused the golden's loop shape (`Global`) until
T48.8 gave the target def-as-value. `tui/check.sh` is the package's gate; the `beam` lowering defects the golden forced are fixed and
recorded in `CHECK.md`. The usage demo lives at `examples/tui_menu/` — a
terminal menu driven by a scripted input — and the same gate checks it.

`translator/` is the `.emoui` experiment (2026-10-18): a stdin-to-stdout
filter that lowers a tree literal — containers with blocks,
`list(src) -> (x T) { ... }`, `if` — into the settled spelling of nested
calls with explicit `Array[Node]` children, making the README's
illustrative form writable with no compiler change. Its `demo/` rewrites
the spelling spike's two screens in the literal form and asserts, through
the debug backend, that the generated trees equal the hand-written A
spelling beside them on four models; `demo/check.sh` is the gate,
regenerating the committed output and diffing it against the translator.
The grammar and the lowering rules live in `translator/README.md`; where
this sits in the C-versus-D question is recorded in
[`docs/emo-ui-composition.md`](../../docs/emo-ui-composition.md).

`ssr/` is the server-rendered backend (T48.6), a package of its own —
`emo/ui_ssr`, pinned against `emo/ui`. It turns the portable tree into HTML
plus the stylesheet its styles intern into: `page(title, root)` for a whole
document, `fragment(root)` for a region a browser swaps in, and
`stylesheet(root)` for the CSS alone, all walking the tree pre-order so the
classes a page's markup carries are the ones its stylesheet defines. A node's
class comes from interning on its base declarations and its `Style` — equal
styles share one rule, while a `row` and a `column` stay distinct — and every
prop reaching markup is escaped byte by byte, so a multi-byte character rides
through unchanged. The interaction model is the two things a browser can do
without a client runtime: a `form` posts its fields and the event tag of the
button that submitted it, and a `link` navigates. Three nodes live here rather
than in the core — `form`, `link` and `field` — because only a server round
trip has anywhere to put them. `Ssr` implements `ui.Backend` with `mount`
printing the document, `patch` the fragment, and `run()` returning, because a
server has no input source; `deliver(tag)` is the request that steps one
event. `test.emo` pins escaping, the rule shape, interning and one assertion
per node kind in twelve assertions, and `golden/` — a consumer of both
packages — is byte-identical on all five hosted targets. `ssr/check.sh` is the
package's gate; the usage demo is `examples/ssr_page/`.

`macos/` is the native backend (T48.8), a package of its own — `emo/ui_macos`,
pinned against `emo/ui`, declaring the `c` target and the `AppKit` framework.
The window has no layout engine the core can reach either, so the box model
lives here as `box.emo`: the core's `Style` measured in points, and
`layout(root, w, h)` returning the `Array[Draw]` whose positions `place`
applies — arithmetic the interpreter runs without a session. `shim.m` is the
AppKit side of the nine verbs `ui_macos.emo` declares as foreign defs:
`window_make`, `label_make` and `button_make`, `place`, `clear`, `connect`,
`root`, `run` and `autotest_arm`. The loop's sink crosses the FFI as
`ui.Events`, a single-method interface, which the C ABI hands over as a
trampoline and a userdata pair; a click carries its tag back through that pair.
`place` flips y, because AppKit's origin is the bottom left. `autotest_arm`
takes a comma-separated tag script and, only under `EMO_GUI_AUTOTEST`, an
`NSTimer` clicks each tag in turn and terminates, so the gate needs no one at
the keyboard and no screenshot. `corpus/` is the convergence consumer — every
primitive on one screen, the script `0,0,1,2`, and `expected.txt` holding the
loop's bytes. `macos/check.sh` is the package's gate and runs only on Darwin;
the shim is the project's only Objective-C outside `spike/`. Demo scale: the
`c` target's long-running memory is step 49 (`CHECK.md`).

`gtk/` is the GTK 4 backend (T48.9), a package of its own — `emo/ui_gtk`,
pinned against `emo/ui`, declaring the `c` target and the `gtk4` pkg-config
module. It is the same shape as the macOS package: `box.emo` carries the point
model, `ui_gtk.emo` the nine foreign verbs and the `Gtk` class, and `shim.c`
the C side. GTK is already C, so the shim is thinner — the signal handler and
the self-driving script are what Emo cannot name — and `place` applies x and y
unchanged, because GtkFixed's origin is already the top left. The loop's sink
crosses the FFI as the same `ui.Events` pair. `corpus/` is the same convergence
consumer, with the same `0,0,1,2` script and `expected.txt`. `gtk/check.sh` is
the package's gate: it builds and runs natively where `pkg-config gtk4`
answers, and otherwise compiles and runs the same generated C in the
`emo-ui-gtk-build` container (GTK 4 plus Xvfb), which is how a macOS host
checks it; with neither it says so and passes.

`browser/` is the DOM backend (T48.11), a package of its own —
`emo/ui_browser`, pinned against `emo/ui`, declaring the `browser` target and
reached through the runtime path T48.10 added. The browser has a layout engine,
so the package carries no box model: `css.emo` maps a `Style` to the
declarations the page's own layout consumes, and it is pure Emo, so the
interpreter runs `test.emo`'s twenty-seven assertions. `ui_browser.emo` is the
`Dom` class over the thirteen `dom_*` calls: `mount` sets the title, the
page-root declarations and the sink; `render` builds one element per node — a
`text` is a span, a `button` carries its tag as the `name`/`value` pair
`ui_ssr`'s markup uses, an `input` is a read-only view, an `image` is an `img`
— and `patch` rebuilds the tree, as every backend does. `run()` returns,
because the page owns the loop. `corpus/` is the convergence consumer — the
same application, the same `0,0,1,2` script and `expected.txt` — and `page.mjs`
is the stub page the gate runs it in: a `document`/`window` just large enough
for the host, then the script's tags clicked in order. `browser/check.sh` is
the package's gate; it needs Node >= 22.13 for `emo build --target browser`'s
bundling step, and says so and passes where that is missing.

Still to come: wiring `term` into `ui_tui`'s input source, and the
cross-backend convergence corpus (T48.12–T48.13). The design and its evidence:

- [`docs/emo-ui.md`](../../docs/emo-ui.md) — the assessment and the design direction.
- [`docs/emo-ui-composition.md`](../../docs/emo-ui-composition.md) — how a tree gets written: why children are an array rather than a block form.
- [`plan/step-48-emo-ui.md`](../../plan/step-48-emo-ui.md) — the execution plan, T48.1–T48.13.
- [`spike/emo-ui-spelling/`](../../spike/emo-ui-spelling/) — the two-screen measurement that settled the spelling, and the prototype this core came from.
- [`spike/emo-ui-probe/`](../../spike/emo-ui-probe/), [`spike/components/`](../../spike/components/), [`spike/macos-gui/`](../../spike/macos-gui/), [`spike/gtk/`](../../spike/gtk/) — the language-feature and native-toolkit evidence.

## Where this directory sits

EmoUI is a **project of its own**, not a standard-library package: the standard
library embeds inside the compiler binary as generated data, and a UI framework
carrying per-platform native shims does not belong there. It lives in the
compiler's repository as `projects/emo-ui/`, named after the repository it can
be split out into, so that `git subtree split -P projects/emo-ui` later yields
the standalone repository with its history (`CHECK.md`, the in-tree project
layout).

The directory is rooted by its own `package.emo` — the portable core's, whose
`ui.emo` is the module `require "emo/ui"` binds — and the repository root
carries no manifest, so this package's modules are checked as its own program
and no compiler build sweeps them in. The `debug` backend is a *module* of that
package rather than one of the packages below, because it carries no platform
and no native code: `debug.emo` sits beside `ui.emo`, which also lets the core's
own test exercise it. Each later backend is a package of its own: a subdirectory
with its own `package.emo`, which the module walk leaves out of this package
entirely, exactly as `spike/emo-ui-spelling/mismatch/` does. `golden/` is the
first of those — a consumer rather than a backend, but a package of its own for
the same reason, and the one whose `deps` entry exercises the registry flow the
platform packages will use.

The scope is `emo`, the same one every package in this repository carries: a
`deps` key is a string literal, so a package name is data rather than something
the lexer has to accept (T11.9).
