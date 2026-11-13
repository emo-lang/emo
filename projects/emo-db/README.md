# emo-db

emo-db is Emo's own client-server SQL database: one PostgreSQL-dialect
surface over two engines — a row store for OLTP first, a column store
for OLAP later. The design record is [`docs/emo-db.md`](../../docs/emo-db.md);
this directory is the project. Arc one is closed: M28 (the RocksDB
half), M29 (the record layer), M30 (the SQL front-end's DML/DDL), M31
(the planner and executor), M32 (transactions and the session plane),
M33 (the PostgreSQL wire), and M34 (conformance and documentation) are
landed. Arc two — the column engine — is under way: M35 (the column
format) is landed.

## Layout

- `rocksdb/` — the project-local `emo/rocksdb` binding: a package-carried
  C shim over RocksDB's official C API, `targets = ["c"]`,
  `pkg_config = ["rocksdb"]`. The public surface is `Db`, `Cf`, `Batch`,
  `Iter`, and `Snapshot`; the raw `foreign def`s live under `internal/`.
  `list_families` enumerates the existing column families before an
  open, which the record layer needs to reopen a database with index
  families.
- `record/` — the project-local `emo/record` layer: the catalog (tables,
  columns, types, indexes, oid counters), the row and index encodings,
  `rowid` allocation, and the `Store`/`Table`/`Row`/`Value` surface. Its
  byte codec lives under `internal/`.
- `kv_demo/` — the KV golden: text and embedded-NUL values, an atomic
  batch, a prefix scan, snapshot isolation, and close/reopen.
- `record_demo/` — the record golden: a `users` table covering every v0
  type, NULLs, an embedded NUL in BYTEA, UTF-8 TEXT, a duplicate unique
  key, the table scan, unique and non-unique index scans, and a reopen.
- `engine/` — the embedded SQL engine: the analyzer (names, types, the
  PG-shaped failures), the typed expression tree with three-valued NULL
  logic, the scan/filter/project plan with an equality index scan, the
  CREATE TABLE/INSERT/UPDATE/DELETE executors, and the session plane —
  BEGIN/COMMIT/ROLLBACK, the per-statement snapshot, and the table locks
  through a `LockClient`.
- `engine_demo/` — the engine golden: SQL text in, a command tag, the
  plan tree, and rows out; the error values; a close/reopen.
- `txn_demo/` — the session-plane golden: a lock-manager process, two
  session processes over one Store, read committed, a write-write
  block, and a deadlock.
- `wire/` — the project-local `emo/wire` package: PostgreSQL protocol
  v3's simple query path over `net` — startup (SSL/GSSENC refused,
  trust authentication), ParameterStatus/BackendKeyData/ReadyForQuery,
  Query with a multi-statement string, RowDescription with the v0 type
  OIDs, text-format DataRow, CommandComplete, EmptyQueryResponse, and
  ErrorResponse. One session actor per connection over the shared
  Store, with the table locks of the session plane.
- `wire_demo/` — the wire server: a fresh database, an ephemeral
  listener reported through a ready file, and a fixed number of
  connections.
- `wire_client/` — the standard library's `postgres` client against
  emo-db: the same SQL script psql runs, through libpq's simple path.
- `column_demo/` — the column format's golden: a column table created
  with `STORE = COLUMN`, 1030 rows across the 1024-row block boundary
  in one transaction, the block scan in rowid order, a reopen, and the
  no-indexes/no-primary-key refusals.
- `htap_demo/` — the two-engine proof's server: a row table and a
  column table (1100 rows, across the block boundary) seeded through
  the engine, then served over the wire.
- `htap_client/` — the standard `postgres` client's two-engine script:
  both engines read, then one BEGIN/COMMIT carrying the row table's
  UPDATE and the column table's INSERT.
- `corpus/` — the SQL surface as data: six `.test` files and 126 cases
  in the SQLLogicTest spirit, `statement ok` with a pinned tag,
  `statement error` with a pinned `code: message` line, and `query`
  with pinned rows.
- `corpus_runner/` — the corpus's only code: one fresh database per
  invocation, the files in argument order, per-file counts, failures
  collected.
- `bench/` — the benchmark workloads and `run.sh`; `results.md`
  records the measured numbers.
