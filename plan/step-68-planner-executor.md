# Step 68 — The planner and executor

**Milestone:** M31 · **Prereq:** steps 66 (the record layer) and 67 (the
SQL AST's DML/DDL) · **Status:** landed 2026-11-12

## Why this step exists

The record layer stores rows; the `sql` package parses statements. This
step is the first full SQL-to-rows path: a planner that resolves names
and types, chooses a table scan or a secondary-index scan, and an
executor that walks the plan — INSERT building encoded rows, UPDATE and
DELETE locating rows, SELECT filtering and projecting. There is no wire
yet: the acceptance is an embedded test face that pins SQL text in and
rows out on the `c` target.

## The v0 surface (deliberately narrow)

- **SELECT**: one table, `*` / `t.*` / expressions, an optional WHERE.
  `DISTINCT`, joins, subqueries in FROM, `GROUP BY`/`HAVING`,
  `ORDER BY`, `LIMIT`/`OFFSET`, aggregates, functions, `CAST`, and
  parameters refuse with `0A000` (feature not supported) — the parser
  still parses them, the executor says no.
- **Expressions**: literals, column references (qualified by the table
  name or alias), parentheses, unary +/-, NOT, comparisons, AND/OR,
  arithmetic on numbers, `||` on text, `IS [NOT] NULL/TRUE/FALSE`,
  `[NOT] IN`, `[NOT] BETWEEN`, `[NOT] LIKE` (`%`/`_`, byte-oriented in
  v0), and `CASE` (simple and searched). NULL follows SQL's
  three-valued logic; WHERE keeps a row only when the predicate is
  non-null true.
- **CREATE TABLE**: the `sql` package's v0 types and column-level
  constraints map onto the record layer; a primary-key column becomes
  one unique index named `<table>_pkey`. More than one primary column
  refuses (42P16); schema-qualified names refuse (0A000).
- **INSERT**: an optional column list; omitted columns are NULL (a NOT
  NULL omission is 23502); values are constants, widened to the
  column's type; each row is one record-layer insert (multi-row
  statement atomicity is not v0).
- **UPDATE**: distinct assignments evaluated against the old row,
  an optional WHERE, rows located by the planner's scan; the record
  layer replaces the row and rewrites its index entries in one batch.
- **DELETE**: an optional WHERE; the record layer removes the row and
  its index entries in one batch.
- **Errors** are a `SqlError { code, message }` value: the PG-shaped
  codes and messages the wire will map in M33 (`42P01` missing relation,
  `42703` missing column, `42883` operator mismatch, `42804` assignment/
  WHERE type mismatch, `23505` duplicate key, `23502` not-null, `22003`
  range, `22012` division by zero, `42601` syntax, `0A000` unsupported,
  `42P16` invalid table definition).
- **The plan nodes**: `Scan` (table or index), `Filter`, `Project`,
  `Insert`, `Update`, `Delete`. Each renders a short text tree that the
  test face prints (`project ... / filter ... / index scan ...`), so
  the golden proves the access path.

## Tasks

- [x] **T68.1** — This file, the TASKS Step 68 section EN+zh, and the
      plan README row.
- [x] **T68.2** — The record layer's `Table.update`/`Table.delete`:
      read the old row, remove its index entries, write the new row and
      entries in one batch; unique checks excluding the row's own rowid;
      a missing delete is a no-op, a missing update an error value.
- [x] **T68.3** — `projects/emo-db/engine/` skeleton: the manifest, the
      `SqlError`/`Result` types, `Engine.open`/`close`.
- [x] **T68.4** — The analyzer: table/alias resolution, column lookup,
      the v0 type mapping, numeric/text conformance, and the PG-shaped
      error constructors.
- [x] **T68.5** — The typed expressions: literals, columns, unary,
      binary (comparisons/arithmetic/concat/AND/OR), three-valued logic,
      IS/IN/BETWEEN/LIKE/CASE, coercions, division/range errors.
