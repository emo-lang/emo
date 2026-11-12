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
drivers default to), scram-sha-256, SSL.

**D9 — The ladder.** Arc one is milestones M28–M34, one milestone per
step, steps 65 through 71. The exit criteria live in `docs/TASKS.md`;
the ladder's shape:

| Milestone | Steps | Lands |
| --- | --- | --- |
| M28 — The RocksDB half | 65 | The project scaffold and the C shim, with the `Bytes` borrowed view (D10): open/close, get/put/delete, WriteBatch, iterators, snapshots, column families. |
| M29 — The record layer | 66 | The catalog column family, the row encoding, rowid allocation, and secondary indexes as one column family per index — rows in one shared `data` family keyed by table oid + rowid. |
| M30 — The SQL front-end's DML and DDL | 67 | `sql` grows CREATE TABLE / INSERT / UPDATE / DELETE beside SELECT — pure Emo, byte-identical on every target. |
| M31 — The planner and executor | 68 | The first full SQL-to-rows path: plan nodes (scan/filter/project, insert/update/delete), expression evaluation over the record layer, an embedded test face. The v0 SELECT is single-table (projection, WHERE, an equality index scan); joins, aggregates, ORDER BY/LIMIT, and subqueries wait for M34. |
| M32 — Transactions and the session plane | 69 | BEGIN/COMMIT/ROLLBACK, read committed on per-statement snapshots, the Emo lock manager. |
| M33 — The wire | 70 | PG protocol v3, simple path; psql end-to-end and the `postgres` client connecting. |
| M34 — Conformance and documentation | 71 | The SQL corpus, the measured-performance table, docs EN+zh. |

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

## Arc two — the OLAP shape (direction decided, cut open)

- Columnar v1 rides RocksDB too: one column family per column, column
blocks as values. The single storage dependency holds for both arcs;
a Parquet-like segment format of our own stays a decision that
performance evidence earns later.
- Vectorized expression evaluation over column batches; scans pruned
by block-level min/max statistics.
- `CREATE TABLE ... STORE = COLUMN` joins the catalog; the planner
routes by the table's storage. The HTAP door opens here.
- The language gap this arc reopens: binary file IO beyond RocksDB
(`os`'s Bytes-shaped fd surface). By then the need is shared with
every Emo program that moves binary data — exactly how the assessment
said the gap should close.

The arc's milestone cut is written when arc one's planner exists to
plug into — not before.

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
nodes wait for M34's conformance breadth.
- Streaming scans — v0 materializes rows; a cursor-shaped record API
waits for a plan node that consumes one.
- The rest of SELECT — joins, aggregates, `GROUP BY`/`HAVING`, `ORDER
BY`/`LIMIT`, subqueries, `DISTINCT`, and `CAST` — the v0 engine
refuses them; they land with M34's conformance breadth.
- The commit's durability knob — the binding's plain write path leaves
RocksDB's `sync` off; M32's COMMIT is where the flag finds its
consumer.
- Arc two's milestone cut.
