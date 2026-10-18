# EmoUI package references

One page per public package in `projects/emo-ui/`. Each reference states
the package's manifest (name, targets, native fields), its entry points
as they are declared in the source, and the behavior a caller can rely
on. `golden/` is the shared harness rather than a public package; its
gates are described in the top-level README.

| Package | What it is |
|---|---|
| [`ui`](ui.md) | The portable core: nodes, styles, the Elm loop, the backend interface |
| [`debug`](debug.md) | The headless backend and the stable text form (a module of `ui`) |
| [`ui_tui`](ui_tui.md) | The terminal backend and its cell box model |
| [`ui_ssr`](ui_ssr.md) | The server-rendered HTML/CSS backend |
| [`ui_macos`](ui_macos.md) | The macOS/AppKit backend |
| [`ui_gtk`](ui_gtk.md) | The GTK 4 backend |
| [`ui_browser`](ui_browser.md) | The DOM backend |
| [`ui_corpus`](ui_corpus.md) | The shared application every backend runs |

An application depends on `emo/ui` plus one backend package and calls
`ui.run(view, update, model, backend)`. The design these packages
implement is stated in the repository's `README.md`; the evidence and
the open questions are in [`docs/emo-ui.md`](../../../docs/emo-ui.md).
