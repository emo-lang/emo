# Step 73 — The column executor

**Milestone:** M36 · **Prereq:** step 72 (the column format) ·
**Status:** landed 2026-11-13

## Why this step exists

Step 72 gave column tables a format; the SQL surface still bridged them
with a named `0A000`. This step replaces the bridge with the executor:
a SELECT on a column table reads blocks as batches, filters and
projects through the shared typed expressions, and answers the global
aggregates — the first aggregates anywhere in the engine.

## Decisions settled here

- **The select list is all plain items or all aggregate calls.** A
  mixture is PostgreSQL's grouping error (`42803`, the column named in
  the message), because there is no GROUP BY in v0 — for either engine.
  An aggregate nested inside a larger expression falls to the row
  path's function refusal (`0A000`); the supported shape is the call as
  the whole select item.
- **COUNT, SUM, AVG, MIN, MAX; global only.** `count(*)` and
  `count(expr)` answer `bigint`; `sum` answers `bigint` over
  integer/bigint and `double` over real/double; `avg` answers `double`;
  `min`/`max` answer the argument's type (every v0 type compares). A
  sum, avg, min, or max over zero rows answers NULL, PostgreSQL's rule;
  count answers 0. `DISTINCT` aggregates refuse `0A000`. Aggregates are
  a column-table feature in v0 — the row engine's function refusal
  stands until the shared breadth lands them for both engines.
- **The block is the batch unit.** The record layer gained
  `scan_column_batches` (one entry per block: the block id and the
  per-column value arrays) and `column_block_counts` (row counts
  without decoding values). The executor decodes each block once per
  column, then evaluates the shared per-row expressions over the
  materialized values; the batch expression evaluator is the named
  follow-up. `count(*)` with no WHERE takes the fast path and sums the
  block counts without touching values at all.
- **Column names for aggregates.** The alias wins; without one the
  result column is the function's own name (`count`, `sum`), the way
  PostgreSQL names an unaliased aggregate. The plan text lists the
  calls: `aggregate count(*), sum(id)` over `column scan <table>`.
- **Insert-only stands.** UPDATE and DELETE on a column table answer
  `0A000: column-store tables are insert-only in v0`; INSERT routes to
  the column blocks through the same transaction. The plan text keeps
  the row path's insert form (`insert <table> (n rows)`).

## Tasks

- [x] **T73.1** — This file and the Step 73 section EN+zh.
- [x] **T73.2** — `record`: `scan_column_batches` and
      `column_block_counts`; `scan_column_tx` rebuilt on the batches.
- [x] **T73.3** — `engine`: the routing (SELECT branches to the column
      executor, INSERT to the column blocks), the insert-only refusals,
      the column plan nodes, and the aggregate machinery.
- [x] **T73.4** — The engine demo's column section grows into the
      executor's cases (scan, filter, the five aggregates, the mixing
      and type errors, the insert-only refusals, the reopen).
- [x] **T73.5** — The gate green three times.
- [x] **T73.6** — The docs EN+zh and the close-out.

## Evidence

- `projects/emo-db/check.sh` green three times with 66 checks (the
  engine demo's column section rewritten to the executor's cases).
- `engine_demo/expected.txt`'s column section: `INSERT 0 3` into the
  column table, the projection (`SELECT *`, three rows with the NULL
  score), the filtered projection (`WHERE id < 3` over the blocks),
  `count(*)` (3), the five aggregates over NULLs
  (`(3, 6, 2.0, 1, linus)` — sum 6 as bigint, avg 2.0 skipping the
  NULL, min 1, max `linus`), the filtered count (2), the mixing error
  (`42803` naming `id`), the type error (`42883: function sum(text)
  does not exist`), the two insert-only refusals, the primary-key
  refusal, and the reopen counting the column table.
- The plan texts: `column scan cold`, `filter id < 3` / `column scan
  cold`, and `aggregate count(*), sum(id), avg(score), min(id),
  max(name)` / `column scan cold`.
- `dune build`/`@fmt` green.

## Found on the way

- **`is()` narrowing follows bound locals only.** `items[i].value`
  inside `items[i].is(sql.SelExpr)` refuses; the classifier and the
  aggregate resolver bind the item first. The downcast-shaped helper
  (reading `value` after a negated `is` check) is not a form either —
  the resolver checks positively and passes the alias out of the
  narrowed branch.
- **A variable is typed by its initializer.** `var arg =
  TLit.new(...)` then `arg = typed` refuses, so the Aggregate is
  constructed inside the case that owns the typed argument.
- **`sql.Column`'s field is `parts`.** The mixing error spells the
  plain column from `parts[0]`, the same shape the `42703` message
  uses.
- **Zero-row aggregates answer NULL but count answers 0**, which the
  demo could not show without an empty column table — pinned by the
  decision and waiting for the corpus's column cases in step 74.
