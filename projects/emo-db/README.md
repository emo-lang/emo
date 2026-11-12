# emo-db

emo-db is Emo's own client-server SQL database: one PostgreSQL-dialect
surface over two engines — a row store for OLTP first, a column store
for OLAP later. The design record is [`docs/emo-db.md`](../../docs/emo-db.md);
this directory is the project. M28, the RocksDB storage half, is the
first landing; the catalog, the row encoding, the planner, transactions,
and the wire follow in M29–M34.

## Layout

- `rocksdb/` — the project-local `emo/rocksdb` binding: a package-carried
  C shim over RocksDB's official C API, `targets = ["c"]`,
  `pkg_config = ["rocksdb"]`. The public surface is `Db`, `Cf`, `Batch`,
  `Iter`, and `Snapshot`; the raw `foreign def`s live under `internal/`.
- `kv_demo/` — the KV golden: text and embedded-NUL values, an atomic
  batch, a prefix scan, snapshot isolation, and close/reopen. Its
  `expected.txt` is the pinned output; `package.lock` pins the binding.
- `check.sh` — the gate: resolve RocksDB, stage the registry, build the
  demo, run it three times against `expected.txt`, and pin the two
  refusals (the interpreter's E3009 and a non-`c` target's E5007).

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
view. M29 — the record layer (catalog, row encoding, rowid allocation,
secondary indexes) — is next.
