# The `ui_corpus` Package

The convergence corpus: the one application every EmoUI backend runs,
unchanged. It is a package of its own — `emo/ui_corpus`, pinned against
`emo/ui` — and carries no platform. Each backend's entry module requires
it and hands its three functions to `ui.run`; between backends only the
backend package and that entry module differ.

## Using the package

```emo
require "emo/ui"
require "emo/ui_corpus"
```

The package is `emo/ui_corpus` version `0.1.0`; a manifest pins both it
and `emo/ui` in `deps`.

## The application

```emo
enum Msg { inc, dec, submit }

class Model {
  def init(count Int64)
  def count() Int64
}

def initial() Model
def update(msg Msg, m Model) Model
def view(reg ui.Registry, m Model) ui.Node
```

The state is a counter. `view` registers its three messages in
statements of its own — `inc`, `dec`, `submit` at tags `0`, `1` and `2`
— and builds a titled column: two buttons in a row, an input showing the
count, a scrolled list of two texts and an image, a submit button, and a
growing spacer. The children are an explicit `Array[ui.Node]`, with the
list assembled through `ArrayBuilder`.

`update` prints each state transition (`inc 1`, `dec 0`, `submit 0`), so
the corpus's output is the loop's bytes rather than any one backend's
rendering. That is what lets one `expected.txt` be pinned on every
entry.

## Entries and the gate

Six entries consume the package:

| Entry | Backend | Gate |
|---|---|---|
| `corpus/debug` | `ui.debug` | `projects/emo-ui/check.sh` |
| `corpus/ssr` | `ui_ssr` | `projects/emo-ui/check.sh` |
| `corpus/tui` | `ui_tui` | `projects/emo-ui/check.sh` |
| `macos/corpus` | `ui_macos` | `macos/check.sh` |
| `gtk/corpus` | `ui_gtk` | `gtk/check.sh` |
| `browser/corpus` | `ui_browser` | `browser/check.sh` |

Each entry is a `require` of the shared package plus a single `ui.run`
over that backend. The debug entry steps `inc, inc, dec, submit` by hand
through `deliver` and prints the trees it logged; the SSR entry steps
the same four through the printing backend. The TUI, macOS, GTK 4 and
browser entries run the same tags as a script — `0,0,1,2` — through
their own input source.

`corpus/check.sh` stages the core, the corpus, `ui_ssr` and `ui_tui`
into a content-named registry and pins one `expected.txt` per entry:
the debug and SSR entries are byte-identical on all five hosted targets
(`ocaml`, `c`, `typescript`, `wasm` and `beam`), and the terminal entry
on `ocaml`, `c`, `typescript` and `beam`, with its `wasm` refusal pinned
by name.
