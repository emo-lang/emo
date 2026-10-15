# EmoUI

The component-based UI framework written in Emo: one declarative tree rendering
on a terminal, a server-rendered page, a macOS/AppKit window, and a GTK 4 window
— the browser DOM following its runtime path. Emo's syntax is shaped to serve
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

The portable **`ui` core** (T48.1), the **Elm loop** (T48.2) and the headless
**`debug` backend with its golden** (T48.3) have landed.
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

The loop compiles on `ocaml`, `typescript` and `beam`. It does not compile on
`c` or `wasm` yet, and what stands in the way is its spelling rather than its
structure: a bare def name is the only expression that yields the `Block` value
`ui.run` takes, and `c` has no def-as-value (`Global`) while `wasm` refuses a
dynamic call with more than one parameter. `probe/` holds that gap as a minimal
pair — `def_shape/` is the landed shape and reaches both refusals,
`handler_shape/` is the same loop with the application's two functions behind a
`Handler` interface, and it builds on all five targets, printing what `emo run`
prints on `c` and `ocaml` (`CHECK.md`, the Elm loop's shape). Which way to close
it — grow the two targets, or move the application's functions behind an
interface — is the open decision T48.4 onward waits on.

`debug.emo` is the headless backend (T48.3): `render(node)` turns a tree into
stable text — one node per line, two spaces per level, the node's own props then
a style summary in a fixed field order — and the `Debug` class implements
`Backend` over that text, logging every tree the loop hands it instead of
printing it, so the caller decides when text reaches stdout. Its `run()` drives
nothing, because headless means there is no input source: an event is stepped by
hand through `deliver`, on the sink `mount` was given.

`golden/` is what the text form is for: the harness the core and every later
backend are measured against. It is a package in the consumer's position —
`deps { emo_lang/ui = "0.1.0" }` and a `require`, reached through a registry the
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
prints itself. The golden also takes its event tags in statements before it
builds a tree, never inside the argument list the tree is made of, because
operands are evaluated in the target's order and `ocaml`'s is the reverse of
every other target's, which would hand the same message a different tag per
target. Both are recorded, with a minimal pair each, in `CHECK.md`
(`probe/eval_order`, `probe/enum_print`).

`./check.sh` is the gate: the package type-checks, the loop's seventeen
assertions run, every target's build — and every refusal — is pinned there, and
the golden's bytes are compared on each of the four targets that can run it.

Still to come: one package per platform behind the browser runtime path
(T48.4–T48.12). The design and its evidence:

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
`ui.emo` is the module `require "emo_lang/ui"` binds — and the repository root
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

The scope is spelled `emo_lang` rather than the organization's hyphenated name:
a `deps` key is a scoped identifier, and neither a keyword (`emo`) nor a hyphen
(`emo-lang`) can appear in one.