- [x] **T68.6** — CREATE TABLE: the type/constraint mapping, the pkey
      index, the multiple-primary and schema-name refusals, the tag.
- [x] **T68.7** — INSERT: the target columns, NULL fill, constant
      evaluation, coercion, the not-null pre-check, the record insert,
      the 23505 mapping, the tag.
- [x] **T68.8** — SELECT: the single-table/unsupported-clause checks,
      the scan choice (equality on an indexed column becomes an index
      scan), the filter, the projection (star/aliases/names), the tag.
- [x] **T68.9** — UPDATE and DELETE: the assignment/where analysis, the
      scan, the old-row evaluation, the record calls, the counts.
- [x] **T68.10** — The plan text renderers and the result's plan field.
- [x] **T68.11** — `projects/emo-db/engine_demo`: the statement walk
      (DDL, insert, scans, filter, index scan, update, delete, the
      errors, the reopen), the value renderer, `expected.txt`.
- [x] **T68.12** — The gate: stage the engine, build the demo, run it
      three times, keep the record/KV goldens and the refusals green.
- [x] **T68.13** — The project README + zh, the package docs, and the
      locks.
- [x] **T68.14** — The close-out: TASKS, the plan README, CHECK.md,
      `dune build`/`@fmt`.

## Evidence

- `projects/emo-db/check.sh` green with three goldens: the binding, the
  record layer, and the engine type-check; the KV, record, and engine
  demos build and run three times byte-identical; the E3009/E5007 pins
  stay green (28 checks).
- The engine demo's 61-line output: CREATE TABLE, `INSERT 0 3`, the
  full table scan (projection over all five columns), the filtered
  scan (`active = TRUE`, two rows), the equality index scan on
  `users_pkey`, the UPDATE and its index scan, the SELECT confirming
  `99.0`, the DELETE and its index scan, the two-row rescan, the ten
  error runs over nine codes (`42P01`, `42703`, `42883` `bigint + text`, `42804` for
  the assignment, `0A000` for DISTINCT and CAST, `22012`, `23505` with
  `users_pkey`, `23502`, `22001`), and the close/reopen scan.
- The record layer's new `Table.update`/`delete` are exercised by the
  engine demo (the UPDATE and DELETE rows) with the index entries
  rewritten in the same batch.
- `dune build`/`@fmt` green; the full `dune runtest` waits for the next
  requested run, per the auto-test rule.

## Found on the way

- **The error-handling convention types the reason as a String.** The
  first draft gave the engine an `SqlError { code, message }` class; the
  checker's `(R, T)` rule (`r_error_pair_conforms`) only lets a literal
  `(R.error, reason)` pair conform, and a caller's `(R.error, e)`
  pattern reads `e` as a String. The engine's failures are now Strings
  shaped `code: message` (the wire will split them in M33), and the
  `SqlError` class is gone.
- **`is()` narrowing follows a bound local, not a field or index
  expression.** `stmt.from_t[0].is(sql.TblNamed)` then `const ref =
  stmt.from_t[0]; ref.parts` refused (`sql.TableRef has no field
  parts`); the fix binds the local first and checks that local
  (`from_parts(ref)`), and the same shape fixed `expr.left.is(...)`
  (bind `left`/`right`) and `item.value.is(sql.Column)` (bind
  `value_expr`). Narrowing through `&&` also does not reach the body;
  the two conditions are nested `if`s now.
- **`def` is reserved** — `var def = record.column(...)` in
  CREATE TABLE is a parse error; the local is `cdef`.
- **The demo's CREATE wrote `DOUBLE` without `PRECISION`**; the SQL
  parser correctly refused, which made every later statement answer
  `42P01` and the first engine run a useful smoke of the error path.
- **The record layer's `Table.update`/`delete` were missing**; M31 adds
  them (old-row read, index-entry removal, the new row/entries in one
  batch, update's unique check excluding the row's own rowid, a missing
  delete as a no-op).
