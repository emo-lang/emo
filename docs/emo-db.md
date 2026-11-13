# emo-db — the design record

Written 2026-11-12. This is the decided design for emo-db, Emo's own
database: what the product is, the decisions behind the shape, the
ladder that builds it, and what stays open. The feasibility background
is `docs/sql-database.md` (2026-10-06); its tier framing is the honest
scale this project inherits. Decisions here were settled with the
project owner; open items are stated as open, with the reason.

## The product, in one paragraph

emo-db is a client-server SQL database written in Emo. One SQL surface
— PostgreSQL's dialect, spoken over PostgreSQL's wire protocol — in
front of two engines: a row store for OLTP first, a column store for
OLAP later, chosen per table. The storage layer underneath is not
hand-built: the row store rides RocksDB through the binding shape the
`sqlite3` and `postgres` packages already proved. The goal is the two
products the ecosystem knows — a PostgreSQL/MySQL-style transactional
service and ClickHouse-style analytics — as one project with one
surface.

## Why one project, not two

The two goals share more than they differ, and the shared part is the
bulk: SQL parsing, the AST, the type system, the catalog, the planning
scaffolding, expression evaluation, error codes, the wire protocol,
the client tooling. Two projects would duplicate exactly that part and
guarantee the classic disaster of database engineering — two SQL
dialects drifting apart. What genuinely differs is the storage format
and the executor, and those live as separate packages inside one
project anyway.

The combination is also the product story neither project could give
alone: one SQL surface, per-table storage choice (`STORE = ROW` /
`STORE = COLUMN`), one planner routing each query to the engine that
holds the table. This is the TiDB (TiKV + TiFlash) and SingleStore
shape — HTAP by table, not by product. Splitting into `emo-db-sql` and
`emo-db-olap` is rejected on these grounds. If the OLAP engine ever
grows to where a separate repository pays for itself, it extracts from
emo-db then — a decision made by weight, not paid for upfront.

## The decisions

**D1 — The storage layer is RocksDB, not hand-built.** fsync, WAL,
compaction, and compression are RocksDB's job. This is the
CockroachDB/TiDB precedent the feasibility assessment itself named
("neither builds a B-tree"), and it dissolves the assessment's first
Tier-B gate — no fsync, no WAL — because the fsync discipline is no
longer ours to write. The binding is the `postgres`/`sqlite3` shape: a
package-carried C shim over the official C API (`rocksdb/c.h`),
reached through `foreign def`s with the manifest's `link` /
`pkg_config` fields naming the library. The keys and values ride
`Bytes` through D10's borrowed view. `c` target only; every other
target refuses at resolution, the interpreter at run time.

**D2 — One project, one SQL surface, two engines.** As above. The
catalog, the types, the front-end, the wire, and the tooling are
shared from the first commit; the row and column engines are separate
packages behind one planner.

**D3 — OLTP first.** The OLTP arc builds the shared front-end; the
OLAP engine plugs under it afterward. The reverse order — a
DuckDB-shaped analytical engine first — is the smaller product to a
credible v1, but it has no wire protocol, no transaction plane, and
leaves the shared front-end unbuilt, which is the part both arcs
need. The RocksDB decision is itself row-shaped, which seals the
order.

**D4 — Client-server.** The product is a server: an Emo program built
from the project, accepting connections over `net`, one session actor
per connection (the `httpd` precedent). An embedded in-process
library face is not v0 scope; nothing in the architecture forecloses
one later.

