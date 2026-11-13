# Step 70 — The wire

**Milestone:** M33 · **Prereq:** steps 66–69 (the record layer, the SQL
front-end, the engine, the session plane) · **Status:** landed
2026-11-12

## Why this step exists

The engine answers SQL as a library; the product is a server. This step
is the door every PostgreSQL client already knocks on: protocol v3's
simple query path — startup, the query cycle, the result stream, errors
— so psql and the standard library's `postgres` client connect without
a line of client-specific code.

## Decisions to settle here

- **The splitter reuses the lexer's token stream.** The wire receives a
  Query string that may hold several statements; `sql.parse` refuses
  more than one. `sql.split` lexes once and cuts at the lexer's own
  `t_semi` tokens, so quotes, doubled quotes, `--` comments, and
  `/* */` comments follow exactly the parser's rules. A lexer error is
  the split's error (an unterminated string stays a 42601, not a
  silently-cut statement). Empty pieces are dropped; a string with no
  statements is the empty query.
- **RowDescription needs types, so `Result` carries them.** The engine
  already types every projection expression; `Result` gains `types`,
  filled from `pr.exprs[i].result_type()`. Commands carry none. The
  wire maps `ValType` to PG's OIDs (23, 20, 700, 701, 25, 1043, 16, 17;
  `null_t` reads as TEXT) and sends text format everywhere.
- **The v0 catalog reports a compatibility level.** `server_version`
  is `16.4`, psql's parser reads a real number, and the product's own
  version lives in the parameter status list conceptually but not in
  the number. `server_encoding`/`client_encoding` are UTF8, DateStyle
  is ISO/MDY, TimeZone UTC, integer_datetimes on,
  standard_conforming_strings on.
- **Trust authentication, explicitly.** Startup answers
  AuthenticationOk without asking for a user check; the parameters are
  read (user, database, application_name) but authentication policy is
  a later milestone's work. SSLRequest and GSSENCRequest answer the
  single byte `N` and the server rereads the startup message;
  CancelRequest closes the connection (there is no cancel machinery).
- **A failed statement stops the string, and the transaction is
  already clean.** PostgreSQL marks a transaction failed (`E`) and
  waits for ROLLBACK; M32's engine aborts the transaction on any
  statement error and releases its locks, so ReadyForQuery reports `I`
  and the session is usable immediately. The difference is deliberate
  and documented: the wire reports the state the engine actually has,
  never a state a client would have to roll back out of.
- **Each connection is an actor with its own Engine over the shared
  Store.** The server opens one Store; every session builds an
  `Engine` over it with `RemoteLocks` keyed by a monotonic session id,
  so the table locks of Step 69 arbitrate across connections. The lock
  manager and `RemoteLocks` move from `txn_demo` into the engine
  package — the demo keeps its golden, the server gains the same
  machinery without a second copy. A session that ends without COMMIT
  aborts its transaction and releases its locks (`Engine.end_session`,
  which leaves the shared Store open).
- **The server stops after N connections when told to.** The demo's
  `max_connections` argument lets the gate run a finite server, wait
  for its exit, and compare output without killing a process. Zero
  means "serve forever". The bound port is written to a ready file, so
  the gate learns an ephemeral port without a sleep loop; the demo's
  own stdout stays static.
- **The `postgres` client gains the simple path for zero parameters.**
  `PQexecParams` is the extended protocol, which v0 does not speak;
  `PQexec` is the simple path. The shim routes an empty parameter
  array to `PQexec` and keeps `PQexecParams` for real parameters.
  Against a real PostgreSQL server the answers are unchanged; against
  emo-db, the zero-parameter half works and a parameterized statement
  fails honestly (the server answers 0A000 for the extended protocol's
  messages).

## Tasks

- [x] **T70.1** — This file and the Step 70 section EN+zh.
- [x] **T70.2** — `sql.split` over the lexer's tokens, the two
      examples' cases, the six-path re-run.
- [x] **T70.3** — `Result.types`; the lock manager and `RemoteLocks`
      in `emo/engine`; `txn_demo` re-pointed, its golden unchanged.
- [x] **T70.4** — The `postgres` shim's zero-parameter `PQexec`.
- [x] **T70.5** — `projects/emo-db/wire`: the byte buffer and the
      protocol's message forms.
- [x] **T70.6** — The query cycle and the error path.
- [x] **T70.7** — The session actor, the accept loop, and the lock
      manager wiring.
- [x] **T70.8** — `wire_demo` and `wire_client` with their goldens.
- [x] **T70.9** — The gate's two phases behind the `psql`/`libpq`
      probes.
- [x] **T70.10** — The docs EN+zh.
- [x] **T70.11** — The close-out.

## Evidence

- `projects/emo-db/check.sh` green three times with 49 checks: the four
  package checks (binding, record, engine, wire), six demo builds, the
  five three-run goldens, and the two wire phases.
- **psql, phase A:** one multi-statement Query creates the table, inserts
  two rows, selects them, opens a transaction, updates and selects
  inside it, and commits — psql prints
  `CREATE TABLE`, `INSERT 0 2`, the two `|`-separated rows, `BEGIN`,
  `UPDATE 1`, the updated row, `COMMIT`. A second connection's
  `select id ...; select * from missing; select id ...` prints the first
  row, stops at the ErrorResponse (`ERROR:  relation "missing" does not
  exist`, exit 1), and never runs the third statement.
- **libpq, phase B:** the standard library's `postgres` client runs the
  same SQL with zero parameters through `PQexec`; its golden carries
  `CREATE TABLE`'s 0, `INSERT`'s 2, the rows with `t`/`null`, the
  UPDATE 1, the in-transaction row, `COMMIT`'s 0, the 42P01 message
  from `select * from missing`, and a select after the error.
- The server's own stdout is `listening`/`done` in both phases; the
  bound port travels through the ready file, so no sleep loop guesses.
- `sql_demo`/`sql_edge` (with the new `split` cases) are byte-identical
  on the interpreter, c, OCaml, TypeScript, wasm, and BEAM; `txn_demo`
  is unchanged after the lock manager moved to `engine.locks`;
  `dune build`/`@fmt` green.

## Found on the way

- **The BEAM emitter's `__inst_recv` temp was not in `beam_temps`.** A
  `while` loop before an interface `.to_string()` made the lifted loop
  function take the not-yet-bound receiver temp as a parameter, and erlc
  answered `unbound variable '___inst_recv...' in main/0`. Adding
  `__inst_recv` to the temps list fixed the class; the new `sql_demo`
  split loop was the repro.
- **A package that imports `record` cannot own an `internal/`
  directory.** Both register a top-level `internal` module, and record's
  `internal.codec` then resolves to the importer's package (E5008). The
  wire package keeps `buf` and `protocol` as root children instead.
- **`def main()` is a function, not an entry.** The c target runs the
  file's top-level statements; a program with a top-level `const` and a
  `def main()` runs only the consts. The demos call `main()` at the end,
  the repo's convention.
- **`store.close()` is Void.** A `case store.close()` is a tuple pattern
  against Void (E4013); the server closes with a bare call.
- **The first `select 1` phase-2 probe hit the engine's no-FROM
  refusal** (joins and multiple tables are `0A000`); the script's
  selects all name a table, which is also a truer test of the wire.
