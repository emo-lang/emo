# emo-db — the deferred items, as a working index

Written 2026-11-13. Temporary by name: everything the design record
(`docs/emo-db.md`) and the step records (`plan/step-65` through
`plan/step-74`) deliberately left open after arc one (M28–M34, the row
store behind the wire) and arc two (M35–M37, the column engine). Each
item states what the shipped behavior is, why it waits, and what would
let it land. `docs/emo-db.md` stays the source of truth — when an item
lands it moves there, and when this file is triaged it folds back or
goes away.

Items are grouped by where the work would land, not by the step that
named them. A group's source step records are noted at its head.

## 1. The SQL surface's breadth

*Sources: the design record's open items; `plan/step-67`'s deliberate
opens; `plan/step-73`.*

1.1 **The rest of SELECT, for both engines.** Joins, subqueries,
`GROUP BY`/`HAVING`, `ORDER BY`/`LIMIT`, `DISTINCT`, and `CAST` answer
`0A000` today, and the corpus pins each refusal. They land in a shared
front-end breadth milestone — one implementation, both engines inherit.
The cheapest first pair is `ORDER BY`/`LIMIT` (the column engine's
blocks are already ordered; the row engine needs a sort node).

1.2 **The row engine's aggregates.** COUNT, SUM, AVG, MIN, MAX exist
only on column tables; a row table's function call still answers
`0A000: function calls are not supported in v0`. The column engine's
machinery (`classify_select`, `resolve_aggregate`, `AggState`) is
storage-agnostic in shape — the shared breadth milestone ports it to
the row engine's scan.

1.3 **Aggregates are whole select items only.** An aggregate nested in
a larger expression (`sum(id) + 1`) falls to the function refusal, and
`DISTINCT` aggregates refuse `0A000`. Both widen when the breadth
milestone lands; the corpus pins today's shape.

1.4 **The DML/DDL tails the parser refuses by name** (`plan/step-67`):
`INSERT … SELECT`, `ON CONFLICT`, `RETURNING`, table-level
`PRIMARY KEY`/`UNIQUE` and `CREATE INDEX` (the record layer's index
machinery exists; the SQL surface waits for the planner's index
selection), `DEFAULT`/`CHECK`/`REFERENCES` (constraints with runtime
semantics), and type aliases / length-less `VARCHAR` (a dialect
decision, not a mechanism).

1.5 **BYTEA has no SQL literal.** A bytea column takes NULL through
SQL today; a non-null bytea value needs the record API. An escape form
(`E'\\x…'` or `decode()`) is a parser decision.

## 2. The column store's deferred half

*Sources: the design record's arc-two deferrals; `plan/step-73`.*

2.1 **Block-level min/max statistics and pruning.** Blocks carry a row
count only; every scan reads every block. A stats sidecar (per block,
per column, numeric and text bounds) and the planner's skip rule are
the first performance step of the column arc's second half.

2.2 **Column-table indexes.** A column table carries no indexes —
`PRIMARY KEY` and secondary indexes refuse `0A000`, uniqueness is the
application's job, and the block scan is the access path. Indexes would
need the same CF machinery the row tables use, plus an update story
(see 2.3).

2.3 **Column UPDATE and DELETE.** The v0 column engine is insert-only;
both answer `0A000: column-store tables are insert-only in v0`. A
rewrite-in-block path (read the block, drop or replace the row, put it
back) is the natural shape, and the catalog's rowid counter already
exists.

2.4 **The batch expression evaluator.** The block is the batch unit,
but the per-row expressions are the shared typed evaluator over
block-materialized values. A per-block typed evaluator (column
operands, row-count semantics for the three-valued NULL logic) is the
named follow-up; the M34/37 measurements are its baseline.

## 3. The wire

*Sources: the design record's D8 and open items; `plan/step-70`'s
decisions; the M33 record.*

3.1 **The extended protocol** (`Parse`/`Bind`/`Describe`/`Execute`/
`Sync`). The simple path serves psql and libpq's zero-parameter route;
a parameterized statement (what most drivers default to) speaks the
extended protocol and fails honestly today. It lands when a driver
beyond psql and libpq's simple path demands it.