**D5 — PostgreSQL wire protocol v3.** The protocol is the de facto
interop standard (the assessment's own words): psql, and the wider PG
driver ecosystem, can connect the day the wire is right. Emo's own
proof is immediate — the standard library's `postgres` client speaks
libpq's protocol, so Emo programs talk to emo-db through an existing
package. That client doubles as the dogfood golden.

**D6 — Emo's actor plane owns concurrency control, not TransactionDB.**
The session actor owns its transaction state. Writes buffer in a
RocksDB WriteBatch; COMMIT is one atomic write with RocksDB's WAL
behind it; ROLLBACK drops the batch. Reads ride RocksDB snapshots —
read committed (a snapshot per statement) first, repeatable read (a
snapshot per transaction plus conflict detection) later. Write-write
conflicts go through an Emo-owned lock manager. Two reasons: the
plain C API is smaller and steadier than the TransactionDB surface,
and the lock manager is the assessment's "the actor model maps onto
the database's control plane" made concrete — Emo's concurrency is
the design's advantage on exactly this plane.

**D7 — The v0 type subset.** INTEGER, BIGINT, REAL, DOUBLE PRECISION,
TEXT, VARCHAR(n), BOOLEAN, BYTEA (riding `Bytes`). REAL and DOUBLE
PRECISION both store as binary64 in v0; REAL's 4-byte narrowing waits
for a Float32 or a rounding routine. Deferred: NUMERIC
(waits on Int128/bignum — the language gap the assessment listed),
DATE/TIMESTAMP (waits on a calendar library; a candidate standalone
package later).

**D8 — v0 wire scope: the simple query path.** Startup, trust
authentication, Query / RowDescription / DataRow / CommandComplete /
ReadyForQuery, ErrorResponse with PG's error-field convention,
multi-statement strings. psql drives the whole surface with this.
Deferred: the extended protocol (prepared statements — what most
drivers default to), scram-sha-256, SSL. The standard library's
`postgres` client meets the server on this path by taking `PQexec` for
a zero-parameter statement; a parameterized statement still speaks the
extended protocol and fails honestly against v0. The standard library's
`postgres` client meets the server on this path by taking `PQexec` for
a zero-parameter statement; a parameterized statement still speaks the
extended protocol and fails honestly against v0.

**D9 — The ladder.** Arc one is milestones M28–M34, one milestone per
step, steps 65 through 71. The exit criteria live in `docs/TASKS.md`;
the ladder's shape:

| Milestone | Steps | Lands |
| --- | --- | --- |
| M28 — The RocksDB half | 65 | The project scaffold and the C shim, with the `Bytes` borrowed view (D10): open/close, get/put/delete, WriteBatch, iterators, snapshots, column families. |
| M29 — The record layer | 66 | The catalog column family, the row encoding, rowid allocation, and secondary indexes as one column family per index — rows in one shared `data` family keyed by table oid + rowid. |
| M30 — The SQL front-end's DML and DDL | 67 | `sql` grows CREATE TABLE / INSERT / UPDATE / DELETE beside SELECT — pure Emo, byte-identical on every target. |
| M31 — The planner and executor | 68 | The first full SQL-to-rows path: plan nodes (scan/filter/project, insert/update/delete), expression evaluation over the record layer, an embedded test face. The v0 SELECT is single-table (projection, WHERE, an equality index scan); joins, aggregates, ORDER BY/LIMIT, and subqueries wait for M34. |
| M32 — Transactions and the session plane | 69 | BEGIN/COMMIT/ROLLBACK, read committed on per-statement snapshots, one WriteBatch per transaction with the COMMIT's fsync, the Emo lock manager. Table-level locks in v0. |
| M33 — The wire | 70 | PG protocol v3, simple path: startup (SSL/GSSENC refused, trust authentication), ParameterStatus/BackendKeyData/ReadyForQuery, Query with multi-statement strings, RowDescription with the v0 OIDs, text-format DataRow, CommandComplete, EmptyQueryResponse, and ErrorResponse; one session actor per connection over the shared Store and the table locks; psql end-to-end and the `postgres` client through its zero-parameter simple path. |
| M34 — Conformance and documentation | 71 | The SQL corpus — 126 text-comparable cases in the SQLLogicTest spirit over one fresh database, tags, rows, and `code: message` errors pinned — the measured-performance table (`projects/emo-db/bench`), the shipped-surface documentation, and the arc-two review. |

**D10 — The byte view: `Bytes` crosses the C ABI as a borrowed view.**
RocksDB's keys and values are arbitrary bytes — an embedded NUL is
ordinary data — and the sqlite3/postgres bindings' NUL-terminated
String crossing would truncate them. The `c` target's foreign ABI
grows one shape for this: a `Bytes` parameter crosses as
`{data, len}`, borrowed for the call only (the C side never retains
it); a `Bytes` **return** stays refused, because ownership of a C
buffer cannot cross a generic ABI — a read takes a caller-provided
out-parameter (length first, then copy in), so the Emo side always
owns the bytes. The interpreter keeps E3009; every other target keeps
its marshaling tier. This is the one language change v0 needs, and it
lands with M28's binding because the row encoding (M29) cannot be
built on NUL-terminated strings.

## The architecture

Top to bottom:

1. **The wire** — PostgreSQL protocol v3, the simple query path:
framing, startup and authentication, the query cycle, error
reporting. `net` accepts; one session actor per connection.
2. **The session plane** — per-session state: the current
transaction's WriteBatch and snapshot, statement dispatch, the result
stream back through the wire, the session's held locks.
3. **The SQL front-end** — the `sql` package, pure Emo and
byte-identical on every target: the AST and parser grow CREATE TABLE,
INSERT, UPDATE, DELETE beside the existing SELECT.
4. **The planner and executor** — logical plan nodes (scan, filter,
project, insert, update, delete) and expression evaluation over the
record layer's values.
5. **The record layer** — the catalog (tables, columns, types, by
oid, in its own column family), the row encoding (null bitmap,
fixed-width and length-prefixed variable-width values), rowid
allocation, and secondary indexes: one column family per index, keyed
by the indexed columns plus the rowid. Rows live in one shared `data`
column family keyed by the table oid plus the rowid; the catalog is its
own column family; the index keys are exact-prefix capable (an equality
scan is a seek and a prefix walk) and not yet order-preserving.
6. **The storage half** — RocksDB through the package's C shim:
open/close, get/put/delete, WriteBatch, iterators, snapshots, column
families. Keys and values cross as `Bytes` through D10's borrowed
view; a read fills a caller-owned buffer.

One property worth stating because the whole binding leans on it: the
scheduler's cooperative model means every call into RocksDB
serializes — the shim grows no locks of its own, and the lock manager
arbitrates transactional conflict, not memory safety. M28 verifies
this premise; if a hosted runtime ever grows true parallelism, the
premise is re-checked there.

## What shipped

Arc one closes with a row store behind the PostgreSQL surface. The
ladder, top to bottom as packages:

- **`emo/rocksdb`** (`projects/emo-db/rocksdb`) — the C shim over
  RocksDB's official API: open/close, get/put/delete, WriteBatch,
  iterators, snapshots, column families, `list_families`, and the
  COMMIT's `write_sync`. Keys and values are `Bytes` (D10).
- **`emo/record`** (`projects/emo-db/record`) — the catalog column
  family (tables, columns, types, indexes, oid and rowid counters), the
  row encoding over the v0 types, rowid allocation, one column family
  per index, and the `Txn`: one WriteBatch, a per-statement snapshot
  (read committed), a pending overlay for read-your-writes, the
  rowid counters published only at commit.
- **`sql`** (standard library, pure Emo on all five targets) — the AST
  and parser for SELECT, CREATE TABLE, INSERT, UPDATE, DELETE, and
  BEGIN/COMMIT/ROLLBACK, the canonical renderings, `split` for
  multi-statement strings, and the shape checks that answer byte-offset
  errors instead of guessing.
- **`emo/engine`** (`projects/emo-db/engine`) — the analyzer, the typed
  expressions with three-valued NULL logic, the scan/filter/project
  plan with an equality index scan, the four executors, the session
  plane (transaction state, table locks through a `LockClient`), and
  the lock-manager process with a wait-for graph and `40P01`.
- **`emo/wire`** (`projects/emo-db/wire`) — protocol v3's simple query
  path over `net`: one session actor per connection, trust
  authentication, the ParameterStatus set, multi-statement Query
  strings, RowDescription with the v0 OIDs, text-format DataRow,
  CommandComplete, EmptyQueryResponse, ErrorResponse, and
  ReadyForQuery.

The v0 SQL surface, stated exactly: CREATE TABLE with the eight v0
types and column-level `NOT NULL`/`PRIMARY KEY`; INSERT with an
optional column list and one or more rows; UPDATE and DELETE with an
optional WHERE; single-table SELECT with a projection, aliases, and a
WHERE over comparisons, AND/OR/NOT, arithmetic, text `||`, `IS`, `IN`,
`BETWEEN`, `LIKE`, and `CASE` — an equality between an indexed column
and a constant becomes an index scan, everything else a table scan; and
BEGIN/COMMIT/ROLLBACK over read committed. Everything else answers
`0A000` by name — joins, subqueries, GROUP BY/HAVING, ORDER BY/LIMIT,
DISTINCT, aggregates, functions, CAST, parameters — or the PG-shaped
code for its own failure family: `42601` parse, `42P01` missing
relation, `42703` missing column, `42883` missing operator,
`42804` type mismatch, `23505` unique, `23502` not-null, `22001` too
long, `22012` division by zero, `42P07` duplicate table, `42P16`
multiple primary keys, `25001`/`25P01` transaction state.

The corpus is the surface as data: `projects/emo-db/corpus/` holds six
`.test` files (ddl, types, dml, select, transactions, errors) and 126
cases in the SQLLogicTest spirit — `statement ok` with an optional
pinned command tag, `statement error` with a pinned
`code: message` line, and `query` with pinned rows rendered canonically
(`|`-separated, NULL as `NULL`, booleans `true`/`false`). One runner
(`corpus_runner`) destroys and reopens one database per invocation,
executes the files in order, and the gate compares its transcript
across three runs byte for byte.

## Measured

Numbers only where the bench script measured them (`projects/emo-db/bench/run.sh`,
2026-11-13, Darwin arm64, c target; one warmup and three timed runs,
the mean in milliseconds per run; `bench/results.md` carries the
record):

| workload | size | ms per run | per second |
| --- | --- | ---: | ---: |
| INSERT, autocommit | 200 rows, one transaction each | 1160 | 172 inserts |
| INSERT, one transaction | 10000 rows, one COMMIT | 6680 | 1497 inserts |
| primary-key lookup | 10000 lookups over 10000 rows | 1037 | 9643 lookups |
| full table scan | 10000 rows, one SELECT | 580 | 17241 rows |
| UPDATE, autocommit | 200 rows by primary key | 1305 | 153 updates |

The autocommit rows are one fsynced write each — the durability point
is the point. Not measured: the wire's per-query latency, concurrent
sessions, tables larger than memory, and arc two's column engine.

## Arc two — the OLAP shape (direction decided, cut open)

Arc one's planner now exists to plug into, so the sketch is reviewed
against what the row store actually built:

- **The plug point is the plan, not the parser.** The analyzer, the
  AST, the type rules, and the catalog are storage-agnostic; a column
  engine would sit behind the same scan/filter/project shape and the
  same `Result`. Arc one's nodes materialize one row at a time, so a
  column engine's batch-shaped executor is the second implementation
  behind one interface.
- **The catalog carries no storage choice yet.** `STORE = COLUMN` is
  the first schema change: one field in the catalog's table record,
  and the planner routing by it.
- **The storage layout already shows the shape.** One column family
  per index is v0's own precedent for one column family per column;
  column blocks would ride as values in those families, crossing the
  same `Bytes` borrowed view.
- **The shared blockers are the type system's.** NUMERIC (Int128 or a
  bignum in the language) and DATE/TIMESTAMP (a calendar package) are
  engine-agnostic; arc two inherits whatever lands first.
