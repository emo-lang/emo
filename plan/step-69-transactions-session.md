# Step 69 — Transactions and the session plane

**Milestone:** M32 · **Prereq:** steps 66–68 (the record layer, the
engine) · **Status:** landed 2026-11-12

## Why this step exists

M31 executes one statement at a time, each in its own WriteBatch. A
database needs transactions: BEGIN/COMMIT/ROLLBACK, a write buffer that
commits atomically, reads at a snapshot so a session does not see
uncommitted work, and a lock manager that makes two sessions' writes
serialize and detects the deadlock. This step is that plane, with the
sessions as Emo processes and the locks as an Emo process.

## Decisions settled here (the trail)

- **The session actor owns the transaction.** Each session has its own
  `record.Txn`: one RocksDB WriteBatch for its writes, one snapshot per
  statement (read committed), and the rowid counters it publishes only
  at commit. The `sql` package grows `BEGIN`/`COMMIT`/`ROLLBACK`; the
  engine's dispatch moves the session's state. COMMIT writes the batch
  with `write_sync`, so the WAL fsyncs before the answer; the record
  API's plain (non-transactional) writes keep the old unsynced path.
- **The pending overlay is the transaction's own read.** The WriteBatch
  is invisible to RocksDB reads until commit, so the Txn keeps a
  pending map (slot + hex key) of its puts/deletes. Reads see the
  pending entry first and the statement snapshot behind it; a table or
  index scan overlays the pending entries on the snapshot iterator,
  with a pending put replacing a snapshot value, a pending delete
  dropping the key, and pending-only keys appended in insertion order.
- **Rowids and the catalog ride the transaction.** The Txn allocates
  rowids from a per-transaction counter initialized from the Table; the
  insert writes the table definition with the txn's counter into the
  batch; commit publishes the final counter to the Table, rollback
  leaves it untouched. The catalog's next-rowid change is therefore one
  atomic write with the row.
- **Read committed is per statement.** `Txn.begin_statement` closes the
  previous snapshot and takes a fresh one; a session sees another
  session's committed work at its next statement, not at its next
  transaction.
- **Locks are table-level in v0.** A write statement acquires the
  table's write lock; the session holds it until COMMIT/ROLLBACK, and
  autocommit releases after the statement. Row-level locks are finer
  than v0 needs and the table lock is the correct coarse form of the
  same write-write conflict.
- **The lock manager is a process; blocking is a receive.** The manager
  owns `owners` (table → session id), a FIFO of waiters per table, and
  the wait-for map (session id → the table it waits for). A grant is a
  reply; a blocked acquire parks in `receive`. A release grants the
  first waiter. An acquire that closes a wait-for cycle answers the
  requester `40P01: deadlock detected` and removes it from the queue;
  the aborted session's engine rolls back and releases its locks, which
  lets the other side proceed.
- **A failed statement aborts the transaction.** PostgreSQL's rule: any
  statement error inside BEGIN (a deadlock included) rolls the
  transaction back and releases the locks; the session is idle again.
- **DDL is autocommit.** `CREATE TABLE` inside a transaction answers
  `0A000`; the DDL's own catalog writes are not part of a session's
  batch in v0.
- **One Store, many sessions.** The sessions share one opened
  `record.Store` (one RocksDB handle) and each has its own Engine over
  it; the shared Tables' counters are safe because the table locks
  serialize the writes. Two RocksDB instances on the same directory are
  not a shape v0 opens.
- **The demo's actors are deterministic.** The coordinator sends the
  statements in a fixed order and parks on the replies; the manager and
  the sessions never print. The goldens pin the read-committed values,
  the blocking order (B's UPDATE reply after A's COMMIT), and the
  deadlock (B's 40P01, then A's blocked UPDATE and COMMIT).

## Tasks

- [x] **T69.1** — This file and the Step 69 section EN+zh.
- [x] **T69.2** — The `sql` package's `BEGIN`/`COMMIT`/`ROLLBACK`
      (`StmtKind`, the three classes, the dispatch), the two examples'
      new cases, and the five-target re-run.
- [x] **T69.3** — The record `Txn`: the batch, the per-statement
      snapshot, the pending overlay, the rowid counters, the tx read/
      write methods on `Table`, and commit/rollback.
