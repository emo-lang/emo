# emo-db — the user's guide

emo-db is Emo's client-server SQL database: one PostgreSQL-dialect
surface — spoken over PostgreSQL's wire protocol, protocol v3 — over
two storage engines behind it, chosen per table (`STORE = ROW`, the
default, or `STORE = COLUMN`). This guide is the build-and-drive
manual: how to build the server, how to run the integration tests, and
how to work with the database through `psql`. The design record — what
was decided and why — lives in
[`docs/emo-db.md`](../../docs/emo-db.md); the deferred items are
indexed in [`docs/temp-emo-db.md`](../../docs/temp-emo-db.md).

Everything here is verified on macOS arm64 with Homebrew; the Linux
equivalents are noted inline.

## 1. Prerequisites

| Tool | Needed for | Install |
| --- | --- | --- |
| OCaml 5 + dune | building the Emo toolchain from source | `opam install ocaml dune` (or see the root README's install section) |
| pkg-config | resolving RocksDB and libpq | `brew install pkg-config` / `apt install pkg-config` |
| RocksDB (the C API) | the storage half — not optional | `brew install rocksdb` / `sudo apt install librocksdb-dev` |
| psql | driving the server (optional — the gate skips the psql phases without it) | `brew install postgresql@18` / `sudo apt install postgresql-client` |
| libpq through pkg-config | the standard `postgres` client's phase (optional) | ships with `postgresql@18`; Homebrew keg fallback is built into the gate |

Check RocksDB resolves before anything else:

```console
$ pkg-config --exists rocksdb && echo ok
ok
```

## 2. Build the Emo toolchain

The gate and every build below use the in-tree compiler binary by
default (`EMO` overrides it). From the repository root:

```console
$ dune build src/emo_cli/emo.exe
```

The binary lands at `_build/default/src/emo_cli/emo.exe`. The release
installer (`curl -fsSL https://www.emo-lang.cn/cdn/install.sh | sh`,
see the root README) installs a prebuilt `emo` — it works for general
use, but the in-tree build is the path the gate tests, so prefer it
for emo-db work.

## 3. Build emo-db

`projects/emo-db/check.sh` is the one-command build. It resolves
RocksDB, stages a local package registry (the project's `emo/rocksdb`,
`emo/record`, `emo/engine`, `emo/wire` beside the standard library's
`sql`/`float`/`net`/`os`/`file`/`postgres`), type-checks the four
packages, and builds every demo and server binary into
`.emo-build/check/`:

```console
$ cd projects/emo-db
$ ./check.sh
ok   the binding type-checks
...
ok   and names the missing target
```

76 checks green means the whole system is built and verified. The
binaries you will actually run:

| Binary | What it is |
| --- | --- |
| `.emo-build/check/wire_demo` | the server: an empty database, the PostgreSQL simple query path |
| `.emo-build/check/htap_demo` | the server with a seeded two-engine database (a row table and a column table) |
| `.emo-build/check/corpus_runner` | the SQL corpus's runner (141 cases) |
| `.emo-build/check/bench` | the benchmark workloads |

RocksDB is a build dependency, not an optional service: a machine
without it fails the gate with the install line rather than skipping.
`psql` and libpq are the opposite — the wire's client phases skip with
a `skip ...` line when their tool is missing.

A single package's binary can also be built by hand after the gate has
staged the registry once:

```console
$ cd wire_demo
$ EMO_REGISTRY=$PWD/../.emo-build/registry-* \
    ../../../_build/default/src/emo_cli/emo.exe build main.emo -o ../wire-server
```

## 4. Integration tests

The gate **is** the integration test suite — every phase drives real
binaries against real databases:

- **Five demos, three runs each, byte-identical** against their
  `expected.txt` (the KV binding, the record layer, the engine, the
  transaction plane, the column format).
- **The SQL corpus**: 141 cases in the SQLLogicTest spirit —
  statements with pinned command tags, queries with pinned rows, and
  errors with pinned `code: message` strings — executed against one
  fresh database, three byte-identical runs.
- **The bench smoke**: every benchmark mode runs and answers its
  count (times are never checked by the gate).
- **The wire phases**: a fresh server per phase; `psql` drives a
  multi-statement script (DDL, DML, a transaction, a SELECT), then an
  error script whose missing relation must stop the string; the
  standard library's `postgres` client drives the same script through
  libpq's simple path.
- **The two-engine phases**: one database holding a row table and a
  column table (1100 rows, across the block boundary); both clients
  update the row table and insert into the column table inside one
  `BEGIN`/`COMMIT`, then read the post-commit aggregates.
- **Two refusals pinned live**: the interpreter's E3009 on foreign
  bindings and a non-`c` target's E5007 at resolution.

Rerun it any time; three consecutive runs are the project's own
stability bar:

```console
$ ./check.sh && ./check.sh && ./check.sh
```

Two more test surfaces:

```console
$ ./bench/run.sh          # the measured numbers -> bench/results.md
```

The corpus alone (after the gate staged the registry):

```console
$ cd corpus_runner
$ ../.emo-build/check/corpus_runner ../corpus/*.test
ddl.test 6 cases
...
cases 141, failed 0
```

## 5. Run a server

Both servers take the same arguments — `port`, then the number of
sessions to serve (`0` = forever), then an optional ready-file path —
and both **reset their database at startup**: the directory under
`.emo-build/` is destroyed and recreated, so every start is a fresh
database. Stop a server with Ctrl-C. Run them from their own
directory (the database lives at `.emo-build/<mode>-db` relative to
the working directory).

The empty server (everything you create is yours):

```console
$ cd wire_demo
$ ../.emo-build/check/wire_demo 5433 0
listening
```

The seeded two-engine server (comes with `items`, a row table, and
`cold_items`, a column table with 1100 rows):

```console
$ cd htap_demo
$ ../.emo-build/check/htap_demo 5433 0
listening
```

Pass `0` as the port to bind an ephemeral one and write it to a file
(`../wire-server 0 1 /tmp/port` — the gate's own trick); pass a
positive session count to stop the server after that many connections
end. A fixed port and `0` sessions is the manual shape.

## 6. Drive it with psql

Connect — authentication is trust, so any user, database, and password
are accepted (the server reports your startup user back as
`session_authorization`). Always name the host; the server listens on
TCP only:

```console
$ psql "host=127.0.0.1 port=5433 user=emo dbname=emo" -X
emodb=>
```

`-X` skips your `psqlrc`. For scripts, add `-v ON_ERROR_STOP=1` so a
failure stops the file instead of rolling on.

### DDL — a row table

The v0 types are `INTEGER`, `BIGINT`, `REAL`, `DOUBLE PRECISION`,
`TEXT`, `VARCHAR(n)`, `BOOLEAN`, and `BYTEA` — exact spellings, no
aliases. Column-level `NOT NULL` and `PRIMARY KEY` are supported (a
primary key builds a unique index `<table>_pkey`):

```sql
CREATE TABLE users (
  id    BIGINT NOT NULL PRIMARY KEY,
  name  TEXT NOT NULL,
  score DOUBLE PRECISION,
  handle VARCHAR(12)
);
```

### DDL — a column table

`STORE = COLUMN` names the storage. A column table carries no indexes
— `PRIMARY KEY` and secondary indexes answer
`0A000: column-store tables carry no primary key in v0` — and it is
insert-only:

```sql
CREATE TABLE events (
  id    BIGINT,
  kind  TEXT,
  value DOUBLE PRECISION
) STORE = COLUMN;
```

### DML

```sql
INSERT INTO users (id, name, score) VALUES (1, 'Ada', 9.5), (2, 'Grace', 3.25);
INSERT INTO events (id, kind, value) VALUES (1, 'login', 1.0), (2, 'click', 2.0);
UPDATE users SET score = 10.0 WHERE id = 1;
DELETE FROM users WHERE id = 2;
```

An omitted column fills with NULL; the values coerce by widening
(INTEGER → BIGINT → REAL → DOUBLE PRECISION) but never narrow —
`42804` names the column and both types otherwise. Rows come back in
insertion order: the engines have no `ORDER BY` yet, so do not rely on
any other order.

### SELECT

Single-table only, with a projection, aliases, and a WHERE over
comparisons, `AND`/`OR`/`NOT`, arithmetic, text `||`, `IS`, `IN`,
`BETWEEN`, `LIKE`, and `CASE`. An equality between an indexed column
and a constant becomes an index scan; everything else is a scan:

```sql
SELECT * FROM users;
SELECT id, name FROM users WHERE score > 5.0;
```

On a column table the executor reads blocks, and the global aggregates
live there — `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`:

```sql
SELECT count(*), sum(value), avg(value), min(id), max(kind) FROM events;
SELECT count(*) FROM events WHERE kind = 'login';
```

The aggregate rules worth knowing: `sum` answers BIGINT over
integer/bigint and DOUBLE PRECISION over real/double; `avg` answers
DOUBLE PRECISION; over zero rows `count` answers 0 and the rest answer
NULL. The select list is all plain items or all aggregate calls — a
mixture answers `42803`. On a **row** table, aggregate calls are still
refused (`0A000: function calls are not supported in v0`) — the
shared-breadth work has not reached the row engine.

### Transactions

```sql
BEGIN;
UPDATE users SET score = 11.0 WHERE id = 1;
INSERT INTO events (id, kind, value) VALUES (4, 'buy', 8.0);
COMMIT;
```

One transaction can touch both engines — the row table's UPDATE and
the column table's INSERT commit in one atomic, fsynced write. Reads
inside a transaction are read committed (a snapshot per statement).
One difference from PostgreSQL to know: a failed statement aborts the
transaction immediately and releases its locks, and the wire reports
the session idle (`I`) — there is no failed-block state that only
ROLLBACK leaves.

### A full worked session

```console
$ psql "host=127.0.0.1 port=5433 user=emo dbname=emo" -X -A -t \
    -c "create table users (id bigint not null primary key, name text not null, score double precision);
        insert into users (id, name, score) values (1, 'Ada', 9.5), (2, 'Grace', 3.25);
        select * from users;
        update users set score = 10.0 where id = 1;
        select id, name, score from users where score > 5.0;
        delete from users where id = 2"
CREATE TABLE
INSERT 0 2
1|Ada|9.5
2|Grace|3.25
UPDATE 1
1|Ada|10.0
DELETE 1
```

(`-A -t` is psql's unaligned, tuples-only output — the shape the
gate's goldens pin. Drop it for the aligned table view.)

Errors look like PostgreSQL's:

```console
$ psql ... -c "select * from missing"
ERROR:  relation "missing" does not exist
$ psql ... -c "select * from events join users on events.id = users.id"
ERROR:  joins and subqueries in FROM are not supported in v0
```

## 7. The supported surface at a glance

| Area | Works | Answers `0A000` (or the named code) |
| --- | --- | --- |
| Types | the eight v0 types, `NOT NULL`, `PRIMARY KEY` (row tables), `STORE = COLUMN` | type aliases, length-less `VARCHAR` |
| INSERT | multi-row, optional column list, NULL fill, widening coercion | `INSERT … SELECT`, `ON CONFLICT`, `RETURNING` |
| UPDATE/DELETE | row tables, optional WHERE | column tables (insert-only) |
| SELECT | single table, projection, WHERE, column-table aggregates | joins, subqueries, `GROUP BY`/`HAVING`, `ORDER BY`, `LIMIT`/`OFFSET`, `DISTINCT`, `CAST`, row-table aggregates |
| Transactions | `BEGIN`/`COMMIT`/`ROLLBACK`, cross-engine writes, read committed | transactional DDL |
| Wire | psql and libpq's simple path, multi-statement strings, trust auth | the extended protocol (`Parse`/`Bind` — parameterized statements), scram-sha-256, SSL |
| psql | SQL statements, `-c`, `-f` | catalog meta-commands (`\d`, `\dt`, `\l` — they query `pg_catalog`, which does not exist here) |

## 8. Troubleshooting

- **`pkg-config` cannot find RocksDB** — the gate tries Homebrew's
  kegs itself; otherwise export
  `PKG_CONFIG_PATH=/opt/homebrew/opt/rocksdb/lib/pkgconfig` (macOS) or
  install `librocksdb-dev` (Debian/Ubuntu).
- **`connection to server ... failed: Connection refused`** — the
  server is not running, or the port differs. The server prints
  `listening` once its port is bound; run it in the foreground to see.
- **`psql: error: invalid integer value ... for connection option "port"`**
  — the conninfo was quoted wrong; pass the whole conninfo string as
  one argument, as in the examples.
- **`42P07: relation "users" already exists`** — the table is still
  there from earlier in the session; the server's database resets only
  at startup.
- **The gate prints `skip psql` / `skip postgres client`** — the tool
  is missing; the phases it gates are skipped, everything else still
  runs. Install psql (and libpq) to exercise them.
- **A stale build** — `dune build src/emo_cli/emo.exe` rebuilds the
  toolchain; `./check.sh` rebuilds every binary from the current
  sources (its registry is named by the sources' content, so it never
  serves a stale package).