- `check.sh` — the gate: resolve RocksDB, stage the registry, check the
  four packages, build and run the five embedded demos three times
  against their `expected.txt`, run the corpus three times
  byte-identical, smoke the bench's counts, drive the wire through psql
  and the `postgres` client (one fresh server per phase, each
  byte-pinned), prove both engines in one database the same way, and
  pin the two refusals (the interpreter's E3009 and a
  non-`c` target's E5007).

## The binding's shape

Keys and values are `Bytes`, so they carry arbitrary binary data —
embedded NULs included. A `Bytes` crosses the C ABI as a borrowed
`{data, len}` view (D10), valid only for the call; a read fills a
caller-owned out-parameter because a C buffer's ownership cannot cross a
generic ABI.

Expected failures are values: `(R.ok, …)` or `(R.error, reason)` with
the reason beginning `rocksdb: `. A missing key is not an error — `get`
answers an empty array (absent) or a one-element array (present). Only
contract violations raise: a closed database, a handle used after its
owner closed, an invalid iterator, or a batch mixed with another
database's column family. The facade counts live batches, snapshots, and
iterators and refuses `Db.close` while one is open, so RocksDB's memory
is never freed from under a live handle.

The scheduler is cooperative: every call into the shim serializes, so the
shim carries no locks. Transactions and the lock manager are the
database's own (M32).

## The record layer

The catalog is its own column family: two meta keys carry the next table
and index oids, and one key per table holds the versioned definition
(columns, types, flags, `next_rowid`, and each index's columns). Rows
live in one shared `data` family, keyed by the table oid plus the
`rowid` (8-byte big-endian each). Every secondary index gets its own
family named `idx_<oid>`, keyed by the indexed values (each marked
present or NULL) plus the `rowid`.

The row encoding is a null bitmap followed by the non-null values in
column order: `INTEGER` is 4-byte big-endian and range-checked, `BIGINT`
8-byte, `REAL` and `DOUBLE PRECISION` both binary64 in v0, `BOOLEAN` one
byte, and `TEXT`/`VARCHAR(n)`/`BYTEA` a 4-byte length plus the bytes.
`VARCHAR(n)` counts UTF-8 code points. A unique-index check runs before
the write; the insert's row, index entries, and updated catalog
definition then ride one atomic `WriteBatch`, so a failed write leaves
the `rowid` counter untouched. `update` and `delete` read the old row,
remove its index entries, and write the new row/entries (or the
removals) in one batch; an update's unique check excludes the row's own
rowid. The transaction's `Txn` buffers every write in one `WriteBatch`,
reads at a per-statement snapshot, overlays its own pending entries on
the snapshot (read-your-writes), and publishes the rowid counters only
at COMMIT — which writes the batch with `write_sync`, so the WAL fsyncs
before the answer. Reopening enumerates the families with
`list_families` and verifies every index family the catalog names was
present — a missing one is corruption, not something to recreate
silently.

Index keys are exact-prefix capable (an equality scan is a seek and a
prefix walk), not order-preserving; range scans and streaming scans wait
for a later planner.

## The engine

`emo/engine` is the first full SQL-to-rows path, and its session plane
is the transaction boundary. `execute` parses with
the `sql` package, resolves names and types against the catalog, and
answers a `Result` (the PG command tag, the projected columns and rows,
and the plan text) or a `code: message` failure string in PostgreSQL's
shape. The v0 surface: single-table SELECT with a projection and an
optional WHERE; an equality between an indexed column and a constant
becomes an index scan, everything else a table scan. CREATE TABLE maps
the v0 types and column constraints and gives a primary-key column one
unique index (`<table>_pkey`); INSERT fills omitted columns with NULL
and coerces numeric widening; UPDATE and DELETE locate rows through the
same scan choice and call the record layer's update/delete. The typed
expressions implement SQL's three-valued NULL logic, comparisons,
AND/OR, arithmetic, text `||`, `IS`, `IN`, `BETWEEN`, `LIKE`, and
`CASE`; DISTINCT, joins, subqueries, GROUP BY/HAVING, ORDER BY,
LIMIT/OFFSET, aggregates, functions, CAST, and parameters answer
`0A000`. `engine_demo` shows the whole surface and the error values.

BEGIN opens a transaction, COMMIT writes its batch (fsync included),
and ROLLBACK discards it; a statement inside a transaction takes the
per-statement snapshot, and a statement without one runs in its own
autocommit transaction. A failed statement aborts the transaction. A
write statement acquires the table's lock through the attached
`LockClient` and holds it to COMMIT/ROLLBACK; the lock manager is an
Emo process with a FIFO of waiters, a wait-for graph, and a `40P01`
abort for a deadlock. `txn_demo` runs two sessions and the manager to
show read committed, the write-write block, and the deadlock.

## The wire

`emo/wire` makes the server real. A `net` listener accepts; one process
per connection reads the startup packet, answers AuthenticationOk under
trust, sends the ParameterStatus set, BackendKeyData, and
ReadyForQuery, then runs the simple query cycle. A Query string may
hold several statements: `sql.split` cuts it at the lexer's own
semicolons, and each statement runs through the session's engine. A
SELECT answers RowDescription (name, OID, size, text format) and one
DataRow per row — integers as decimal, floats as their own rendering,
booleans as PG's `t`/`f`, BYTEA as `\x` hex, NULL as the -1 length —
then CommandComplete. A command answers only its tag. An empty string
answers EmptyQueryResponse.

An error answers ErrorResponse with the SQLSTATE and the primary
message, stops the remaining statements, and leaves the session clean:
the engine has already aborted the transaction and released its locks,
so ReadyForQuery reports `I` and the next Query works. psql drives the
whole surface; the standard library's `postgres` client connects over
libpq's simple path for zero-parameter statements (`PQexec`), which is
the same server without the extended protocol. Each connection has its
own Engine over the shared Store and a `RemoteLocks` client over the
server's one lock-manager process, so the table locks of M32 arbitrate
across connections.

The v0 wire is the simple path only: the extended protocol (Parse/
Bind/Execute), SSL, scram-sha-256, and cancel requests are not spoken.
`server_version` reports the PostgreSQL compatibility level (`16.4`)
because tools parse it; the product's own version stays in the package.

## The column store

Arc two's first landing is the format (M35). `CREATE TABLE ... STORE =
COLUMN` names a column table; the catalog's table definition carries a
`store` field (version 2; a version-1 record reads as row storage, so
an old database opens unchanged). A column table's rows live as
1024-row blocks, one column family per column (`col_<oid>`): the block
value is the row count, the null bitmap, then the values in the row
encoding's own widths. An insert re-reads and rewrites the trailing
partial block inside the transaction's batch, so the pending overlay
and the statement snapshot apply unchanged; the reopen verifies every
column family like the index families. Column tables carry no indexes
— `PRIMARY KEY` and secondary indexes answer `0A000`, and the block
scan is the access path. The executor (M36) routes a column table's
SELECT to the blocks: plain projections and WHERE ride the shared
typed expressions over block-materialized values, and the global
aggregates — `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` — accumulate over the
blocks (`count(*)` with no WHERE sums the block counts without
decoding). A select list is all plain items or all aggregate calls (`42803`
names the column otherwise); UPDATE and DELETE answer `0A000` — the
column engine is insert-only — and INSERT rides the column blocks
through the same transaction. The plan text shows `column scan` and
`aggregate`.

The two engines meet in one database: `htap_demo` seeds `items` (a row
table) and `cold_items` (a column table with 1100 rows across the
block boundary) and serves the wire; psql and the `postgres` client
both run a script that reads both engines, then carries the row
table's UPDATE and the column table's INSERT inside one BEGIN/COMMIT —
one WriteBatch, one fsync — and reads the post-commit aggregates. The
bench's column rows are the arc's first measured comparison: the block
scan answers 10000 rows in 304 ms against the row store's 675.

## Conformance and measurement

The corpus states the SQL surface as data and the runner is its only
code. A record is a header (`statement ok`, `statement error`, or
`query`), the statement's lines, and after `----` the expectation — a
command tag, a `code: message` line, or the rows in the runner's
canonical rendering (`|`-separated, `NULL`, `true`/`false`). 126 cases
over one fresh database; the gate runs it three times byte-identical.

The bench's modes print counts only — `bench/run.sh` times them (one
warmup, three timed runs) and writes `bench/results.md`; the design
record carries the measured table. The gate checks the modes run and
answer their counts, never a time.

## Running the gate

RocksDB must be resolvable through `pkg-config`:

```console
$ brew install rocksdb           # macOS
$ sudo apt install librocksdb-dev # Debian/Ubuntu
$ ./check.sh
```

The gate fails loudly when the library is missing rather than skipping —
the binding is the thing under test. The wire phases are the exception:
psql is skipped when it is not on `PATH`, and the `postgres` client's
phase is skipped when libpq is not resolvable through `pkg-config` (the
same Homebrew-keg fallback the standard library's probe uses). `EMO`
may point at a different compiler binary; the default is
`../../_build/default/src/emo_cli/emo.exe`.

## Status

M28 landed 2026-11-12: the binding, the KV golden, and the C ABI's byte
view. M29 landed the same day: the record layer, the record golden, and
the catalog's reopen path. M30 landed the SQL front-end's DDL/DML, M31
the embedded planner/executor and its golden, M32 the transaction and
session plane with its two-session golden, and M33 the PostgreSQL wire
with psql and the `postgres` client as goldens. M34 landed 2026-11-13:
the 126-case corpus, the measured table, and the shipped-surface
documentation close arc one. M35 landed the same day: the column
format — the parser's `STORE = COLUMN` tail, the catalog's version-2
`store` field, the 1024-row blocks, the column families, and the
reopen's verification. M36 followed hours later: the column executor —
the block scan with the shared filter and project, and the global
aggregates COUNT/SUM/AVG/MIN/MAX — replaced the bridge; UPDATE and
DELETE on a column table answer `0A000` (insert-only). M37 closed the
arc the same day: `htap_demo` and `htap_client` prove both engines in
one database and one transaction over the wire, the corpus's
`column.test` states the column surface as 15 more cases, and the
bench's column rows record the first measured comparison (the block
scan 304 ms against the row store's 675 for 10000 rows).