- [x] **T69.4** — The engine's transaction state: `BEGIN`/`COMMIT`/
      `ROLLBACK`, the autocommit transaction per statement, the
      per-statement snapshot, and the error-path abort.
- [x] **T69.5** — The `LockClient` interface, the engine's table-lock
      acquire/release, and the held-lock bookkeeping.
- [x] **T69.6** — The lock-manager process: owners, FIFO waiters, the
      wait-for graph, deadlock detection, and the release grant.
- [x] **T69.7** — The session process and `RemoteLocks`: the shared
      Store, the per-session engine, and the blocking acquire.
- [x] **T69.8** — `projects/emo-db/txn_demo`: the three scenarios (read
      committed, write-write blocking, deadlock) and `expected.txt`.
- [x] **T69.9** — The gate: the fourth demo's build/run three times and
      the build-failure guards that stop a stale binary from passing.
- [x] **T69.10** — The docs EN+zh: the project README, the `sql` docs
      for the transaction statements, the design record's lock
      granularity and DDL notes.
- [x] **T69.11** — The close-out: TASKS, the plan README, CHECK.md,
      `dune build`/`@fmt`.

## Evidence

- `projects/emo-db/check.sh` green with four goldens (35 checks): the
  binding/record/engine type-check; the KV, record, engine, and
  transaction demos build and run three times byte-identical; the
  E3009/E5007 pins stay green.
- The binding's new `Batch.write_sync` (the WAL fsync) is the
  transaction's COMMIT path; the demos' outputs are unchanged.
- The transaction demo's 50-line output: the read-committed pair
  (95.5 before A's COMMIT, 1.0 after), the blocking pair (B's UPDATE
  reply after A's COMMIT), and the deadlock (B's `40P01`, A's blocked
  UPDATE then COMMIT).
- `examples/sql_demo`/`sql_edge` re-run byte-identically on the
  interpreter, c, OCaml, TypeScript, wasm, and BEAM after the
  transaction statements joined the parser.
- `dune build`/`@fmt` green; the full `dune runtest` waits for the next
  requested run.

## Found on the way

- **The c target cannot compare Pids.** `owner == who` on a `Pid` fell
  to the emitter's "this expression form" refusal, and `Pid.to_string()`
  is not lowered ("`Pid` values in a string yet"). The manager keys
  sessions by an explicit `Int64` id and keeps the Pid only for the
  reply address; the session's RemoteLocks carries its id.
- **The c target's receive cannot carry a value out of two branches**
  (`const x = receive { ... }` is not a form; a two-branch receive whose
  branches `return` is the recorded `__ret` redefinition). The
  transaction demo uses a single-branch receive in each place: the
  manager's uniform 4-tuple message, the session loop, `ask`/`await`'s
  3-tuple reply, and RemoteLocks' one branch with two returns inside it.
- **The initial `iter_at` helper leaked an iterator per scan.** The
  first `scan_prefix` created `cf.iter()` and then replaced it with
  `cf.iter_at(snap)` without closing the first; the DB's live-handle
  count reached 13 and `Db.close` refused. The helper now chooses one
  iterator and the engine's M31 golden still passes unchanged.
- **The c compiler warns `-Winfinite-recursion` on the manager and
  session loops** — the intentional actor loops; the build succeeds and
  the warnings are inherent to a process that never returns.
- **The gate could pass on a stale binary.** A failed demo build left
  the previous run's binary in `$OUT`, and the run steps compared that
  binary's output. The gate now exits on a failed build before the
  runs.

## Open, deliberately

- **Row-level locks** — table-level is the v0 conflict unit; row locks
  arrive with a workload that needs them.
- **Deadlock victim selection** — the requester that closes the cycle;
  PostgreSQL's cost-based choice waits.
- **DDL inside a transaction** — `0A000`; the catalog's table creation
  would ride the txn's batch in a later step.
- **Serializable and repeatable read** — read committed is the v0
  level.
- **Lock timeouts and `55P03`** — a blocking acquire waits indefinitely
  unless the deadlock closes it.
- **Write skew and predicate locks** — read committed does not prevent
  them; the isolation ladder waits.
