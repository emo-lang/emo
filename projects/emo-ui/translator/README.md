# The EmoUI translator

A `.emoui` file states a component tree the way the README's illustrative
syntax always showed it — containers take their children from a block, an
iteration walks an array, an `if` picks children. The translator lowers
that text to the settled spelling (docs/emo-ui.md, decision 3: nested
calls with explicit `Array[Node]` children) so the ordinary compiler,
checker and backends run on the result unchanged. It is docs/
emo-ui-composition.md's option D: a text transformation with full
knowledge of the target, no compiler change, a second syntax as the
whole cost.

## Usage

The translator is an Emo program and a stdin-to-stdout filter (an Emo
program cannot read its own command line — the `os` package has no
argv):

```sh
cd translator          # the translator's directory is the project root
emo run translate.emo < screens.emoui > screens.emo
```

Generated files are committed beside their sources. `demo/check.sh` is
the gate: it regenerates the demo's `screens.emo` and diffs it against
the committed file (a stale file or a translator change is a diff, never
a silently different tree), then runs `demo/show.emo` — which asserts
the `.emoui` trees equal the hand-written A-spelling trees on four
models — against `demo/expected_show.txt`.

## The `.emoui` grammar (v1)

A file is **require lines and view defs, nothing else** — a `class`,
`const` or `enum` at the top level is refused loudly. Require lines and
comments before the first def are copied verbatim into the output.
Sibling modules (`ui`, `components`, …) are named directly; a packaged
core's `require` lines ride along verbatim.

    file   := (require | comment | blank | view-def)*
    view-def := "def" name "(" params ")" type "{" tree "}"

The def header is copied verbatim; the body is **exactly one tree**
(more or fewer is an error).

    tree      := call | iteration | if
    call      := path "(" args? ")" block?
    iteration := path "(" expr ")" "->" "(" name type ")" block
    if        := "if" expr block ("else" block)?
    block     := "{" (tree)* "}"

- **A call with a block is a container**: the block's items are its
  children. A call without a block is a leaf. There is no third
  reading — EmoUI events are `Int64` tags, never callback blocks, so
  every block in a tree is a children block.
- **`path(expr) -> (x T) { ... }` is an iteration**: the call's name
  never reaches the output; the children are lowered once per element,
  with `x` bound by a `const` (never substituted textually, so an
  indexed source expression is evaluated once, not once per use).
- **An `if` (statement form only — no `else if`, no `case`, no loops)
  picks children**; branches hold trees.
- **Arguments, conditions and iteration sources are opaque spans**,
  copied verbatim — balanced across strings, `${...}` interpolations
  (which nest strings), char literals and comments. The translator does
  not read Emo expressions; the checker downstream does.

## The lowering

- A block whose items are all static (no iteration, no conditional,
  recursively) lowers to an **array literal**: `navbar() { logo()
  menu(routes) }` becomes `navbar([logo(), menu(routes)])`.
- Any other block lowers to **`ArrayBuilder` statements**, one builder
  per dynamic container, numbered in emission order
  (`__kids_1`, `__kids_2`, …, `__src_N`, `__i_N`; counters reset per
  def). An iteration hoists its source (`const __src_1 = m.messages()`)
  so the walked expression is evaluated once, binds the element
  (`const msg = __src_1[__i_1]`), and pushes into the enclosing
  builder.
- The body's root is `return`ed; a dynamic root is returned as
  `__kids_1.to_array()` in its children slot.

## The component table

Names are matched by their **last path segment** (`ui.column` and
`column` both meet the core). The portable core's signatures are fixed,
so:

- `column` / `row` / `scroll` — children from the block (first
  parameter), style from an optional `style:` argument, default
  `ui.style()`. Any other argument is refused.
- `text` / `button` / `text_input` / `image` — props positionally, a
  default style appended; `style:` passes through only when there are
  no positional arguments (Emo refuses positional after named).
- `spacer` — style only.
- **Any other call is a user component**: children pass as a *final
  positional* argument, so a component that takes children declares an
  `Array[ui.Node]` last. A user call cannot mix named arguments with a
  children block — the array is appended positionally.

Everything the translator refuses, it refuses with the 1-based source
line: unterminated blocks and headers, a body that is not exactly one
tree, a root that is an iteration or a conditional, an iteration
without exactly one positional source, a top-level construct that is
not a require or a view def.

## What v1 does not do

- Trees only in the **def-body position** — one tree per view def. A
  tree nested inside an argument expression is not parsed (the free
  variables would need threading); the body convention keeps every
  local visible with no closure analysis.
- No `case`, `while`, `break` or assignments in tree position — `if`
  and iteration cover child selection and repetition. Refused, not
  guessed.
- Comments inside tree bodies are skipped, not carried; each generated
  def carries a `// from line N` provenance note instead. The leaf
  expressions themselves are verbatim, so a checker diagnostic on a
  prop greps straight back to the source text.
- Errors are a raised `Exception` (non-zero exit) with the line
  number; span-accurate diagnostics and an editor grammar are the
  second-toolchain work the composition doc prices, not v1 work.

## Measured

The demo holds the spike's two screens (the measurement
docs/emo-ui-composition.md asked for, now between spellings):

| file | lines |
|---|---|
| `demo/screens.emoui` | 52 |
| `demo/screens_a.emo` (the A reference) | 65 |
| `demo/screens.emo` (generated) | 50 |

The `.emoui` file states the tree; the A file also states the assembly
— three per-element-type defs and the builder statements the
translator writes instead. The equality of the two is asserted, not
claimed: four models (base, empty inbox, shown banner) through
`debug.render`, plus the regenerate-diff on the committed output.

One target note: the demo's `tags.emo` keeps its registry in a
module-level `Box`, whose initializer re-runs on every read on the
compiled targets (CHECK.md, module-level bindings) — on `ocaml` the
absolute tag values differ from the interpreter's, identically for both
spellings. The equality assertions are not affected; the golden pins
the interpreter's bytes, which is what the gate runs on.