3.2 **scram-sha-256 and SSL.** Trust authentication only;
SSLRequest/GSSENCRequest are answered `N`. The `crypto` package already
holds the pieces; the work is the authentication state machine and a
TLS listener choice (`net`'s `listen_tls`).

3.3 **Cancel machinery.** A CancelRequest closes the connection
silently; BackendKeyData is written but no pid-keyed cancel walks the
sessions. Real cancel needs a session registry keyed by the key data.

3.4 **Per-connection deadlines.** A session blocks in `read` without a
timeout — a hung client parks a session (and its locks) forever. `net`'s
`set_timeout` and a session-level idle limit are the shape; the lock
manager would need the same timeout story as 3.5's.

## 4. Transactions and concurrency

*Sources: `plan/step-69`'s deliberate opens; the design record's open
items.*

4.1 **The failed-transaction state.** The wire reports ReadyForQuery
`I` after a statement error because the engine aborts and releases
immediately; PostgreSQL's `E` (a block only ROLLBACK leaves) waits for
a transaction model that keeps the failed block.

4.2 **Repeatable read and serializable.** Read committed (a snapshot
per statement) is the v0 level. RR is a snapshot per transaction plus
conflict detection; serializable adds the predicate story (see 4.6).

4.3 **Row-level locks.** Table-level is the v0 conflict unit; row locks
arrive with a workload that needs them (and probably with 2.3's
per-row column rewrites).

4.4 **Deadlock victim selection.** The requester that closes the
wait-for cycle is aborted today; PostgreSQL's cost-based choice waits.

4.5 **Lock timeouts and `55P03`.** A blocking acquire waits
indefinitely unless the deadlock closes it; a timeout parameter and the
SQLSTATE are a small, self-contained step.

4.6 **Write skew and predicate locks.** Read committed does not prevent
them; the isolation ladder in 4.2 owns this.

4.7 **DDL inside a transaction.** It refuses `0A000` and aborts the
block. The deferred half is the catalog's table creation riding the
transaction's batch (atomic with the transaction's rows) instead of
staying autocommit-only.

## 5. Types

*Sources: the design record's D7 and open items; the corpus's pinned
refusals.*

5.1 **NUMERIC** — waits on Int128 or a bignum in the language. SUM over
bigint would also want it (PG answers numeric; v0 accumulates in Int64,
so a wide SUM can overflow — pinned by decision, not by test).

5.2 **DATE/TIMESTAMP** — waits on a calendar package (a candidate
standalone stdlib package later).

5.3 **REAL's 4-byte narrowing.** REAL stores binary64 in v0; the
narrowing waits for a Float32 or a rounding routine. The visible face:
a float literal (double precision) refuses into a REAL column
(`42804`, corpus-pinned) — an integer literal is the v0 value form.

## 6. Storage, the record layer, and operations

*Sources: `plan/step-65` and `plan/step-66`'s deliberate opens; the
design record's open items.*

6.1 **Backup and restore.** RocksDB checkpoints versus a logical dump
in the pg_dump shape; both plausible, neither decided. The binary fd
surface (6.5) gates the checkpoint file story.

6.2 **Range scans over an index.** The v0 index key is exact-prefix
capable, not order-preserving; the comparison encoding and the
planner's range nodes wait for a planner milestone. The corpus pins
today's shape.

6.3 **Streaming scans and cursors.** v0 materializes rows (and whole
values); a cursor-shaped record API waits for a plan node that consumes
one.

6.4 **Values larger than memory.** A value is read fully into one
`Bytes`; streaming a value needs the binary file story and a consumer.

6.5 **`os`'s binary fd surface.** The language gap arc two reopened:
RocksDB is the only binary IO today. The segment format the arc-two
sketch named, checkpoint-based backup (6.1), and large-value
streaming (6.4) all wait on it.

6.6 **RocksDB knobs without consumers.** Column family drop, prefix
extractors, TTL, compaction tuning — none has an arc-one consumer. The
two-pass read's result slot waits on the same evidence (M34 measured
before any cache-shaped shim state).

6.7 **Multiple databases in one process.** The shim keeps one
last-error buffer and the package is written for one database; the
design is a single-node server. A second handle waits for a consumer.

6.8 **The record API's non-transactional writes.** The binding's plain
`write` leaves RocksDB's `sync` off; the transaction's COMMIT calls
`write_sync`. A direct record-API caller that needs durability takes
the transaction — the API could grow a `write_sync` of its own if a
caller appears.

## 7. Measurements not yet taken

*Sources: the design record's `Measured` section and honest costs;
`bench/results.md`.*

7.1 The wire's per-query latency (server + client, one connection).
7.2 Concurrent-session throughput and the lock manager's behavior at
    scale.
7.3 Tables larger than memory (the block cache's assumptions).
7.4 Crash-recovery timing (WAL replay after a kill).
7.5 The GC tail-latency question — the assessment's #4 — lands the day
    latency is measured at scale.

## 8. The language gaps that gate the above

| Gap | Gates |
| --- | --- |
| Int128 or a bignum | 5.1 (NUMERIC), wide SUM |
| A calendar package | 5.2 (DATE/TIMESTAMP) |
| `os`'s binary fd surface | 6.1 (checkpoint backup), 6.4 (large values), 6.5 (segment formats) |
| Float32 | 5.3 (REAL's narrowing) |

## What would let each land — the triage view

- **Evidence first:** 6.6 (shim knobs), 7.x (the measurements), 2.1
  (pruning needs the stats numbers).
- **Small, self-contained steps:** 4.5 (lock timeouts), 3.4
  (deadlines), 1.1's `ORDER BY`/`LIMIT` pair, 5.3 (Float32).
- **Decisions first:** 6.1 (checkpoint vs dump), 1.4's aliases
  (dialect), 6.5 (the fd surface's shape in `os`).
- **Workload-driven:** 4.3 (row locks), 2.2/2.3 (column indexes and
  rewrites), 3.1 (the extended protocol).
- **Language-driven:** 5.1, 5.2, and everything in section 8.
