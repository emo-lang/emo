# emo-db

emo-db is Emo's own client-server SQL database: one PostgreSQL-dialect
surface over two engines — a row store for OLTP first, a column store
for OLAP later. The design record is [`docs/emo-db.md`](../../docs/emo-db.md);
this directory is the project. M28 (the RocksDB half), M29 (the record
layer), M30 (the SQL front-end's DML/DDL), M31 (the planner and
executor), and M32 (transactions and the session plane) are landed; the
wire and the conformance pass follow in M33–M34.

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
- `check.sh` — the gate: resolve RocksDB, stage the registry, check the
  three packages, build and run the four demos three times against
  their `expected.txt`, and pin the two refusals (the interpreter's
  E3009 and a non-`c` target's E5007).

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

## Running the gate

RocksDB must be resolvable through `pkg-config`:

```console
$ brew install rocksdb           # macOS
$ sudo apt install librocksdb-dev # Debian/Ubuntu
$ ./check.sh
```

The gate fails loudly when the library is missing rather than skipping —
the binding is the thing under test. `EMO` may point at a different
compiler binary; the default is `../../_build/default/src/emo_cli/emo.exe`.

## Status

M28 landed 2026-11-12: the binding, the KV golden, and the C ABI's byte
view. M29 landed the same day: the record layer, the record golden, and
the catalog's reopen path. M30 landed the SQL front-end's DDL/DML, M31
the embedded planner/executor and its golden, and M32 the transaction
and session plane with its two-session golden. M33 — the PostgreSQL wire
— is next.
