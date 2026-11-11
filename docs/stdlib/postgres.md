# The `postgres` Package

The standard library's PostgreSQL client: a direct-style binding over
libpq, PostgreSQL's own C client library. The calls are `foreign def`s
against a small C shim the package carries in its own tree, and libpq
is resolved by the manifest's `pkg_config` field — pkg-config answers
the include path for the shim and the `-lpq` for the link. Consuming
the package is plain `require`, with no `--cclib` and nothing to
install beyond the platform's libpq (on Debian and friends,
`libpq-dev`; on Homebrew, `libpq` or `postgresql@18` with its
pkgconfig directory on `PKG_CONFIG_PATH`). It targets PostgreSQL 18's
libpq and speaks to any server the wire protocol carries — 18.6 is
simply what it was built against.

The package declares `targets = ["c"]` — its calls are foreign code,
which the interpreter refuses with E3009 and the other targets refuse
at resolution or build time. `emo run` cannot execute a program that
touches it; build with `emo build` (the default target is `c`).

## Using the package

```emo
require "postgres"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "postgres"` needs
`"postgres" = "0.1.0"` in the manifest's `deps` block. The package
declares the `c` target — it carries native code, so only the `c`
target can build it.

## Errors

Following the standard library's convention, expected failures are
values: `connect`, `exec`, and `query` answer `(R.ok, ...)` or
`(R.error, reason)`, the reason a `String` beginning `postgres: ` that
carries the server's own one-line message and, for a failed statement,
its SQLSTATE:

```emo
postgres: query: relation "no_such_table" does not exist (sqlstate 42P01)
postgres: connect: connection to server at "localhost" (127.0.0.1),
port 5432 failed: Connection refused
```

A server that is down is a value, and so is a constraint the data broke
(`23505` for a unique violation) — both are ordinary `(R.error, ...)`
branches to match on, not raises. Only contract violations raise:
reading outside `Rows`, reading a `Rows` after `finish()`, touching a
`Conn` after `close()`, running a statement through the wrong door
(`exec` refuses a statement that returned rows, `query` refuses one
that produced no result set), or a typed read (`i64`/`f64`/`bool`) of
text that is not one.

## Connecting

```emo
def connect(options ConnOptions) (R, Conn)
def connect_info(info String) (R, Conn)
def options() ConnOptions
```

`connect` is the plain path: start from `postgres.options()`, set what
the connection needs with the `with_*` builders, and hand it over.

```emo
class ConnOptions {
  def with_host(host String) ConnOptions
  def with_port(port Int64) ConnOptions
  def with_database(database String) ConnOptions
  def with_user(user String) ConnOptions
  def with_password(password String) ConnOptions
  def with_connect_timeout(connect_timeout Float64) ConnOptions
  def info() String
}
```

Every field left unset falls to libpq's own default — the local unix
socket, the operating system's user, the database named after the
user. The builders return a fresh options; nothing mutates.
`with_connect_timeout` bounds the seconds libpq may spend reaching the
server (0.0, the default, leaves the wait unbounded).

`connect_info` is the raw path: a libpq conninfo string passed through
untouched, for the keywords the options do not name — `sslmode`,
`application_name`, a service file entry, and the rest:

```emo
const (R.ok, conn) = postgres.connect_info(
  "host=db.internal sslmode=verify-full dbname=shop user=ada")
```

A refused connection — wrong port, wrong password, unknown database —
answers `(R.error, reason)` carrying libpq's own message. `close()`
when done; the server sees the socket close and rolls back any
transaction left open.

## Running SQL

```emo
class Param {
  def stage(stg Int64, i Int64) Void   // the package's own machinery
}

def text(v String) Param
def i64(v Int64) Param
def f64(v Float64) Param
def bool(v Bool) Param
def none() Param

class Conn {
  def exec(sql String, params Array[Param]) (R, Int64)
  def query(sql String, params Array[Param]) (R, Rows)
  def close() Void
}
```

