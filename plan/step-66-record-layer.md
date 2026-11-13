# Step 66 — The record layer

**Milestone:** M29 · **Prereq:** step 65 (the `emo/rocksdb` binding, the
`Bytes` view) · **Status:** landed 2026-11-12

## Why this step exists

The KV half is a byte store. A database needs its own data model above
it: a catalog that knows tables, columns, types, and indexes; a row
encoding that round-trips the v0 type subset without losing a byte; a
rowid that allocates inside the same atomic write as the row; and
secondary indexes that let a query find a row without scanning the
table. This step is that model, and it is the last layer M31's planner
needs before it can turn SQL text into rows.

The step deliberately ships **no SQL**: no parser, no plan nodes, no
wire. Those are M30–M33. The demo here calls the record API directly.

## Decisions settled here (the trail)

- **Rows live in one shared `data` column family.** The key is the
  table oid and the rowid, both 8-byte big-endian; the value is the row
  blob. One CF instead of one per table keeps the open list bounded and
  makes a table scan a prefix walk. Indexes keep the design record's
  one-CF-per-index rule.
- **The catalog is its own column family and its own format.** Keys are
  a one-byte kind (`0x00` meta, `0x01` table) plus a big-endian oid; the
  values are a versioned TLV. The catalog holds `next_table_oid`,
  `next_index_oid`, and one record per table (columns, types, flags,
  `next_rowid`, and the index definitions).
- **The row encoding is a null bitmap plus the non-null values in column
  order.** `INTEGER` is 4-byte big-endian and range-checked; `BIGINT`
  is 8-byte big-endian; `REAL` and `DOUBLE PRECISION` are both stored
  as binary64 in v0 (a 4-byte REAL narrowing waits for a Float32 or a
  rounding routine); `BOOLEAN` is one byte; `TEXT`, `VARCHAR`, and
  `BYTEA` are a 4-byte big-endian length plus the bytes. `VARCHAR(n)`
  counts UTF-8 code points and stores the bytes.
- **An index key is the indexed values in order, each marked present or
  NULL, then the rowid.** `0x00` means NULL; `0x01` is followed by the
  value's normal encoding. The key is exact-prefix capable, so an
  equality scan is a seek plus a prefix walk. It is not
  order-preserving for ranges — that waits for the planner and a
  comparison encoding (M31).
- **Rowid allocation rides the row's batch.** The table definition
  carries `next_rowid`; an insert writes the row, every index entry,
  and the updated table definition in one `WriteBatch`. A failed write
  leaves the counter untouched. The unique-index check is a read before
  that batch; M29 is single-session, and M32's lock manager makes it
  safe across sessions.
- **The open list is enumerated, not assumed.** `rocksdb.list_families`
  reads the existing CFs before open; the record layer opens with the
  union of those and the three base names (`default`, `catalog`,
  `data`), so a database with index CFs reopens. After loading the
  catalog, every index CF must have been in the pre-open list — a
  missing index CF is corruption, not a silent re-creation.
- **Errors follow the binding's split.** Storage failures and duplicate
  keys are `(R, reason)` with a `record: ` prefix; a wrong value count,
  a mismatched type, a null in a NOT NULL column, an unknown column
  name, or a malformed row raises. The SQL layer maps these onto
  PG-shaped error strings in M31.
- **Scans answer arrays in v0.** `Table.scan` and `Table.scan_index`
  materialize rows; a streaming iterator waits for the planner, where
  a plan node needs one. The demo's tables are tiny, and M34 measures
  before a cursor-shaped API is added.

## The format (v0, version 1)

All multi-byte integers are big-endian. `string` is a 4-byte length
plus UTF-8 bytes; `bytes` is a 4-byte length plus the raw bytes.

**Catalog CF**

| Key | Value |
| --- | --- |
| `0x00 0x01` | `u64` next table oid (default 1) |
| `0x00 0x02` | `u64` next index oid (default 1) |
| `0x01` + `u64` table oid | the table definition below |