- **The wire and the session plane are engine-agnostic already.** The
  same protocol, transactions, locks, and snapshots serve the column
  store without a second control plane.
- **The vectorized evaluator is the real new code.** Scans pruned by
  block-level min/max statistics, and a Parquet-like segment format of
  our own only if the column-family layout's evidence demands it.

The arc's milestone cut is the next design act, not this pass: arc one
closes with the plug points named, and the cut starts from them.

## The honest costs

- Even with the storage layer outsourced, arc one is the assessment's
Tier-B shape minus storage engineering: person-years, not months. The
ladder is cut small on purpose — one milestone per step, each with a
byte-pinned golden.
- The correctness burden does not shrink with the language. SQL
breadth, crash semantics, and protocol conformance are the product.
- The GC tail-latency question (the assessment's #4) lands the day
latency is measured; the backend choice is made early, deliberately.
- The churn tax is real: a pre-1.0 language moves and the engine
moves with it; every rename the language lands, the engine's corpus
follows.

## Open items

Stated as open, each waiting on its own evidence or decision:

- The failed-transaction state — the wire reports ReadyForQuery `I`
after a statement error because the engine aborts and releases the
transaction immediately; PostgreSQL's `E` (a block that only ROLLBACK
leaves) waits for a transaction model that keeps the failed block.
- The extended protocol — when a driver beyond psql and libpq's
simple path demands it.
- scram-sha-256 and SSL — real authentication and real transport
security; the `crypto` package already holds the pieces.
- NUMERIC — with Int128 or a bignum in the language.
- DATE/TIMESTAMP — with a calendar package.
- Repeatable read and serializable — after read committed holds under
concurrency.
- Backup and restore — RocksDB checkpoints versus a logical dump in
the pg_dump shape; both plausible, neither decided.
- `Bytes` foreign returns — the out-parameter rule covers every
arc-one read; a return position waits for an API that truly needs one.
- Range scans over an index — the v0 index key is exact-prefix capable,
not order-preserving; the comparison encoding and the planner's range
nodes wait for a later planner milestone. The corpus pins the current
shape.
- Streaming scans — v0 materializes rows; a cursor-shaped record API
waits for a plan node that consumes one.
- The rest of SELECT — joins, aggregates, `GROUP BY`/`HAVING`, `ORDER
BY`/`LIMIT`, subqueries, `DISTINCT`, and `CAST` — the v0 engine
refuses them, and the corpus pins each refusal; a later breadth
milestone lands them.
- The record API's non-transactional writes — the binding's plain
`write` leaves RocksDB's `sync` off; the transaction's COMMIT calls
`write_sync`. A direct record-API caller that needs durability takes the
transaction.
- Arc two's milestone cut.
