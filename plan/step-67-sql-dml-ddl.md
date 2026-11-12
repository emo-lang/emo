# Step 67 — The SQL front-end's DML and DDL

**Milestone:** M30 · **Prereq:** step 30 (`sql`'s SELECT surface and its
expression grammar) · **Status:** landed 2026-11-12

## Why this step exists

The record layer can store tables and rows; the executor (M31) needs a
front-end that can say what to create, insert, update, and delete. This
step grows the `sql` package's statement set beside `SELECT`: `CREATE
TABLE` with the v0 column types, multi-row `INSERT`, `UPDATE`, and
`DELETE` — AST classes, the parser, and the canonical `to_string()`
rendering for each. The package stays pure Emo and byte-identical on all
five hosted targets; the existing SELECT grammar does not move.

The step is structural only: the parser checks the statement's shape
(duplicate names, row widths, a positive VARCHAR length), never the
catalog or the value types. Table existence, column resolution, and type
matching are M31's.

## Decisions settled here (the trail)

- **One `Stmt` interface, one class per statement, one enum member.**
  `StmtKind` gains `create_table`, `insert`, `update`, and `delete`;
  `Select` and its nodes are untouched except for the new reserved
  words. Every statement answers `to_string()` in the package's existing
  canonical style — uppercase keywords, `ident_text` quoting, the
  expression renderer unchanged.
- **CREATE TABLE's v0 surface is the record layer's column model.**
  Types: `INTEGER`, `BIGINT`, `REAL`, `DOUBLE PRECISION`, `TEXT`,
  `VARCHAR(n)`, `BOOLEAN`, `BYTEA` — exact spellings, no aliases (`INT`,
  `BOOL`, `SERIAL`, … refuse). `VARCHAR` requires a positive `(n)`.
  Column constraints: `NOT NULL` and `PRIMARY KEY`, each at most once,
  in either order; the canonical rendering writes `NOT NULL` then
  `PRIMARY KEY`. Table-level constraints, `UNIQUE`, `DEFAULT`, `CHECK`,
  `REFERENCES`, and `IF NOT EXISTS` refuse with a reason naming what is
  unsupported — the executor must never silently ignore a constraint.
- **INSERT is VALUES-only, one or more rows.** `INSERT INTO t [(a, b)]
  VALUES (…), (…)`; every row has the same width, and equals the column
  list's length when one is present. `INSERT … SELECT`, `ON CONFLICT`,
  and `RETURNING` refuse. Duplicate names in the column list refuse.
- **UPDATE carries distinct assignments and an optional WHERE.**
  `UPDATE t SET a = expr, b = expr [WHERE expr]`; a repeated column
  refuses; `FROM` and `RETURNING` refuse.
- **DELETE carries an optional WHERE.** `DELETE FROM t [WHERE expr]`;
  `USING` and `RETURNING` refuse.
- **The new keywords join `is_reserved`.** `create`, `table`, `insert`,
  `into`, `values`, `update`, `set`, `delete`, `primary`, `key`, and the
  unsupported-constraint words are reserved, so a column named `set` or
  `primary` renders quoted. Type names stay non-reserved (a column named
  `text` is ordinary SQL).
- **One statement per parse stays true.** `SELECT 1; SELECT 2` still
  refuses at the second statement; the trailing-semicolon allowance is
  unchanged.

## Tasks

- [x] **T67.1** — This step file and the Step 67 section in
      `docs/TASKS.md` + zh, sized for spare sittings.
- [x] **T67.2** — The AST: the four `StmtKind` members, the `SqlType`
      enum, `ColumnDef` (name, type, VARCHAR length, NOT NULL, PRIMARY
      KEY), `CreateTable`/`Insert`/`Update`/`Delete`, `Assignment`, and
      their canonical `to_string()` renderers plus the comma helpers.
- [x] **T67.3** — `is_reserved` gains the statement/constraint words;
      `want_kw`, `parse_ident_name`, and `parse_target_name` join the
      token helpers.
- [x] **T67.4** — `parse_create_table`: the name path, the column list,
      the type parser (including `DOUBLE PRECISION` and `VARCHAR(n)`),
      the NOT NULL/PRIMARY KEY constraints, duplicate-column checks, and
      the unsupported-constraint refusals.
- [x] **T67.5** — `parse_insert`: `INTO`, the optional column list, the
      VALUES rows, the row-width checks, the duplicate-column check, and
      the refusals for the unsupported tails.
- [x] **T67.6** — `parse_update`: the SET assignments, the duplicate
      check, the optional WHERE, and the trailing-token refusals.
- [x] **T67.7** — `parse_delete`: `FROM`, the optional WHERE, and the
      trailing-token refusals.
- [x] **T67.8** — `parse_stmt` dispatches the five statements and names
      the set in its error.
- [x] **T67.9** — `examples/sql_demo`: the DDL/DML parses, the canonical
      renderings, and the AST reads (columns, types, constraints, rows,
      assignments, WHERE); `expected.txt` regenerated.
- [x] **T67.10** — `examples/sql_edge`: the old INSERT refusal becomes a
      valid parse, so it is replaced; new malformed DDL/DML cases pin
      the error messages, and `expected.txt` is regenerated.
- [x] **T67.11** — The package header's supported/unsupported lists,
      `docs/stdlib/sql.md` + zh, and the `docs/stdlib.md` row if its
      wording moved.
- [x] **T67.12** — The close-out: the two `sql` locks re-resolved,
      `plan/README.md`, the M30 row, `CHECK.md`, `dune build`/`@fmt`,
      and the step's evidence.

## Evidence

- `examples/sql_demo` and `examples/sql_edge` are byte-identical on the
  interpreter, the `c` binary, the OCaml binary, the TypeScript output
  under Node, the wasm module under the canonical host, and the BEAM
  module under `erl` — six runs each, `cmp` against `expected.txt`.
- The new demo output: the CREATE TABLE rendering and its column reads
  (9 columns, the NOT NULL/PRIMARY flags, `DOUBLE PRECISION`,
  `VARCHAR(12)`), the normalized `create table` rendering, the two
  INSERT renderings and the row reads, the UPDATE rendering and its
  assignment/WHERE reads, and both DELETE forms.
- The edge output: the old `INSERT INTO t VALUES (1)` refusal is gone
  (the statement is valid now); 27 new malformed DDL/DML cases pin the
  messages and byte offsets, and the existing SELECT/number/nesting
  cases are unchanged.
- Both examples' locks were re-resolved for the new `sql` digest; the
  package's own check wrote a lock into the stdlib tree, which is not
  the stdlib convention and was moved out of the tree.
- `dune build`/`@fmt` green; the full `dune runtest` waits for the next
  requested run, per the auto-test rule.

## Found on the way

- **The BEAM emitter could not lower the new INSERT parser's mutable
  locals.** The first draft assigned `var` locals inside nested `case`
  branches (`parse_insert`'s `k`/`columns`, the constraint and WHERE
  loops); `erlc` answered "unbound variable '_why1066'" in
  `sql__parse_insert/2`. The SELECT parser's shape — recursion with the
  state as parameters — is the one every target lowers; the new
  parsers were refactored to it (`parse_insert_after_name`/
  `parse_insert_values`, `parse_column_constraints`,
  `parse_update_where`/`update_tail`,
  `parse_delete_where`/`delete_tail`), and the BEAM build went green
  with the output unchanged. Recorded here so the next parser draft
  starts from recursion.
- **The old `sql_edge` pinned INSERT as malformed.** `INSERT INTO t
  VALUES (1)` was a refusal case; M30 makes it valid, so the case is
  replaced with malformed DDL/DML inputs and the golden regenerated.
- **The package check writes a `package.lock` into the stdlib tree.**
  No stdlib registry package carries one; the file was moved out after
  the check (the examples' locks are the locks that matter).

## Open, deliberately

- **INSERT … SELECT** — the executor's projection and the plan node are
  M31's.
- **ON CONFLICT / RETURNING** — conflict semantics and a returning
  projection wait for the executor and the wire.
- **Table-level PRIMARY KEY/UNIQUE and CREATE INDEX** — the index
  machinery exists in the record layer; the SQL surface waits for the
  planner's index selection (M31).
- **DEFAULT/CHECK/REFERENCES** — constraints with runtime semantics are
  not v0; the parser refuses them by name.
- **Type aliases and length-less VARCHAR** — the canonical v0 spelling
  only; aliases wait for a dialect decision.
