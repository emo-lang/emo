# Step 03 — Parser: Expressions

**Milestone:** M1 · **Prereq:** step 02 · **Status:** done

## Goal

The AST (in `emo_ast`) and a recursive-descent expression/statement parser
covering everything except declaration forms (step 04). After this step,
every runtime-level construct in the README parses.

## Scope

### In

- **AST** for expressions and statements: literals, interpolated strings
  (list of literal / expression parts), `self`, identifiers, member access
  `x.y`, indexing `a[i]`, calls, arrow blocks, `if` / `else`, `return`, and
  expression statements.
- **Precedence** (loosest → tightest):
  `||` < `&&` < comparisons (`== != < <= > >=`, non-associative) <
  additive (`+ -`) < multiplicative (`* / %`) < unary (`!`, unary `-`) <
  postfix (call, member, index, repeated freely).
- **Calls** — explicit parentheses, positional and named arguments mixed
  (`hello(name: "world")`, `f(a, b, k: c)`). Trailing block sugar:
  `page(title: "Home") { ... }` desugars to passing one final arrow-block
  argument — the component-tree and structured-literal shape from the README
  falls out with no extra machinery (provisional decision: the block is the
  last positional argument).
- **Arrow blocks** — `-> (x Int) { ... }` with annotated parameters (multiple
  allowed) and the parameterless `-> { ... }`. Body is always a `{ }` block.
- **`if` statements** — exactly one shape: `if cond { ... }` with an
  optional `else { ... }`. There is no `else if`, `elif`, or any chaining
  sugar — a further test is an `if` visibly nested inside the `else`
  block. `if` is a statement, not an expression; branches communicate
  through explicit `return` or binding (no implicit last-expression
  value). `else` must stay on the closing brace's line (`} else {`) — an
  `else` at the start of a line is a syntax error under the
  newline-termination rules.
- **`do` expressions** — `do <call>` starts a process running the call
  (README, Concurrency) and evaluates to the new process's pid, so
  `const pid = do fetch(page)` binds the process reference. The operand
  must be a call expression — `do task(x)` or an immediately invoked block
  `do -> { ... }()` — anything else is a parse error. The syntax lands
  here; evaluation semantics land in step 11, and until then the evaluator
  reports a clear not-yet error.
- **Send statements** — `pid <- message` delivers a message to a process's
  mailbox; the space-delimited `<-` is send (step 02 rejects every
  juxtaposed form with an error), never assignment. Messages are ordinary
  values. Syntax lands here; semantics in step 11 (not-yet error until
  then).
- **`case` statements** — `case expr { pattern -> { ... } ... }`: branches
  are tested top to bottom and the first match's block runs. `case` is a
  statement — results leave through explicit `return` or binding. Patterns
  (first-edition scope): enum members by **qualified name only**
  (`Color.red`; a bare lowercase name is a binding pattern — members and
  variables share the lowercase space, so qualification is what keeps them
  apart), literals matching by value, a binding name, and `_`. Guards:
  `pattern when cond`. Exhaustiveness is the checker's job (step 08). The
  branch `->` never collides with arrow blocks: patterns are not
  expressions, so the two `->`s occur in disjoint parser states (Elixir
  precedent). Tuple patterns destructure by position (see Tuples below).
- **`receive` statements** — `receive { ... }` with the same branch shape
  as `case`: on evaluation it takes the first mailbox message matching any
  branch, and non-matching messages stay queued (selective receive for
  free — no separate mechanism). Syntax lands here; semantics in step 11
  (not-yet error until then).
- **Tuples** — literals are `(a, b, c)`, resolved by content, with no
  trailing-comma forms anywhere:
  - commas → tuple literal: `()`, `(a, b)`, `(a, b + c)`;
  - a single operator-free value — literal, name, call, member access,
    index, or arrow block → one-element tuple: `(a)`, `(user.name)`;
    grouping a lone value is meaningless, so the form is not a group;
  - an expression containing operators → grouping: `(sum * 3)`,
    `x && (y || z)`, `(-x)`.
  `(a,)` is a syntax error — the error message points at `(a)` as the
  one-element form. One lexical law covers every paren-nesting shape:
  **a `(` token immediately followed by another `(` token is a syntax
  error** — `((x))`, `f((a, b))`, `f((a, b), c)`, `f((a + b))` never
  parse. An inline tuple argument, or a nested tuple in first position,
  is bound to a name first: `const point = (x, y)`, then
  `move_to(point)`. Nesting after a comma is legal — the separator
  keeps it unambiguous: `(a, (b, c))`, `(a, (b + c))`. The boundary
  against calls is spacing, mirroring the `<-` rule: call parentheses
  must touch the callee — `f(a)` is a call, and `f (a)` on one line is
  an error (juxtaposed expressions are never implicitly a call). The
  annotation form mirrors the literal — `(Int, String)`. In **pattern**
  position, parentheses are always tuple patterns (patterns have no
  precedence to override): `(Color.red, count) -> { ... }`, with element
  count checked against the pattern; the `((` law applies to patterns
  too, so nested patterns always sit after a comma. `-> (x Int)`
  parameter lists sit in their own parser state.
- **Statement termination** — provisional rule: a newline ends a statement
  unless (a) the line's last token is a binary operator, comma, or an
  unclosed `(`/`[`/`{` (tracked by depth), and (b) inside any brackets. When
  a statement boundary is ambiguous, it is an error, not a guess.
- **Qualified module paths** are plain member access: `shop.order.total(cart)`
  parses as member/call. No import syntax exists and none is added — modules
  arrive in step 09 by making namespaces values.
- Statement-level `const` / `var` bindings parse here (declaration
  initializers are expressions); top-level and class-body declarations are
  step 04.

### Out

- `def` / `class` / `interface` / `enum` / `raise` (step 04).
- Pattern matching, destructuring — undecided (`CHECK.md`).
- Error recovery beyond a basic sync point (polished multi-error recovery is
  step 07's diagnostics work; here: recover to the next newline and continue).

## Tasks

- [x] `emo_ast` expression/statement types with spans on every node.
- [x] Pratt-style expression parser with the precedence table above.
- [x] Call parsing: positional + named args, trailing-block sugar.
- [x] Arrow blocks; `if` / `else` (single shape, no chaining).
- [x] Newline-termination rules with depth tracking.
- [x] Interpolated-string reassembly from lexer parts.
- [x] Parser tests: precedence table, dangling-operator continuations,
      malformed input errors.

## Acceptance

- Every expression snippet appearing in the README parses to the expected
  AST (golden tests).
- Precedence golden tests pin `1 + 2 * 3`, `a && b || !c`,
  `x.foo(1)[i].bar?()`.
- `dune test` green.

## Open design items

- Trailing-block-as-last-positional-argument is a provisional decision; the
  alternative (dedicated block parameter) needs a keyword the README doesn't
  have, so this stays unless design says otherwise.
- Class patterns in `case` (`Ok(value:) -> { ... }`) are deliberately
  deferred: classes are an open set with no exhaustiveness and no union
  type for the scrutinee, so `is()` narrowing covers the need for now.
  Revisit through `CHECK.md` if real demand appears.
