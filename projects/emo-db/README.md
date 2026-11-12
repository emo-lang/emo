# emo-db

emo-db is Emo's own client-server SQL database: one PostgreSQL-dialect
surface over two engines — a row store for OLTP first, a column store
for OLAP later. The design record is [`docs/emo-db.md`](../../docs/emo-db.md);
this directory is the project. M28 (the RocksDB half) and M29 (the
record layer) are landed; the planner, transactions, and the wire follow
in M30–M34.

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
- `check.sh` — the gate: resolve RocksDB, stage the registry, check both
  packages, build and run both demos three times against their
  `expected.txt`, and pin the two refusals (the interpreter's E3009 and a
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
the `rowid` counter untouched. Reopening enumerates the families with
`list_families` and verifies every index family the catalog names was
present — a missing one is corruption, not something to recreate silently.

Index keys are exact-prefix capable (an equality scan is a seek and a
prefix walk), not order-preserving; range scans and streaming scans wait
for the planner (M31).

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
the catalog's reopen path. M30 — the SQL front-end's DML and DDL — is
next.
