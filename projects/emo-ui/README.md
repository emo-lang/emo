# EmoUI

The component-based UI framework written in Emo: one declarative tree rendering
on a terminal, a server-rendered page, a macOS/AppKit window, and a GTK 4 window
— the browser DOM following its runtime path. Emo's syntax is shaped to serve
it, and the principle is **no template language — the UI is plain Emo code**,
the same philosophy as configuration.

A component tree is nested calls with blocks:

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }
}

list(users) -> (user User) {
  card(user) {
    text(user.name)
    text(user.bio)
  }
}
```

## Status

**Nothing is implemented here yet.** The design is settled and this directory is
where the packages land; T48.1, the portable `ui` core, is the first task. The
design and its evidence:

- [`docs/emo-ui.md`](../../docs/emo-ui.md) — the assessment and the design direction.
- [`docs/emo-ui-composition.md`](../../docs/emo-ui-composition.md) — how a tree gets written: why components return children instead of emitting them.
- [`plan/step-48-emo-ui.md`](../../plan/step-48-emo-ui.md) — the execution plan, T48.1–T48.13.
- [`spike/emo-ui-spelling/`](../../spike/emo-ui-spelling/) — the two-screen measurement that settled the spelling, and `ui.emo`, the prototype of the core.
- [`spike/emo-ui-probe/`](../../spike/emo-ui-probe/), [`spike/components/`](../../spike/components/), [`spike/macos-gui/`](../../spike/macos-gui/), [`spike/gtk/`](../../spike/gtk/) — the language-feature and native-toolkit evidence.

## Where this directory sits

EmoUI is a **project of its own**, not a standard-library package: the standard
library embeds inside the compiler binary as generated data, and a UI framework
carrying per-platform native shims does not belong there. It lives in the
compiler's repository as `projects/emo-ui/`, named after the repository it can
be split out into, so that `git subtree split -P projects/emo-ui` later yields
the standalone repository with its history (`CHECK.md`, the in-tree project
layout).

The directory is rooted by its own `package.emo`, like any other Emo project —
the repository root carries no manifest, so this package's modules are checked
as its own program and no compiler build sweeps them in.
