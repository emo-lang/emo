# Step 72 — The column format

**Milestone:** M35 · **Prereq:** steps 65–71 (arc one closed) ·
**Status:** landed 2026-11-13

## Why this step exists

Arc two's cut is settled: the column engine arrives as a second
implementation behind the same surface. This step is the storage half —
a column table exists in the catalog, stores its values as blocks in
one column family per column, reopens, and scans — while every row-table
behavior stays byte-identical.

## Decisions settled here

- **`STORE = COLUMN` is the catalog's first schema change.** The table
  definition's encoding moves to version 2 with a `store` field; a
  version-1 record decodes as row storage, so an old database opens
  unchanged. The parser takes the tail after the column list; `STORE =
  ROW` is the default and the canonical rendering only spells `STORE =
  COLUMN` when written (or declared).
- **1024-row blocks, one column family per column.** `col_<oid>`,
  keyed by the block id; the block value is the row count, the null
  bitmap (128 bytes for 1024 rows), then the values in the row
  encoding's own widths (4-byte INTEGER, 8-byte BIGINT/REAL/DOUBLE,
  1-byte BOOLEAN, length-prefixed TEXT/VARCHAR/BYTEA). No block-index
  column family and no min/max statistics in this cut — a scan
  iterates the block ids; pruning waits for its own evidence.
- **The trailing partial block is re-read and rewritten.** An insert
  reads the last block through the transaction (pending overlay
  included), appends the row, and puts it back; a full block starts
  the next block id. The table's `next_rowid` counter counts rows for
  column tables exactly as for row tables.
- **Column tables carry no indexes.** `PRIMARY KEY` and secondary
  indexes answer `0A000` (the engine refuses before the record layer;
  the record layer refuses again defensively). The block scan is the
  access path; a unique constraint is the application's job until a
  later step says otherwise.
- **The engine bridges, not routes.** The DDL maps `STORE = COLUMN` to
  the record layer; DML and SELECT on a column table answer `0A000:
  column-store execution is not supported in v0` — the named bridge
  step 73 replaces with the batch executor.

## Tasks

- [x] **T72.1** — This file and the Step 72 section EN+zh.
- [x] **T72.2** — `sql`: the `StoreKind`, the `CreateTable.store`
      field, the tail parse, and the canonical rendering; the two
      examples' cases on the six paths.
- [x] **T72.3** — `record`: the `Storage` enum, `TableMeta.store`, the
      version-2 encoding and the version-1 read, the column column
      families, `insert_column_tx` / `scan_column_tx`, and the reopen
      verification.
- [x] **T72.4** — `column_demo`: create, insert, reopen, scan, and the
      index refusal, pinned on `c`.
- [x] **T72.5** — `engine`: the DDL mapping and the `0A000` bridge for
      DML/SELECT on column tables; the engine demo's new cases.
- [x] **T72.6** — The gate: the fifth demo's build and three
      byte-identical runs.
- [x] **T72.7** — The docs EN+zh and the close-out.

## Evidence

- `projects/emo-db/check.sh` green three times with 66 checks: the four
  package checks, five embedded demos three runs each, the corpus's
  three byte-identical runs, the bench build and smoke, the wire's two
  phases, and the two refusals.
- `column_demo/expected.txt`: create (`events`, column), 1030 rows in
  one transaction (block 0 fills to rowid 1024, block 1 holds
  1025–1030), the block scan in rowid order with the boundary rows
  printed, the reopen and rescan, and the two create refusals.
- `engine_demo/expected.txt` grows the seven column cases: the DDL
  mapped (`CREATE TABLE`, `plan: create table cold`), the four bridges
  (`0A000: column-store execution is not supported in v0`), the
  primary-key refusal, and the explicit `STORE = ROW` and plain creates.
- `sql_demo`/`sql_edge` (with the storage-tail cases) are byte-identical
  on the interpreter, c, OCaml, TypeScript, wasm, and BEAM.
- `dune build`/`@fmt` green.

## Found on the way

- **The golden caught the catalog's v2 encoding order on its first
  run.** `encode_table` wrote the `store` tag after the name while
  `decode_table` read it before the name, so the reopened table decoded
  as row storage and the rescan raised the row-path guard. The tag now
  sits between the version byte and the name, matching the reader.
- **The open path verified column families unconditionally.** A row
  table's missing `col_<oid>` would have raised at open; the
  verification now runs behind the store check.
- **The registry's staged copy and the cache materialization can
  disagree after an edit.** The demo's first fixed build still served
  the old package until every consumer's `deps resolve` ran against the
  updated registry; a package edit needs the resolve in every
  dependent before a build is trusted.
- **A version-2 field belongs beside the version byte.** The layout
  rule the fix landed: a version's own fields come first, then the
  fields they qualify.