Every statement runs through libpq's `PQexecParams` with `$1`, `$2`,
... placeholders, the values supplied as `Param` values in the order
the array carries them. `postgres.i64(18)` arrives as `18`,
`postgres.f64(1.5)` as its round-tripping decimal, `postgres.bool(b)`
as `true`/`false`, `postgres.none()` as SQL NULL — not the empty
string, not zero. The server infers each parameter's type from the
statement, so `$1` compares honestly against an `integer` column and
against a `text` column alike.

```emo
const (R.ok, n) = conn.exec(
  "insert into users (name, age) values ($1, $2)",
  [postgres.text("ada"), postgres.i64(36)])
```

`exec` answers the count the server reports — rows inserted, updated,
or deleted; a command with no count (`CREATE TABLE`, most DDL) answers
0. `PQexecParams` carries exactly one statement: no semicolon batches,
the protocol's own rule. `query` answers the rows a `SELECT` (or a
`RETURNING`) produced.

The two doors check each other: a statement that returned rows refuses
`exec` ("the statement returned rows; query reads them"), and one that
produced no result set refuses `query` ("exec runs it"). The wrong
door is a bug in the calling program, and the refusal names it.

## Reading rows

```emo
class Rows {
  def count() Int64
  def columns() Int64
  def name(c Int64) String
  def index_of(wanted String) Int64
  def text(r Int64, c Int64) String
  def i64(r Int64, c Int64) Int64
  def f64(r Int64, c Int64) Float64
  def bool(r Int64, c Int64) Bool
  def is_null(r Int64, c Int64) Bool
  def finish() Void
}
```

Rows read by `(row, column)`, both **0-based** (libpq's indexing). The
typed readers check what the server actually sent: `i64` parses the
whole cell as an integer — text that is not one, or one past the
`Int64` range, raises and names the column; `f64` refuses overflow of
binary64; `bool` reads the server's `t`/`f` and the literal spellings
it accepts (`true`/`false`, `yes`/`no`, `1`/`0`). A `NUMERIC` too wide
for either width is not silently narrowed — `text` carries it, and a
wider numeric type is a future width's read.

`text` answers the cell's bytes as the server sent them; a SQL NULL
reads as `""`, and `is_null` tells the two apart:

```emo
var r = 0
while r < rows.count() {
  if rows.is_null(r, rows.index_of("deleted_at")) {
    println("still active")
  }
  r = r + 1
}
```

`name(c)` is the column's name as the server reported it;
`index_of(wanted)` is the first column carrying that name, `-1` when
none does (a result can carry two columns of one name; the first
wins). `finish()` releases the rows — libpq's `PQclear` — and every
read after it raises; until then the rows stay readable in any order,
as many times as the program wants.

## Boundaries and limitations

Strings cross the C boundary NUL-terminated: a `String` carrying an
embedded NUL truncates there, in both directions. Statements travel in
PostgreSQL's text format — binary parameters, `COPY`, `LISTEN`/
`NOTIFY`, cursors, and prepared statements reused across calls are
not in this version. One connection runs one statement at a time (the
wire protocol's shape), and a call blocks until the server answers:
concurrent work wants two connections, or a process per connection
riding the scheduler. Transaction control is plain SQL — `exec` a
`begin`, `commit`, or `rollback` like any other statement; the server
rolls back whatever a closed connection left open. The package
assumes the server's `client_encoding` is UTF-8, which is every
modern deployment's default.

## Example

```emo
require "postgres"

const local = postgres.options().with_host("localhost").with_port(5432)
const (R.ok, conn) = postgres.connect(local.with_database("postgres"))

const (R.ok, n) = conn.exec(
  "insert into users (name, age) values ($1, $2)",
  [postgres.text("ada"), postgres.i64(36)])
println("inserted ${n}")

const (R.ok, rows) = conn.query(
  "select id, name from users where age > $1 order by id",
  [postgres.i64(30)])
var r = 0
while r < rows.count() {
  println("row ${rows.i64(r, 0)}: ${rows.text(r, 1)}")
  r = r + 1
}
rows.finish()

conn.close()
```

The full worked demo — DDL through `exec`, writes of every parameter
kind including SQL NULL, typed reads with a by-name lookup, the error
branch — is `examples/postgres_demo`, which runs against a live
server on `localhost:5432`.