Table definition:

```
u8 version = 1
string name
u64 next_rowid
u32 column_count
  per column: u32 oid, string name, u8 kind, u8 flags, u32 varchar_len
u32 index_count
  per index: u32 oid, string name, u8 unique, u32 column_count,
             u32 column_oid ...
```

`kind`: 1 INTEGER, 2 BIGINT, 3 REAL, 4 DOUBLE, 5 TEXT, 6 VARCHAR,
7 BOOLEAN, 8 BYTEA. `flags`: bit 0 nullable, bit 1 primary.

**Data CF**

| Key | Value |
| --- | --- |
| `u64` table oid + `u64` rowid | the row blob |

Row blob:

```
null bitmap: ceil(column_count / 8) bytes; bit (i % 8) of byte (i / 8)
per non-null column, in order:
  INTEGER   i32
  BIGINT    i64
  REAL      u64 (binary64 bits)
  DOUBLE    u64 (binary64 bits)
  BOOLEAN   u8 (0 or 1)
  TEXT      bytes
  VARCHAR   bytes
  BYTEA     bytes
```

**Index CF** (one per index, named `idx_<oid>`)

| Key | Value |
| --- | --- |
| per indexed column: `u8 0` (NULL) or `u8 1` + the value encoding; then `u64` rowid | empty |

An equality scan seeks the encoded values as a prefix and walks while
the key still starts with it; the rowid is the key's last eight bytes.

## Tasks

- [x] **T66.1** — This step file, the plan README row, and the Step 66
      sections in `docs/TASKS.md` + zh, sized for spare sittings.
- [x] **T66.2** — The design notes: `docs/emo-db.md` + zh (D7's REAL
      note, the architecture's storage item naming the shared data CF,
      the M29 row, and the open items for range scans/streaming).
- [x] **T66.3** — The binding's `list_families(path)`: the shim's list
      handle over `rocksdb_list_column_families`, the FFI declarations,
      the facade's `(R, Array[String])`, and the missing-path empty
      answer; the KV demo's gate stays green.
- [x] **T66.4** — `projects/emo-db/record/` skeleton: `package.emo`
      (`emo/record`, `targets = ["c"]`, dep `emo/rocksdb`) and
      `internal/codec.emo` — `Buf`/`Reader` for u8/u32/u64/i32/i64/
      bytes/string, bounds-checked, with UTF-8 length and bytes-prefix
      helpers. The row/index encoders and the catalog codec live in
      `record.emo` itself: a root ↔ internal reference is a module
      cycle when the internal module also calls root defs, so only the
      type-free codec stays internal.
- [x] **T66.5** — The public types and constructors in `record.emo`:
      `ColType`, `Column`, `Index`, `ColumnDef`, `IndexDef`, `Value`,
      `Row`, `Table`, `Store`, the value constructors, `type_name`, and
      the contract checks (names unique, indexes reference columns,
      VARCHAR length positive, primary implies NOT NULL).
- [x] **T66.6** — The row encoder/decoder, the value encoder, the
      index-key encoder, the VARCHAR code-point check, and the
      malformed-row guards (in `record.emo`).
- [x] **T66.7** — The catalog keys, the table definition
      encoder/decoder, the counters, and the load/save through the
      binding (in `record.emo`).
- [x] **T66.8** — `Store.open`/`close`/`table`/`tables`/`create_table`:
      CF enumeration, the base-CF open, the catalog load and index-CF
      verification, oid allocation, the index-CF creation, the catalog
      batch, and the reopen path.
- [x] **T66.9** — `Table.insert`: value validation, the unique-index
      read, the rowid, the row/index/catalog batch, the counter update
      on success, and the duplicate-key error value.
- [x] **T66.10** — `Table.get`/`scan`/`scan_index`: the row-key reads,
      the table prefix scan, the index prefix scan with the rowid
      suffix, and the ordered results.
