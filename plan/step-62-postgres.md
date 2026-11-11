# Step 62 — The standard library: `postgres`

**Milestone:** M25 · **Prereq:** steps 38, 50 · **Status:** landed
2026-11-11 (code, demo, docs; the suite rides the next requested
`dune runtest`)

## Why this step exists

The standard library's database surface is one embedded engine —
`sqlite3`, the first native-binding package. Real deployments talk to
a server, and PostgreSQL is the one the industry standardized on. The
wire client cannot honestly be re-derived in the package: SCRAM-SHA-256
authentication, TLS, the conninfo grammar, and the protocol's pacing
are libpq's to carry, exactly as the sqlite3 decision gave the storage
engine to the system library and kept the shape for Emo. This step
lands `postgres`, the standard library's second native-binding package:
`foreign def`s against a package-carried C shim, libpq resolved through
the manifest's `pkg_config` field, and the `net` error shape — a
network client's routine failures (a server that is down, a constraint
the data broke) are `(R.error, reason)` values, not raises.

## Decisions settled here (the trail)

- **libpq through `pkg_config`, not `link`.** One field answers both
  the shim's include path and the link's `-lpq`, and it is the
  standard resolution on every machine with a `libpq.pc` (Debian's
  `libpq-dev`; Homebrew's kegs with their pkgconfig directory on
  `PKG_CONFIG_PATH`, which the golden's probe supplies).
- **The `net` error shape, not sqlite3's raise-everything.** sqlite3
  is embedded: a failed open means a broken program, and a raise is
  honest. A network client's SQL failures are ordinary control flow —
  the reason carries the server's one-line primary message and the
  SQLSTATE (23505, 42P01), and only contract violations raise. The
  two doors check each other: rows refuse `exec`, a bare command
  refuses `query`.
- **Scalar FFI only, staging between begin and fire.** A `foreign
  def` parameter cannot be an array, so the shim gathers parameter
  slots one `bind_*` at a time over a bound-mask, and `exec_fire`
  with an unnamed slot refuses — the public API binds every slot it
  staged, so the path is a package-bug tripwire, not a silent NULL.
  A tuple foreign return is unusable from a shim: the generated shape
  typedefs are counter-named per program (`emo_shape<N>`), so
  `emo_defs.h` declares a symbol the shim cannot spell — the typed
  cell reads ride `_ok`/read pairs instead, the validation in C with
  endptr full-consume and honest ERANGE handling.
- **No C numeral crosses raw.** `CONNECTION_OK` becomes 1; a result
  becomes 2 (rows) / 1 (command) / 0 (failure) in the shim.
- **The golden rides a live server, behind a probe.** `postgres_demo`
  uses a temp table (nothing left behind), runs against whatever
  answers on `localhost:5432`, and joins `c_goldens` behind
  `postgres_available` — pkg-config resolution with the Homebrew-keg
  fallback putenv'd into the environment, a tiny `-lpq` link, one TCP
  connect. No libpq or no server skips, exactly like `sqlite3_demo`.

## Tasks

- [x] T62.1 — the package (four files, the sqlite3 shape; the public
      API: connect/connect_info + ConnOptions, exec/query + Param,
      Rows with typed checked accessors)
- [x] T62.2 — the demo and its golden (temp table, three runs
      byte-identical, the probe, E3009/E5007 verified live)
- [x] T62.3 — docs EN+zh, the index rows, CHECK.md, TASKS, this file

## Evidence

- `examples/postgres_demo` on PostgreSQL 18.6, three runs
  byte-identical against `expected.txt` (connect via options, DDL,
  three inserts with `$1`–`$3` including one SQL NULL, a full read
  with `index_of`/`i64`/`text`/`is_null`, a filtered read, the error
  branch, close).
- `emo run` on the demo refuses with E3009; `emo build --target
  ocaml` refuses at resolution with E5007.
- `dune build` green with the package embedded in the compiler
  registry; `emo check` on the demo clean.

## Open, deliberately

Prepared statements reused across calls, binary-format parameters,
`COPY`, `LISTEN`/`NOTIFY`, cursors, per-operation timeouts — each
named in the docs' limitations, none promised.
