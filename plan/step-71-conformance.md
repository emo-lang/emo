# Step 71 — Conformance and documentation

**Milestone:** M34 · **Prereq:** steps 65–70 (the whole row-store arc) ·
**Status:** landed 2026-11-13

## Why this step exists

Every milestone so far pinned one behavior with one golden. The arc
closes with the record: a corpus that states the shipped surface as
data (what succeeds with which tag, what returns which rows, what fails
with which SQLSTATE and message), a measured table that separates
numbers from claims, and documentation that matches what was built.

## Decisions to settle here

- **The corpus is data, the runner is the only code.** One `.test` file
  per surface area — `ddl`, `types`, `dml`, `select`, `transactions`,
  `errors` — with `statement ok`, `statement error`, and `query`
  records separated by blank lines. A record's SQL is the lines after
  the header up to `----` (or a blank line); `----` starts the
  expectation: one command tag for `statement ok`, one
  `code: message` line for `statement error`, and the rows for
  `query`. A `query` row renders the engine's values canonically —
  `|`-separated, NULL as `NULL`, booleans `true`/`false`, BYTEA
  `0x`-hex — so the corpus stays readable and text-comparable without
  the wire.
- **One database, one run.** The runner destroys and reopens one store
  per invocation and executes every file in argument order; cases share
  tables deliberately (the DDL file creates them, the later files use
  them), and transaction cases leave the database state they promise.
  The corpus is not a unit-test framework: it is the SQL surface's own
  regression data.
- **Failures are collected, not fatal.** The runner prints one line per
  file (`ddl.test 10 cases`) and a total (`cases 57, failed 0`); a
  mismatch prints `FAIL file:line: detail`, the run continues, and a
  nonzero total raises at the end. The gate compares the success
  transcript byte-for-byte and runs it three times.
- **Measured numbers are recorded where the script measured them.**
  `bench/bench.emo` runs one named workload per mode (autocommit
  inserts, a transactional batch insert, primary-key lookups, a full
  scan, autocommit updates), printing only counts; `bench/run.sh`
  times the binary with Python's `perf_counter` — one warmup and three
  timed runs, the mean reported — and writes the table with the
  machine, date, sizes, and method. The gate builds the bench and
  checks its counts, never a time. Work the script did not measure
  (the wire's per-query latency, for example) stays out of the table.
- **The documentation pass corrects stale claims.** The design record's
  open items said joins/aggregates/ORDER BY "land with M34's
  conformance breadth"; M34 is the corpus and the record, so those
  items are restated as open (the corpus pins the refusals) and the
  arc-two sketch is reviewed against the actual row-store plan nodes,
  catalog, and storage layout.

## Tasks

- [x] **T71.1** — This file and the Step 71 section EN+zh.
- [x] **T71.2** — The corpus format and `corpus_runner`.
- [x] **T71.3** — The six corpus files and their pinned expectations.
- [x] **T71.4** — The gate's three-run corpus golden.
- [x] **T71.5** — The bench modes and `bench/run.sh`, and the recorded
      measurement.
- [x] **T71.6** — The gate's bench smoke.
- [x] **T71.7** — The design record + zh.
- [x] **T71.8** — The project READMEs EN+zh.
- [x] **T71.9** — The close-out.

## Evidence

- `projects/emo-db/check.sh` green three times with 59 checks: the four
  package checks, four embedded demos three runs each, the corpus
  runner plus three byte-identical corpus runs, the bench build and
  smoke, the wire's two phases, and the two refusals.
- `corpus/expected.txt`: `ddl.test 6 cases`, `types.test 13`,
  `dml.test 24`, `select.test 36`, `transactions.test 27`,
  `errors.test 20`, `cases 126, failed 0`.
- `bench/results.md` (2026-11-13, Darwin arm64, c target): INSERT
  autocommit 1160 ms / 172 per second over 200 rows; INSERT one
  transaction 6680 ms / 1497 per second over 10000 rows; primary-key
  lookup 1037 ms / 9643 per second over 10000; full scan 580 ms for
  10000 rows; UPDATE autocommit 1305 ms / 153 per second over 200.
- `docs/emo-db.md` + zh carry the `What shipped` and `Measured`
  sections, the corrected open items, and the arc-two review;
  `benchmarks/run.sh`'s method is the bench's own.
- `dune build`/`@fmt` green.

## Found on the way

- **Read-only statements paid a COMMIT's fsync.** Every autocommit
  statement opened a transaction whose commit called `write_sync`; a
  primary-key SELECT cost 5.6 ms, almost all of it the WAL. The
  record layer's `Txn.commit` now closes without a batch write when
  the pending overlay is empty (a read-only statement, or an explicit
  empty transaction), and the lookup drops to 0.1 ms. The bench's
  autocommit rows state the real cost of durability from then on.
- **The DDL-in-transaction refusal left the block open.** The corpus's
  transaction file expected `COMMIT` after the `0A000` refusal to
  answer `25P01`; the engine's dispatch returned before the error
  path. The refusal now aborts the transaction and releases its
  locks, like every other failed statement.
- **A REAL column cannot take a float literal.** The literal is double
  precision and the engine refuses narrowing by design; the corpus
  pins the `42804` and uses an integer literal (`1` → `1.0`) as the
  REAL column's value form in v0. An open item to revisit with the
  narrowing decision.
- **Parse-error byte offsets are part of the surface.** The corpus
  pins them exactly (`unterminated literal at byte 7`,
  `duplicate assignment to column "id" at byte 17`,
  `expected a table name at byte 13`), which the earlier examples
  printed but never asserted.
- **`scan` renders one row per 0.058 ms** — the materialized row path
  (decode, Value allocation, canonical rendering by the corpus) is
  the number the batch/vectorized work of arc two would improve.
