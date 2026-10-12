# Step 38 — The standard library: `sqlite3`

**Milestone:** M11 — The standard library · **Prereq:** step 23 (the c
target's direct C ABI), step 24 (the embedded stdlib) · **Related:**
`docs/native-backend.md` (the FFI surface), CHECK.md 2026-10-12 (the
package-carried-native-code settle), `docs/stdlib/sqlite3.md` ·
**Status:** done on c; every other target refuses the package at
resolution, and the interpreter refuses its foreign defs with E3009.

## Why this step exists

A language without a database binding has no answer to the most
ordinary server-side question, and SQLite is the one database whose
interface is a C library everywhere. It is also the first standard
library package that cannot be pure Emo *and* cannot be a compiler
builtin without taxing every binary — so it is the forcing case for
the package system learning to carry native code.

## Goal

`require "sqlite3"` on the c target opens a database, executes DDL,
prepares statements, binds parameters (int / float / text / null),
steps rows, and reads typed columns — with no `--cclib` and no
hand-compiled shim on the consumer's side. The package declares
`targets = ["c"]` and `link = ["sqlite3"]`; the build compiles the
package-carried shim and links the system library by itself.

## Design note

- **The route is `foreign def`, not builtins.** The builtin route
  (`os`/`file`'s shape) would put sqlite calls in the always-linked C
  runtime — every Emo binary linking `-lsqlite3` — and would need an
  OCaml-side binding for the interpreter. The foreign route keeps the
  whole dependency inside the package; the interpreter refuses it
  honestly (E3009).
- **The manifest gains `link`; the tree carries the C.** `link`
  names system libraries as bare names (a flag- or path-shaped entry
  is E5103 — the manifest stays data; `--cclib` keeps the verbatim
  role), and `.c`/`.h` files are collected, checksummed, embedded,
  and published beside the `.emo` modules — the tree is the package,
  so no field names files. Both ride the existing cclib mechanism
  into the c target's cc invocation and cache key (sources by
  content, libraries by name). Only the c target honors a package's
  native inputs; anything else refuses at build time (E5007), with
  `targets` refusing at resolution first.
- **A shim with an exact ABI.** SQLite's out-parameters
  (`sqlite3_open`, `sqlite3_prepare_v2`) and its `int` returns cannot
  meet the FFI as-is, so the package carries `emo_sqlite3_shim.c`:
  one wrapper per operation, every signature only
  `int64_t`/`double`/`bool`/`const char *`, handles as pointer-sized
  Int64s. The shim includes the generated `emo_defs.h`, so a
  signature drift breaks at cc time in both directions. The raw
  `foreign def`s sit in a subtree-private `internal/ffi.emo`; the
  public surface is `Database` / `Statement` classes.
- **Errors raise, per the os convention of the base branch** — the
  message names the operation and carries SQLite's own text. The one
  non-raise boundary is `step()`: end of rows is `false`, a value.
  The package joins the error-handling migration to
  `(R.ok, …)` / `(R.error, …)` tuples when that branch lands.
- **Conventions pinned:** bind indices are 1-based (they name the
  SQL text's `?NNN`), column indices 0-based (SQLite's); a NULL
  column reads as `""` with `column_is_null` telling the two apart;
  embedded NULs truncate at the boundary until Bytes can cross the
  FFI — blobs are out of scope until then.

## Tasks

- [x] T38.1 — the manifest's `link` field: parse (strict, optional,
  bare names only), tests.
- [x] T38.2 — packages carry `.c`/`.h`: `Registry.collect_files` and
  `gen-stdlib-data.sh` collect and embed them; publish and checksums
  flow through unchanged.
- [x] T38.3 — the build wiring: `load_deps`/`compile_inputs` collect
  each dependency's C sources and link libraries; the c target's cc
  invocation and cache key take them; the non-c gate (E5007).
- [x] T38.4 — the `sqlite3` package: manifest, `internal/ffi.emo`,
  `emo_sqlite3_shim.c`, the `Database`/`Statement` public surface.
- [x] T38.5 — `examples/sqlite3_demo` golden on the c target (gated
  on a sqlite3 probe, beside `cc_available`), plus the
  native-dependency tests in `test/emo_project`.
- [x] T38.6 — docs: CHECK.md entry, README (+ zh-CN),
  `docs/native-backend.md` (+ zh-CN), `docs/stdlib/sqlite3.md` (+
  zh-CN), the stdlib tours.

## Out of scope

Blobs (Bytes cannot cross the FFI yet), `sqlite3_exec` callbacks,
WAL/pragma helpers, an ocaml-target binding, the vendored
amalgamation, verbatim flags in `link`.
