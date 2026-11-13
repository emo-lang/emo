# Step 74 — The two-engine proof

**Milestone:** M37 · **Prereq:** steps 72–73 (the column format and the
column executor) · **Status:** in progress (2026-11-13)

## Why this step exists

Arc two's pieces exist; the product story needs its proof: one database
holding both storages, one session updating a row table and inserting
into a column table in one transaction, and the whole surface driven by
the same two clients arc one was proved with — psql and the standard
library's `postgres` client. This step also closes the arc's accounts:
the corpus gains the column surface, the bench gains the column rows,
and the docs record the numbers.

## Decisions settled here

- **The proof is a served database.** A new `htap_demo` seeds a row
  table (`items`, three rows) and a column table (`cold_items`, 1100
  rows — across the block boundary) through the engine, then serves the
  wire exactly as `wire_demo` does: an ephemeral port through a ready
  file, a finite connection count, static stdout. The gate runs the
  psql phase and the client phase against fresh servers, each pinned
  byte-for-byte.
- **The script crosses the engines inside one transaction.** BEGIN,
  an UPDATE on the row table, an INSERT into the column table, COMMIT —
  one WriteBatch, one fsync, both engines. The reads before and after
  pin the values: the seeded aggregates (count 1100 over two blocks,
  sum 605500, the lexicographic max `row-999`), the updated row price,
  and the post-commit aggregates (count 1101, sum 606601).
- **The corpus states the column surface as data.** A `column.test`
  file: the DDL, a 12-row insert, the projection and filtered
  projection, the five aggregates, the zero-row rule (`count` 0, the
  rest NULL over an empty filter), the mixing error, the type error,
  `DISTINCT` aggregates, the insert-only refusals, and the primary-key
  refusal. The block boundary itself stays pinned by `column_demo` (the
  record layer) and the served demo (1100 rows through the engine and
  the wire).
- **The bench measures both scans on the same machine.** New modes:
  `column-seed`, `column-scan` (a full block scan, the row-scan row's
  column-store twin), and `column-agg` (`count(*)`, `sum(id)`,
  `avg(score)` — one query). The gate smokes the modes' counts and
  never a time; `bench/results.md` records the measured numbers.

## Tasks

- [x] **T74.1** — This file and the Step 74 section EN+zh.
- [x] **T74.2** — `htap_demo` (the seeding server) and `htap_client`
      (the `postgres` client's script), with their goldens.
- [x] **T74.3** — The gate's two-engine phases behind the same
      `psql`/`libpq` probes.
- [x] **T74.4** — The corpus's `column.test` and the runner's file list.
- [x] **T74.5** — The bench's column modes, `run.sh`'s rows, the
      recorded numbers, and the gate's smoke.
- [x] **T74.6** — The docs EN+zh and the arc's close-out.

## Evidence

- `projects/emo-db/check.sh` green three times with 76 checks: the
  four package checks, five embedded demos three runs each, the corpus
  (now 141 cases) three byte-identical runs, the bench build and
  smoke, the wire's two phases, the two-engine's two phases, and the
  two refusals.
- `htap_demo/psql_expected.txt`: the seeded reads
  (`1|Ada|9.5`, `2|Grace|3.25`, `3|Linus|`,
  `1100|605550|1.0|row-999`), the cross-engine transaction
  (`BEGIN`, `UPDATE 1`, `INSERT 0 1`, `COMMIT`), and the post-commit
  reads (`1|11.0`, `1101|606651`).
- `htap_client/expected.txt`: the same script through libpq's simple
  path (`items: 3` with the NULL price as `-`, `cold: 1100 605550 1.0
  row-999`, `begin/update/insert/commit`, `row: 1 / 1 11.0`,
  `cold2: 1101 606651`, `done`).
- `corpus/expected.txt`: `column.test 15 cases`, `cases 141, failed 0`.
- `bench/results.md`: the column rows — the block scan 304 ms / 32895
  rows per second over 10000 rows, the aggregate 142 ms / 70423 —
  beside the row store's 675 ms / 14815.
- `dune build`/`@fmt` green.

## Found on the way

- **The standard client's typed reads raise on NULL.** The htap
  client's row reader checks `rows.is_null` before every `f64` — the
  `postgres` package's contract is that `is_null` tells NULL from ""
  and a typed read of "" raises, so the reader asks first.
- **The wire's own refusals guard the script.** The first draft named
  `min(price)` against a table whose column is `score`; the wire
  answered the honest `42703` before anything else could run.
- **The seed's arithmetic is part of the golden.** 1100 rows sum to
  605550 (`n(n+1)/2`), 1101 to 606651; the demo's `1100`-row seed
  crosses the block boundary on purpose, so every served aggregate
  walks two blocks.
- **The column seed's cost is setup, not a measurement.** Each insert
  rewrites the trailing block, so seeding 10000 rows through the
  engine is the slow half of `bench/run.sh`'s wall time; the timed
  modes are the scan and the aggregate.
