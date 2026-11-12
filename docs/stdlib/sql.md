# The `sql` Package

The standard library's SQL parser: SQL text in, an abstract syntax
tree out, written in pure Emo over the shared runtimes — bytes and the
`float` package's exact-decimal conversion. No per-target runtime
work: every target that compiles the language answers identically,
byte for byte.

## Using the package

```emo
require "sql"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "sql"` needs `"sql" = "0.1.0"` in
the manifest's `deps` block.

## The tree

`parse` returns a `Stmt`: an interface over one class per statement
kind — `Select`, `CreateTable`, `Insert`, `Update`, and `Delete` —
discriminated by the `StmtKind` enum. Within a statement, expressions
are `Expr` nodes (one class per `ExprKind`) and table references are
`TableRef` nodes (one class per `TableKind`).
All three interfaces answer `to_string()`, the canonical SQL
rendering: uppercase keywords, explicit join kinds, `AS` on aliases.
Node fields are public and frozen after construction; read the
concrete class behind an `Expr` through `is()` narrowing:

```emo
const (R.ok, stmt) = sql.parse("SELECT name, count(*) AS n FROM users GROUP BY name")
if stmt.is(sql.Select) {
  println(stmt.columns.length())
  const item = stmt.columns[1]
  if item.is(sql.SelExpr) {
    println(item.alias_e[0])   // "n"
  }
  println(stmt.group_by.length())
}
```

Optional pieces ride as 0-or-1 arrays — `where_e`, `having_e`,
`limit_e`, `offset_e` on `Select`, `alias_e` on `SelExpr`, `TblNamed`,
and `TblSubquery`, `on_e` on `TblJoin`, `operand_e` and `else_e` on
`CaseExpr` — the same "empty means absent" reading as the list fields
(`group_by`, `order_by`, `from_t`, `using`, an `InTest`'s `choices`).

## Parse

```emo
def parse(text String) (R, Stmt)
```

Strict, byte-level: keywords case-insensitive, identifiers and quoted
identifiers (`"a""b"` decodes to `a"b`), string literals with the
standard `''` escape (no backslash escapes — standard SQL has none),
`?` and `?NNN` parameters (the index counts from 1, so `?0` refuses),
`--` and `/* */` comments, and the full
expression grammar — literals, qualified columns, function calls with
`DISTINCT` and `*` arguments, `CAST`, `CASE`, `EXISTS`, scalar
subqueries, and `OR` / `AND` / `NOT` / comparisons / `LIKE` / `IN`
(list or subquery) / `BETWEEN` / `IS [NOT] NULL|TRUE|FALSE` / `+ - *
/ %`, with `||` sharing the additive level the standard gives it.

Every malformed input comes back as `(R.error, reason)` instead of
inventing a tree: the reason a String stating exactly what failed and
at what byte offset, `sql: expected an expression at byte 7`. The
strictness rules: no chained comparisons (`a = b = c` refuses), and no
invented clauses — each of `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`,
`LIMIT`, `OFFSET` appears at most once and only in that order, so a
duplicate or an out-of-order clause refuses rather than being quietly
reordered; one statement per `parse` call; expression nesting capped at
512 like the format packages. Out-of-range numbers refuse —
integers beyond `Int64` (`-9223372036854775808` itself reaches, the
sign folds into the literal) and floats beyond binary64.

## Supported statements

`SELECT` end to end: a `DISTINCT` select list (`*`, `t.*`,
expressions with optional `AS` aliases), a `FROM` list of named tables
(optionally schema-qualified, optionally aliased), subqueries, and
`INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` / `NATURAL` joins with
`ON` or `USING`; `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY` with
`ASC`/`DESC`, `LIMIT`, `OFFSET`. `JOIN` alone is an inner join; a
`NATURAL` join takes no `ON` or `USING`.

### CREATE TABLE

`CREATE TABLE users (id BIGINT NOT NULL PRIMARY KEY, name TEXT NOT NULL,
score DOUBLE PRECISION, handle VARCHAR(12))`. The v0 types are
`INTEGER`, `BIGINT`, `REAL`, `DOUBLE PRECISION`, `TEXT`, `VARCHAR(n)`,
`BOOLEAN`, and `BYTEA` — exact spellings, no aliases (`INT`, `BOOL`,
`SERIAL`, … refuse), and `VARCHAR` needs a positive `(n)`. Column-level
`NOT NULL` and `PRIMARY KEY` are supported, each at most once and in
either order; the canonical rendering writes `NOT NULL` before
`PRIMARY KEY`. Duplicate column names refuse.

### INSERT

`INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')` — the
column list is optional, and there is one or more parenthesized rows.
Every row has the same number of expressions, and the column list's
length when present; a mismatch refuses. Duplicate names in the column
list refuse.

### UPDATE and DELETE

`UPDATE users SET name = 'Ada', active = TRUE WHERE id = 1` — distinct
assignments (a repeated column refuses) and an optional `WHERE`.
`DELETE FROM users WHERE id = 1` — the `WHERE` is optional.

Not supported — each answers `(R.error, reason)`, never a guess:
`INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, table-level constraints
and `UNIQUE`/`DEFAULT`/`CHECK`/`REFERENCES`, `CREATE INDEX`, `UPDATE ...
FROM`, `DELETE ... USING`, `WITH`, set operations
(`UNION`/`INTERSECT`/`EXCEPT`), window functions, bracket-style quoted
identifiers, `ESCAPE` on `LIKE`, and multiple statements in one call.

## Rendering

`to_string()` on every node rebuilds the statement canonically:

```emo
const (R.ok, q) = sql.parse("select * from users where id = ?1")
println(q.to_string())
// SELECT * FROM users WHERE id = ?1
```

Quoted identifiers render only where the spelling needs quoting; a
name like `weird name` round-trips double-quoted, `name` stays bare.
Explicit source parentheses are kept (`Paren` nodes), so a rendering
always shows the grouping the writer wrote.