- [x] **T66.11** — `projects/emo-db/record_demo/` skeleton: destroy,
      open, create `users`, list the catalog, close; `expected.txt`
      seeded.
- [x] **T66.12** — The demo's insert beats: three rows covering every
      type, NULLs, an embedded NUL in BYTEA, UTF-8 TEXT, and a
      duplicate unique key answering the error value.
- [x] **T66.13** — The demo's read beats: get by rowid, the table scan,
      the name-index equality scan, the id-index scan, and the reopen
      listing the catalog and the rows.
- [x] **T66.14** — The gate: stage `emo/record`, build the record demo,
      run it three times against `expected.txt`, and keep the KV demo
      and the E3009/E5007 pins green; the record demo's lock via
      `emo deps resolve`.
- [x] **T66.15** — The project README + zh: the record layer's formats,
      the demo, and the gate.
- [x] **T66.16** — The close-out: TASKS EN+zh, the plan README, the
      M29 row, `CHECK.md`'s entry, and `dune build`/`@fmt` green.

## Evidence

- `projects/emo-db/check.sh` green with both goldens: the binding and
  the record layer type-check; the KV demo and the record demo build;
  three runs each are byte-identical; `emo run` on the KV demo exits 70
  with E3009 and the ocaml build exits 65 naming the missing target.
- The record demo's output: `create: users columns=8 types=...`, the
  three rowids, the duplicate-key error, `get 2`/`get 99`, the three-row
  scan, the `users_name`/`users_active`/`users_id` index scans, the
  reopen summary, and the three rows again — 22 lines, in
  `record_demo/expected.txt`.
- `dune build` and `@fmt` green; the full `dune runtest` waits for the
  next requested run, per the auto-test rule.

## Found on the way

- **The unique index check asked for the prefix key, but the stored key
  carries the rowid.** `get(prefix)` missed every existing entry, so a
  duplicate name was accepted (the demo's own probe caught it). The fix
  seeks an iterator at the prefix and tests `starts_with` on the first
  key — the same prefix walk the scans use.
- **A root ↔ internal module pair is a cycle when the internal module
  calls root defs.** The first layout split the encoders and the catalog
  into `internal/encode`/`internal/catalog`; both reference the root's
  `Value`/`Column` types, and the root calls them, which the checker
  reports as `record -> internal.encode -> record` (and the catalog's
  call into the encoder made it a three-module cycle). The fix keeps
  only the type-free byte codec internal and moves the encoders and the
  catalog codec into `record.emo`.
- **An empty-array accumulator is a dynamic-typed element**, so
  `bitmap[i] >> n` in the row decoder hit the c target's "bitwise
  operators in the dynamic world" refusal. The bitmap is a `Bytes`
  buffer now; `get` answers a typed Int64.
- **Syntax facts:** `def` is a reserved word (a local named `def` is a
  parse error), `;` separates `for` clauses only (branch bodies put one
  statement per line), and a Void function takes no bare `return`.

## Open, deliberately

## Open, deliberately

- **Range scans** — the index key is exact-prefix capable, not
  order-preserving; a comparison encoding (and the planner's range
  nodes) is M31's.
- **Streaming scans** — v0 materializes; a cursor-shaped API waits for
  the plan node that consumes one.
- **REAL's 4-byte storage** — binary64 in v0; the narrowing waits for
  Float32 or a rounding routine, and the decision is recorded in D7's
  note.
- **UPDATE/DELETE** — M31's executor owns them; the record layer's
  `insert` is the only writer here, so index maintenance on removal is
  not yet exercised.
- **Multi-session safety** — the unique check and the rowid counter are
  single-session in M29; the lock manager and the transaction plane are
  M32's.
- **Streaming a value larger than memory** — M29's values are whole
  `Bytes`; the bound waits for a binary file story (arc two).
