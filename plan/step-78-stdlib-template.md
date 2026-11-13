# Step 78 — The standard library: `template`

**Milestone:** M39 — Text templates · **Prereq:** step 31 (json — the
value tree the context rides and the error split) and step 47 (csv —
the byte-scanner discipline and the all-five-golden shape) ·
**Related:** `stdlib/registry/{json,dom,httpd}` (the sibling surfaces
and the consumer), `docs/stdlib/template.md` · **Status:** done on
every target — both goldens ride all five lists: bootstrap,
typescript, c, wasm, and beam.

## Why this step exists

Server-rendered pages (`httpd`), emails, reports, and generated config
all want the same thing: text with holes, filled from data. EmoUI
rejected a template language for *UI composition* — the UI is plain
Emo — but text templating is a different genre, the one the raw-strings
settle named as its revisit trigger ("Revisit only if regex or text
templating lands, and then with a form of Emo's own"). The engine is a
library, not language surface: a template's expressions are data paths
over the `json` value tree, never Emo code, so the checker never sees
them and nothing evals at runtime — the macros settle rejected runtime
`eval` permanently, and this engine has none.

## Goal

`require "template"` renders a template with a `json` context,
byte-identically on all five hosted targets. `template.render(text,
ctx)` is the one-shot door; `template.new().with(name, text)` builds a
`Set` of named templates (partials, include targets) that renders by
name. Parsing is strict: every malformed action — an unclosed `{{`, a
stray `}}`, an unmatched `{{ end }}`, an unknown filter, a bad path —
answers `(R.error, reason)` with the byte position, never a repaired
tree. Rendering is strict too: a missing key, a wrong kind, an
out-of-bounds index, a null hole, a container hole — all answer
`(R.error, reason)` naming the path, the byte, and the fact. No silent
empty text, no `<no value>`, no zero-value fallthrough.

## Decisions settled here

- **The mechanism is Go text/template's, the surface is Emo's own.**
  Actions `{{ ... }}`, `{{ if }}` / `{{ else if }}` / `{{ else }}` /
  `{{ end }}`, `{{ for x in e }}` (with `{{ else }}`), `{{ template
  "name" [pipeline] }}` includes, trim markers `{{- ` / ` -}}`
  (the Liquid/Go shape), and comments `{{! ... }}`. No Go dot: paths
  are bare dotted paths (`user.name`, `users[0].name`, `m["a b"]`),
  and `for` bindings are author-named.
- **The context is the `json` tree.** `render(text, ctx Json)` — a
  decoded document renders directly, and the number rendering is the
  `float` package's exact-decimal text json already uses, so floats are
  byte-identical by construction. No second value-tree type.
- **Resolution: nearest binding, then root; nothing else.** A path's
  first segment resolves to the nearest enclosing `for` binding with
  that name, else the context root's key; deeper segments walk data
  (objects by key, arrays by index). No parent walking, no scope chain
  through data, no root escape — a binding shadows the root's
  same-named key, and the author names bindings to avoid the collision.
- **Truthiness is "not the zero value"** (Go's rule): `jnull`,
  `jfalse`, `jint` 0, `jfloat` 0.0, `""`, an empty array, an empty
  object are false. `for`'s `{{ else }}` is emptiness, not truthiness.
- **Value rendering refuses what has no text.** `jstring` verbatim,
  `jint` decimal, `jfloat` exact-decimal, `jbool` `true`/`false`; a
  null hole refuses (guard it with `{{ if }}` or supply
  `| default(...)`); an array or object hole refuses (iterate it with
  `for`, or `| length` / `| join`).
- **Filters are a fixed, ASCII-safe table:** `upper` / `lower`
  (ASCII — the language's own `String.lower` is ASCII; a Unicode case
  mapper needs cross-target-identical tables and waits), `trim`,
  `length`, `join(sep)`, `default(v)` (only `jnull` falls through — an
  empty string is a value, not an absence), `escape_html` (the five
  entities `&amp; &lt; &gt; &quot; &#39;`). No custom filter tables
  (FuncMap) in v1 — compute in Emo and put the result in the context.
  No arithmetic, no comparisons — **the template renders, the program
  computes**; filter arguments are paths or String/Int64/Bool literals.
- **Templates live in strings, parsed into a `Set`.** `template.new()`
  answers an empty set; `set.with(name, text)` parses and answers
  `(R, Set)` (the builder-copy shape; redefining a name refuses);
  `set.render(name, ctx)` renders by name. `{{ template "name" }}`
  passes the calling template's root context; `{{ template "name"
  pipeline }}` passes the pipeline's value — the dot semantics minus
  the dot. Bindings do not cross the include edge; the include depth is
  capped at 64 with the chain named.

## Deliberately out (v1)

HTML mode and contextual auto-escaping (the later arc — `escape_html`
exists for explicit use, and the `dom` package is the likely foundation),
custom filter tables, `with` / `block` / inheritance / macros,
arithmetic and comparisons, variables and assignments, date formatting
(the language has no clock — the slog stance), Unicode case mapping,
negative float literals in filter arguments, and Go's `{{/* */}}`
comment form (comments are `{{! ... }}`, ending at the first `}}`).
Amended while landing: a bare `}}` outside an action is **text, not an
error** — the plan draft named it a refusal, but code-generation
templates close nested braces in their static text, and Go's own
scanner agrees; only the action grammar is strict about delimiters.

## Tasks

- [x] **T78.1** — The package: `stdlib/registry/template/0.1.0` —
      manifest (`targets` all five, `deps { "json", "float" }`),
      `template.emo` (the root: `render`, `new`, the `Set` with
      `with`/`render`, the value-rendering rules), `internal/engine.emo`
      (the AST, the byte scanner, the parser — loop-based over the
      cursor, recursion bounded by the 512 nesting cap; the renderer:
      scopes, resolution, the filter table, includes with the depth
      cap).
- [x] **T78.2** — The goldens: `examples/template_demo` (the whole
      walk: one-shot, the set with partials, if chains, for over arrays
      and objects, for-else, every filter, trim markers, comments,
      bracket paths, includes with and without a pipeline) and
      `examples/template_edge` (the refusal matrix: every parse error
      shape, every render error shape, the include cap) — both on all
      five golden lists (bootstrap, typescript, c, wasm, beam).
- [x] **T78.3** — The docs: `docs/stdlib/template.md` + zh-CN mirror
      (using, the grammar, resolution, filters, errors, boundaries),
      `docs/stdlib.md` row + section + zh mirror, README's references
      line.
- [x] **T78.4** — The tracking: `plan/step-78-stdlib-template.md` (this
      file), `plan/README.md`'s milestone bullet and status row,
      `docs/TASKS.md`'s M39 section + zh mirror, CHECK.md's settle
      record.

## Found and fixed here

Two compiler bugs the goldens flushed, each pinned to a shape no
shipped example had walked before:

- **The IR's module-level def mangle skipped `sanitize_ident`.** Class
  methods and `emo` group members were registered through the
  sanitizer (`?` → `_q`), but module-level defs went into the symbol
  table raw — so the package's `filter_exists?` lowered to a name with
  a raw `?`: TypeScript rejected the module (`filter_exists?` is an
  illegal identifier) and the OCaml emitter would have spelled an
  illegal OCaml ident. Both `Item_def` sites (pass-1 registration and
  pass-2 lowering) and both `Item_emo_group` def sites now sanitize.
  No shipped def name carries a `?`, so no existing mangled name
  changed — zero fallout.
- **The BEAM emitter registered a case branch's pattern bindings
  before the per-branch scope save.** `emit_pattern`'s
  `Pattern_binding` arm calls `fresh_var`, which registers the name in
  `env.local_map`; in the threaded-chain case paths the branch save
  rode *after* the pattern, so a sibling arm's pattern variables
  leaked into the enclosing scope — a later `if`-with-rest
  continuation's live set swept them in, and the continuation call
  from another arm referenced an unbound variable (`erlc: unbound
  variable '_why255' in '__cont_203'/12`). The `stmt` case path
  already saved before the pattern; `emit_threaded_control`'s case now
  matches it. Verified against the full suite.
