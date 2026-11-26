# Step 94 — emosh's control flow

**Milestone:** M53 · **Prereq:** steps 92–93 (the everyday surface,
the background jobs) · **Status:** landed 2026-11-22 (code, fixtures,
docs; eleven fixtures byte-identical on both targets, the multi-line
block driven through a pty by hand on both)

## Why this step exists

The honest limits said "no control flow" since v0 — a shell that
cannot branch or loop cannot hold a script together. The user's
direction set the shape: the control flow speaks **Emo**, not bash —
brace blocks instead of `then`/`fi`/`do`/`done`, Emo's numeric for as
the only for, `def name() { }` with the parentheses required, and the
declaration keywords `const`/`var` joining the shell as first-class
bindings. This step lands that grammar across the parser, the AST,
and the executor, with the multi-line reading the blocks demand.

## Decisions settled here (the trail)

- **Brace blocks, no terminators.** `{` and `}` are reserved as
  standalone words: they end commands, they end lists, and a literal
  brace quotes. A condition or body list simply stops at the brace —
  no `then`, no `done`, and the newline a multi-line body carries
  rides as a `;` between the joined lines' tokens (without it the
  body's last command swallowed the closing brace — found by the
  first smoke).
- **`for` is the numeric form, the only form.** `for var i = 0;
  i < n; i = i + 1 { … }` — the header's three expressions kept as
  token slices and evaluated at runtime by a recursive-descent
  reader: bare variables, `$#`, integer literals, `+ - * / %`, the
  six comparisons (lowest precedence), parentheses, everything
  demanding spaces (`i+1` is one word and refuses). The condition
  must compare; the step must be the assignment `name = expr`.
  Division by zero refuses; the loop variable is a declared binding
  snapshotted before and restored after, whatever way the loop
  leaves.
- **`def name() { }` — parentheses required,** attached (`greet()`)
  or spaced (`greet ()`), the body a brace list bound at run time
  into the session's function table. A call is a bare name where a
  command may stand: the call's arguments become `$1..`/`$#`/`$@`
  and the caller's positionals come back on return. Functions run
  their bodies in place — declarations and definitions inside are
  the session's own (no locals, the POSIX answer) — and take no
  redirections.
- **`const`/`var` — the declaration keywords join the shell.**
  `const NAME = WORD` binds and freezes (any redeclaration and
  `unset` refuse: `NAME: is a constant`); `var NAME = WORD` binds
  replaceably. The value is one word — quote a phrase — expanded but
  never globbed; the declaration wants the spaces that make it read
  like Emo (`const x="y"` refuses). `$name` reads a declared binding
  before the environment.
- **Incomplete is a third answer, not an error.** A line ending
  inside a block makes every parse helper answer "incomplete" (the
  payload a sentinel); the driver reads the next line, a `;` token
  riding between the two lines' tokens as the newline-as-separator,
  and re-parses the whole thing from scratch. Empty statements —
  `;;` and that separator landing beside a closer — are silence.
- **break/continue/return ride a session signal.** One box: 1 break,
  2 continue, 3 return. The loop walkers consume break and continue,
  the call consumes return, `run_items` stops a list the moment a
  signal stands — **a signal outranks the connector** (`return 3`
  must stop the rest of its list, the first cut let `;` revive the
  walk) — and the top level refuses a leftover
  (`break: only in a loop`, `return: only in a function`).
- **Compounds take `&`.** A fork child walks the whole compound, the
  parent parks the job with the whole line as its text. Compounds do
  not enter pipelines; a function call takes no redirections.
- **if/while conditions are command lists** — the shell's own nature
  (`while grep -q x f { … }`) — with numeric comparisons living only
  in the for header. `else if` chains flatten into nesting at parse
  time; `elif` stays out.

## The shape

- `parse.emo` — `Compound`/`Decl` classes, `Item` three-way
  (pipeline/compound/decl), the keyword dispatch
  (`parse_if`/`while`/`for`/`def`/`decl`), the item-list walker with
  the closer and the brace-quiet rule, `incomplete` as the third
  answer.
- `exec.emo` — `drive_line` (lex → parse → re-read on incomplete →
  run), `run_compound`, `run_for`, the evaluator family
  (`eval_expr`/`cmp`/`add`/`mul`/`factor`/`cond`/`assign`),
  `bind_decl`, `call_function`, the signal-outranks-connector rule in
  `run_items`.
- `shell.emo` — `Var`/`FuncEntry` classes, the binding table, the
  function table, the positional stack, the signal box.
- `expand.emo` — the declared bindings consulted before the
  environment by `$name`.
- `builtin.emo` — `break`/`continue`/`return`, `unset` clearing
  declared bindings (consts refusing).
- `lex.emo` — `<=` `>=` `==` `!=` as two-character tokens (the
  comparisons the header reads; `==`/`!=` intercepted on the word
  path, quoting keeps a literal).

## Found on the way, fixed in step

- The joined lines needed their newline as a separator: without it
  the body's last command swallowed the closing brace (`echo tick $i }`
  ran with `}` an argument) — the `;` token rides between the lines.
- A signal must outrank the connector: the first cut's `;` set `run`
  back to true after `return 3` had stopped the list, so the body's
  remaining items ran.
- The incomplete answer was dropped at parse_item_list's own
  end-of-tokens check — the driver saw a complete (empty-tailed)
  line and ran it half-parsed.
- `2>&1`'s character order (`>` before `&`) — the dup classifier had
  the two swapped, refusing even `2>&2`; a substring probe pinned the
  order before the fix.
- `.emo-build`'s cache not keying on the compiler: three smokes ran
  against stale binaries — move it aside and rebuild, every time.
- `const NAME Array[UserClass] = []` — the local annotation grammar
  does not take bracketed types; the empty tables moved to def-return
  helpers (`empty_vars()`).

## The honest limits (the guide states them)

Compounds stay out of pipelines; `case`, `until`, `select`, `[[`,
arithmetic parentheses outside the for header; word-list iteration
waits for an indexing form; no `local` — declarations inside a body
are the session's; a declaration's value is one word; numeric
comparisons live only in the for header (a function testing its
arguments waits for a comparison shape in conditions).
