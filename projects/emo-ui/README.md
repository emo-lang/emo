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

The portable **`ui` core** has landed (T48.1). `ui.emo` is the node spine — an
`Node` interface plus the `Column`, `Row`, `Text`, `Button`, `TextInput`,
`Image`, `Spacer` and `Scroll` classes with their positional lowercase
constructors — the typed `Style` with its `style()` factory and `with_*` copies,
the layout vocabulary (`Align`, and padding, gap, grow, width and height on the
style), and the `Backend` interface (`mount`/`patch`/`run`). It is pure Emo,
with no platform and no FFI, and it declares all five hosted targets; `./check.sh`
is its gate.

Still to come: the Elm loop (T48.2), the headless `debug` backend (T48.3), and
one package per platform behind the browser runtime path (T48.4–T48.12). The
design and its evidence:

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
and no compiler build sweeps them in. Each later backend is a package of its
own: a subdirectory with its own `package.emo`, which the module walk leaves out
of this package entirely, exactly as `spike/emo-ui-spelling/mismatch/` does.

The scope is spelled `emo_lang` rather than the organization's hyphenated name:
a `deps` key is a scoped identifier, and neither a keyword (`emo`) nor a hyphen
(`emo-lang`) can appear in one.
