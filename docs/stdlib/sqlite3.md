# The `sqlite3` Package

The standard library's database surface: a direct-style binding over
SQLite's prepared statement API. It is the standard library's first
native-binding package — the calls are `foreign def`s against a small C
shim the package carries in its own tree, and the system sqlite3
library is named by the manifest's `link` field. The build compiles the
shim and links the library by itself: consuming the package is plain
`require`, with no `--cclib` and nothing to install beyond the
platform's sqlite3.

The package declares `targets = ["c"]` — its calls are foreign code,
which the interpreter refuses with E3009 and the other targets refuse
at resolution or build time. `emo run` cannot execute a program that
touches it; build with `emo build` (the default target is `c`).

## Using the package

```emo
require "sqlite3"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "sqlite3"` needs `"sqlite3" = "0.1.0"`
in the manifest's `deps` block. The package declares the `c` target —
it carries native code, so only the `c` target can build it.

## Errors

Following the standard library's convention, every failing call raises
an ordinary Emo exception whose message names the operation and carries
SQLite's own error text — `sqlite3: prepare: no such table: notes` — no
error codes, no nil. The one non-raise boundary is `step()`: reaching
the end of the rows is a value (`false`), not a failure. `step()` is
where a statement's execution error surfaces; `reset()` then clears the
statement for another run instead of re-raising the error `step()` has
already raised (a raise ends the process), and `finalize()` — the
statement's last chance — raises a pending error rather than dropping
it.

## Connections

```emo
def open(path String) Database
```

`open` opens the database at `path` — `":memory:"` for a transient
in-memory database — and raises when SQLite cannot open it. `close()`
when done.

```emo
class Database {
  def exec(sql String) Void
  def prepare(sql String) Statement
  def last_insert_rowid() Int64
  def changes() Int64
  def close() Void
}
```

`exec` runs one or more semicolon-separated statements that return no
rows — DDL and one-off writes — and raises on any error. `prepare`
compiles one SQL text into a `Statement`, raising on a syntax or schema
error. `last_insert_rowid` is the rowid of the most recent insert on
the connection; `changes` is how many rows the most recent
insert/update/delete touched. `close` raises when unfinalized
statements keep the connection busy.

## Statements

```emo
class Statement {
  def bind_int(i Int64, v Int64) Void
  def bind_float(i Int64, v Float64) Void
  def bind_text(i Int64, v String) Void
  def bind_null(i Int64) Void
  def step() Bool
  def reset() Void
  def finalize() Void
  def column_count() Int64
  def column_name(i Int64) String
  def column_int(i Int64) Int64
  def column_float(i Int64) Float64
  def column_text(i Int64) String
  def column_is_null(i Int64) Bool
}
```

The working loop: bind the parameters, `step()` through the rows, read
columns while a row is current, `reset()` to run the same statement
again, `finalize()` when done.

**Bind indices are 1-based** — they name the `?NNN` parameters in the
SQL text — and **column indices are 0-based**, SQLite's convention.
`step()` answers `true` while a row is current and `false` once the
rows are exhausted; any other outcome raises. Column reads follow
SQLite's type conversion rules; a NULL column reads as `0`, `0.0`, or
`""` by accessor, and `column_is_null` tells NULL from a real zero or
empty string.

## Boundaries and limitations

Strings cross the C boundary NUL-terminated: a String carrying an
embedded NUL truncates there, in both directions. Blobs are out of
scope until `Bytes` can cross the FFI — bind them and they refuse at
check time, like every unsupported foreign type.

## Example

```emo
require "sqlite3"

const db = sqlite3.open(":memory:")
db.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

const insert = db.prepare("INSERT INTO notes (title) VALUES (?1)")
insert.bind_text(1, "first")
insert.step()
insert.finalize()

const query = db.prepare("SELECT id, title FROM notes")
while query.step() {
  println("row ${query.column_int(0)}: ${query.column_text(1)}")
}
query.finalize()
db.close()
```

The full worked demo — bound parameters of every type, a stepped read
with NULL handling, change counts — is `examples/sqlite3_demo`.
