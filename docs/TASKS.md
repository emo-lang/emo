# Development Tasks

A numbered checklist of every implementation task, consolidated from
`plan/step-01-project-scaffold.md` onward.
The plan files remain the specs — each task below belongs to a step that
holds its full goal, scope, and acceptance details. This file is the tracker.

## How to use this file

- **Numbering:** `T<step>.<n>` — the step number matches `plan/step-NN-*.md`.
- **Working in spare time:** tasks within a step are ordered; any prefix of
  completed tasks leaves the tree in a consistent state. A step boundary is
  the checkpoint where the repo must build and `dune test` green.
- **Write the section before the work:** a step's section is written when
  the step starts, and each task is sized to finish in one spare sitting.
- **Ground rules** (from `plan/README.md`):
  - Never start the next step on a red build.
  - `README.md` (repo root) is the design source of truth. Provisional
    decisions are marked below; settle them in `CHECK.md` / `README.md`
    before the task that depends on them.
  - Strictness first: reject early with a clear diagnostic. No auto-fixing,
    no implicit additions, no silent fallbacks.
- **Tracking:** check items off here as you go, and update the status table
  in `plan/README.md` when a step completes.

## Milestones

| Milestone | Steps | Exit criteria |
| --- | --- | --- |
| M1 — MVP interpreter | 01–08 | Single-file Emo programs (functions, classes, enums, exceptions) run via `emo run` / `emo repl` with readable errors. |
| M2 — Compile-time experience | 09–11 | Gradual type checker, structural module system, and packages with MVS resolution; multi-package projects build and run. |
| M3 — Concurrency & networking | 12–13 | Processes and message passing on an effects-based scheduler; direct-style networking. |
| M4 — Compilation targets | 14–19 | Native code generation via `emo build`; then Wasm / TypeScript / BEAM / RISC-V. |
| M5 — Wasm Runtime | 20–22 | A WebAssembly runtime written in Emo: the shared systems layer, then the binary decoder/validator, then the interpreter with spec-suite goldens. |
| M6 — Self-contained hosted backend | 23 | `emo build --target c`: emit C, Emo's own runtime, direct C ABI — the hosted-native-FFI assessment scheduled; unblocks self-contained tool distribution (CHECK.md). |
| M7 — Toolchain | 24 | The toolchain release: signed per-platform `emo` binaries on GitHub Releases (brew/opam as the source channels); a binary-only machine runs and builds Emo programs; `emo new` / `emo deps` / `emo doctor` complete the command set. |
| M8 — Target independence | 25 | Every target's runtime lives in the target's own ecosystem — embedded as generated data (c, ocaml, typescript) or inside the emitted module (wasm, beam) — never beside the binary or in the host build tree; the host contributes only the emitters. |
| M9 — For / While loops | 26–27 | The settled loop surface runs on the interpreter and all six targets byte-for-byte: `for` (three clauses, the header `var` scoped to the loop) and `while`, with bare `break`/`continue`; loops never grow any stack; guaranteed tail calls unchanged. |
| M10 — Error handling | 28–30 | The Erlang split lands: expected failures return `(R.ok, value)` / `(R.error, reason)` matched by `case` or assert-bound by pattern, violations raise the one `Exception` class, and the stdlib's raise sites migrate to the convention — every target byte-for-byte, `R` reaching the freestanding tier with them. |
| M11 — The standard library | 31–38 | The bundled stdlib packages — `json`, `yaml`, `xml`, `os`, `base64`, `slog`, `bufio`, and the native-binding `sqlite3` — each resolving against the manifest's `targets`, answering byte-for-byte on every target it declares, and shipping a full API reference plus a runnable golden. |
| M12 — Visualization (`plot`) | 39–45 | The `plot` package fills its T0 surface (continuous axes; line / scatter / area / histogram marks; log scales, domains, legends, grid, themes, palettes, faceting) and the T1 dataset charts, then adds terminal and PNG renderers — SVG output byte-identical on all five hosted targets. |
| M13 — Unit testing | 46 | `emo test` discovers the project's `test/` directory and runs every top-level `def test_*` with per-test isolation, reporting, and the exit-code family; the `expect_*` assertion builtins raise the one `Exception` class on failure (interpreter; compiled targets refuse honestly); scaffold, example, tests, and docs land together. |
| M14 — CSV read/write | 47 | The bundled `csv` package — RFC 4180 records, UTF-8 only — resolving like any stdlib package, answering byte-for-byte on all five targets, with the API reference and runnable goldens. |
| M15 — EmoUI | 48 | One declarative EmoUI tree renders on a terminal, a server-rendered page, a macOS/AppKit window, and a GTK 4 window (the browser DOM following its runtime path), each behind a thin per-platform entry; the shared app module is portable Emo, the composition syntax is identical everywhere, and per-platform component libraries share convergent names. The EmoUI packages live in this repository under `projects/emo-ui/`, and the compiler-side gates and the terminal-input package land in the tree (`CHECK.md`, the in-tree project layout). |
| M16 — Value-family reclamation | 49 | The `c` target reclaims the value-semantic kinds, not only the identity cells: a long-running program's arena bytes and identity liveness stay flat across renders instead of rising per event, array growth is linear rather than quadratic, and every existing golden on every target stays byte-identical (`spike/arena-scope`, `CHECK.md`). |
| M17 — Cross-target conformance | 50 | Conformance to promises already made, not new design: a spawned `c`-target process that raises dies alone, `send` delivers a snapshot, and `foreign def` refuses by name on `wasm` and `beam`; every existing golden on every target stays byte-identical (`CHECK.md`). |
| M18 — TLS on the `c` target | 51 | The three existing `net` TLS builtins run on the default target: the C runtime lands them against the system OpenSSL/LibreSSL behind hand-declared prototypes and IR-keyed conditional linkage (a non-TLS build never links OpenSSL), the ocaml scheduler's semantics and reason conventions hold, and `http`'s `https://` works end-to-end on `c` (`CHECK.md`). |
| M19 — Map on `wasm` and `beam` | 52 | The last two hosted targets implement the `Map` builtin through their existing mutable-kind mechanisms — insertion order, the six key kinds, structural `==`, and the `{key: value}` rendering byte-identical with the four targets that have it — `send` delivers a snapshot on `wasm` (the recorded remainder the new mutability makes reachable), `slog` widens to the two targets, `Exception.new(data:)` carries crash context everywhere but `riscv64`, and the `plot` package's Map-shaped `Table` and channels (Step 42) unblock (`CHECK.md`). |
| M20 — The numerical library | 53–54 | The `math` package grows into the correctness-first numerical surface the netlib assessment staged (`docs/math-netlib.md`): the full elementary-function set, complex arithmetic and a radix-2 FFT, BLAS1, an LU solver, and the error and gamma functions — pure Emo, byte-identical on all five hosted targets, with an ELEFUNT-derived battery as the accuracy record; then the native fast lane — the `fastmath` package binding `math`'s scalar surface to the host libm on `c`/`ocaml`, and the `quad` package binding QUADPACK through the existing scalar-and-callback FFI on `c`. Array-level performance (BLAS2/3, LAPACK) stays parked behind the array FFI gate. |
| M21 — The crypto package | 55 | The portable primitives layer as one pure-Emo package, `crypto` — SHA-2, SHA-3 and SHAKE, HMAC, HKDF and PBKDF2, the constant-time comparison, ChaCha20-Poly1305, AES with CTR, CBC, and GCM, Ed25519 and X25519, SHA-1 and MD5 behind `crypto.legacy` — byte-identical on all five hosted targets with every golden a diff against the RFC and NIST vectors and Go's own answers; the `rand` package beside it binding the entropy source per target and carrying the deterministic HMAC-DRBG stream; the error split per the house rule, Bytes as the carrier, and the docs stating constant time as a source-level discipline with each target's honest status. RSA waits on a bignum foundation; TLS, x509, and the post-quantum set stay out. |
| M22 — File IO on `wasm` | 56 | The wasm target's host boundary grows the file-system syscalls and the canonical host rides the compiler: `file`, `os` (the fd/directory half — the process half refuses at the call naming the capability), and `bufio` resolve and answer byte-for-byte on `wasm`; `emo run --target wasm` runs an artifact under Node with the bundled host; `emo build --target wasm` still emits exactly `.wasm` + `.wat`; every existing golden on every target stays byte-identical (`CHECK.md`). |
| M23 — The httpd server | 57 | The server half of HTTP moves out of `http` into `httpd` as a pure-Emo HTTP/1.1 server over `net` — a request in, a `Response` value out, one process per connection, keep-alive, chunked request bodies, `100-continue`, pattern routing with 405+`Allow` and path-cleanup redirects, per-request timeouts and size limits, graceful shutdown — byte-identical on the three hosted targets it declares, the client package slimmed back, every existing golden green (`CHECK.md`). |
| M24 — Macros | 58–61 | Compile-time macros as the one metaprogramming mechanism: the reserved `// #macro` / `// @name` directive namespace (unknown names refusing), the macro model — scalar parameters plus the trailing `Syntax` tree, checked before it runs, deterministic by construction (every effect and host-touching builtin refusing), erased after expansion, and the spliced code checked with the module — the quote surface and compile-time application arguments checked statically, derivation applied to classes (`Syntax.fields` / `with_methods`), and cross-module macros through the program's macro table with qualified applications and local shadowing — four pilots (`trace`, `memoize`, `derive_eq`, `derive_shared`) byte-identical across the interpreter and the c and TypeScript binaries, expansion riding before codegen so every target inherits by construction; runtime `eval`, open classes, and `method_missing` rejected permanently (`CHECK.md`). |
| M25 — The postgres client | 62 | The standard library's second native-binding package and its first wire-protocol database client: `foreign def`s against a package-carried C shim over libpq, resolved through the manifest's `pkg_config` field; `$1`-style `Param` parameters (text/i64/f64/bool/none), `Rows` with typed checked accessors and a by-name lookup, the `net` error split (a down server and a broken constraint answer `(R.error, reason)` with the server's message and SQLSTATE, contract violations raising); `postgres_demo` rides a temp table against a live server, three runs byte-identical, joining `c_goldens` behind the `postgres_available` probe; docs EN+zh, with the found-and-fixed `sqlite3` table row (`CHECK.md`). |
| M26 — The Emo shell | 63 | `emosh`, the general-purpose command interpreter written in Emo over the `os` surface: the environment, the signals, and the plumbing calls (`dup2`/`execvp`/`isatty`/`argv`) land in `os` beside the fork discipline; the shell itself lexes words into literal and expandable parts, expands `$var`/`$?`/the tilde, forks pipelines per stage and wires them through `dup2`, opens `<`/`>`/`>>` onto the child, walks `;`/`&&`/`||` with the carried status, answers the eight builtins, and lives by the ignored-interrupt discipline — the shell ignores, the fork child resets before its exec — reading lines in the terminal's own cooked mode; fixture scripts run byte-identically on the ocaml and c targets with their exit statuses pinned (`CHECK.md`). |
| M27 — The `websocket` and `playwright` packages | 64 | Browser automation from Emo: the RFC 6455 halves as a stdlib package over `net` (client dial with handshake verification, server accept, one text message per exchange, masking by role, pings answered, closes answered, fragmented receives joined), then the `playwright` client speaking the driver's channel protocol to the official `playwright run-server` over those frames — the pre-launched-browser shape, the initialize handshake on the root channel, and the core door set (goto/click/fill/press/title/content/text_content/screenshot/close) with the `net` error split; both demos carry their own counterparty (an echo server; a miniature driver answering the real wire shapes with a fragmented message, a ping, and the eight-byte length form) so the goldens need no browser and no Node, byte-identical on the interpreter and the `c` target (`CHECK.md`). |
| M28 — The RocksDB half | 65 | emo-db's first landing: the `projects/emo-db/` scaffold with the project-local `emo/rocksdb` binding — a package-carried C shim over the official RocksDB C API (open/close, get/put/delete, WriteBatch atomic writes, iterators, snapshots, column families) resolved through `foreign def`s and the manifest's `pkg_config` field (the `postgres` precedent); the C ABI grows the `Bytes` borrowed view (D10) so keys and values carry arbitrary binary data, with reads filling a caller-owned out-parameter; the scheduler's cooperative model serializes every call, so the shim grows no locks of its own; every other target refuses at resolution and the interpreter at run time (E3009/E5007 verified live); a KV demo — text and embedded-NUL values, a batch commit, reads, a prefix scan, snapshot isolation visible, close/reopen — run three times byte-identical on `c` through `projects/emo-db/check.sh` (`CHECK.md`). |
| M29 — The record layer | 66 | The database's own data model over the KV half: the catalog column family (tables, columns, types, indexes, and oid counters by oid, written and read through the shim), the row encoding over the v0 type subset (null bitmap, 4-byte INTEGER, 8-byte BIGINT/REAL/DOUBLE, boolean, length-prefixed TEXT/VARCHAR/BYTEA), rowid allocation inside the insert's WriteBatch, and secondary indexes as one column family per index named `idx_<oid>` and keyed by the indexed values plus the rowid — the shared `data` family keyed by table oid + rowid, the catalog's reopen through `rocksdb.list_families` with the index-CF verification, and equality-prefix index scans; a record demo creates a table in the catalog, inserts rows covering every type (NULLs, an embedded NUL in BYTEA, UTF-8 TEXT), reads by rowid, scans the table, finds rows through unique and non-unique indexes, and reopens the store, pinned byte-for-byte on `c` (`CHECK.md`). |
| M30 — The SQL front-end's DML and DDL | 67 | The `sql` package (pure Emo, byte-identical on every target) grows its statement set beside SELECT: CREATE TABLE with the v0 column types and column-level NOT NULL/PRIMARY KEY, multi-row INSERT ... VALUES with an optional column list, UPDATE ... SET ... [WHERE], and DELETE FROM ... [WHERE] — AST classes, the parser, and the canonical `to_string()` rendering for each, the existing SELECT grammar untouched, and the parser's shape checks (duplicate columns/assignments, row widths, a positive VARCHAR length, the unsupported tails by name); statement and expression goldens byte-identical on the interpreter and all five hosted targets (`CHECK.md`). |
| M31 — The planner and executor | 68 | The first full SQL-to-rows path through the engine: the `emo/engine` package over `emo/sql` and `emo/record` — plan nodes (scan, filter, project, insert, update, delete), typed expression evaluation with SQL's three-valued NULL logic, single-table SELECT (projection, WHERE; an equality on an indexed column becomes an index scan), CREATE TABLE (the v0 types, a primary-key index), INSERT, UPDATE and DELETE (the record layer's new update/delete rewrite the row and its index entries in one batch), and the PG-shaped `code: message` errors (`42P01`, `42703`, `42883`, `42804`, `23505`, `23502`, `22001`, `22012`, `0A000`, `42601`) — an embedded test face (no wire yet) pinning SQL text in and rows out byte-for-byte on `c`, with the plan tree printed, through `projects/emo-db/check.sh` (`CHECK.md`). |
| M32 — Transactions and the session plane | 69 | The transaction model of D6: BEGIN/COMMIT/ROLLBACK over the record layer's `Txn` — one WriteBatch per transaction committed atomically, a per-statement snapshot (read committed), a pending overlay for read-your-writes, the rowid counters published on commit, and the catalog's next-rowid change in the same write; the engine's session state, `LockClient`, and table-level write locks held to commit/rollback; an Emo lock-manager process with a FIFO of waiters, a wait-for graph, and a deadlock that aborts the requester with `40P01`; a two-session golden showing the read-committed pair, the write-write block, and the deadlock, pinned byte-for-byte on `c` through `projects/emo-db/check.sh` (`CHECK.md`). |
| M33 — The wire | 70 | PostgreSQL wire protocol v3, the simple query path in `emo/wire`: startup (SSLRequest/GSSENCRequest answered `N`, trust AuthenticationOk, protocol 3.0 only), the ParameterStatus set psql and libpq read, BackendKeyData, ReadyForQuery, Query with multi-statement strings split by the new `sql.split` at the lexer's own semicolons, RowDescription with the v0 type OIDs (`Result` grows `types`), text-format DataRow (booleans `t`/`f`, BYTEA `\x` hex, NULL -1), CommandComplete, EmptyQueryResponse, and ErrorResponse with PG's fields; an error stops the rest and reports the engine's clean state (`I`); one session actor per connection over the shared Store, the lock manager moved to `engine.locks` and attached per session, `Engine.end_session` releasing without closing the store; `wire_demo` (ephemeral port through a ready file, finite connection count) and `wire_client` (libpq's zero-parameter `PQexec` path through the standard `postgres` package) pin psql's script and its error stop plus the client's rows/error, byte-identical across three `projects/emo-db/check.sh` runs behind `psql`/`libpq` probes (49 checks); the BEAM `__inst_recv` temp fix (`CHECK.md`). |
| M34 — Conformance and documentation | 71 | The corpus and the record: an SQL statement corpus in the SQLLogicTest spirit — six files, 126 cases (`statement ok` with a pinned tag, `statement error` with a pinned `code: message` line, `query` with pinned rows in the runner's canonical rendering) over one fresh database per run, three runs byte-identical through `projects/emo-db/check.sh` (59 checks); the bench modes and `bench/run.sh` (warmup plus three timed runs) with the measured table, which found and fixed the read-only statement's WAL fsync and (with the corpus) the DDL-in-transaction block leak; `docs/emo-db.md` grown to the shipped surface (`What shipped`, `Measured`), the corrected stale claims, and the arc-two review of the row store's actual plug points (`CHECK.md`). |
| M35 — The column format | 72 | The column format and the catalog choice: `CREATE TABLE ... STORE = COLUMN` in the parser (the canonical rendering spells only the written column tail), the catalog's version-2 table definition with a `store` field (a version-1 record reads as row storage), the record layer's column half — one column family per column (`col_<oid>`), 1024-row blocks (row count, null bitmap, the row encoding's widths), the trailing partial block re-read and rewritten inside the transaction, the block scan in rowid order, the reopen's column-family verification, and the row path's named guards; no indexes on column tables (`PRIMARY KEY` and secondary indexes refuse in both layers); the engine's DDL mapping and the named `0A000` bridge for DML/SELECT; the `column_demo` golden (create, 1030 rows across the block boundary, reopen, refusals) three runs byte-identical through `projects/emo-db/check.sh` (66 checks) (`CHECK.md`). |
| M36 — The column executor | 73 | The batch executor behind the same surface: the record layer's `scan_column_batches` and `column_block_counts`, the engine's storage routing (SELECT to the column executor, INSERT to the column blocks, UPDATE/DELETE answering the insert-only `0A000`), the column plan nodes, and the global aggregates COUNT/SUM/AVG/MIN/MAX — COUNT answers 0 and the others NULL over zero rows, SUM widens by the argument, AVG is DOUBLE PRECISION, MIN/MAX keep the argument's type, `DISTINCT` aggregates refuse, a mixed select list answers `42803` naming the column, `count(*)` with no WHERE takes the block-count fast path, and the plan text shows `column scan`/`aggregate` — pinned by the engine demo's executor cases, three runs byte-identical through `projects/emo-db/check.sh` (66 checks) (`CHECK.md`). |
| M37 — The two-engine proof | 74 | Both engines in one database, one session, one transaction over the wire: `htap_demo` seeds a row table and a column table (1100 rows across the block boundary) through the engine and serves the wire; psql and the `postgres` client each drive a script that reads both engines, carries the row table's UPDATE and the column table's INSERT inside one BEGIN/COMMIT, and reads the post-commit aggregates (`1100|605550|1.0|row-999` seeded, `1|11.0` updated, `1101|606651` after), pinned byte-for-byte behind the probes; the corpus's `column.test` lifts it to 141 cases (the DDL, the projections, the five aggregates, the zero-row rule `0|NULL`, and the mixing/type/DISTINCT/star/insert-only/primary-key refusals); the bench's column modes record the first measured comparison — the block scan 304 ms / 32895 rows per second against the row store's 675 ms / 14815, the aggregate 142 ms / 70423 — through `projects/emo-db/check.sh` green 3x (76 checks) (`CHECK.md`). |
| M38 — The wasm capability | 75–77 | The Emo-written wasm runtime (steps 20–22) becomes a consumable capability: the package moves into the bundled registry as the `wasm` stdlib package with the execution surface on its root — `load`/`instantiate`/`call`/`get_global`/memory access over the R error split, the `(kind, bits)` value model with its constructors, and a host-import table of Emo closures — resolved like any bundled package; then `emo wasm run` executes a `.wasm` artifact from the CLI over the interpreter, the compiler never linking the runtime; then the `emo` host module (and the WASI surface it entails) runs modules from other toolchains; the conformance aliases (`wasm_spec`/`wasm_runs`) ride with the package (`CHECK.md`). |
| M39 — Text templates | 78 | The `template` package renders text with holes from a `json` context — Go `text/template`'s mechanism, Emo's own surface, pure Emo over the shared runtimes, byte-identical on all five targets: one-shot `render` and the parse-once-render-many `Set` (new/with/render), `{{ }}` holes over bare dotted paths and bracket paths with seven ASCII-safe filter pipelines, `if`/`else if`/`else`/`end` on "not the zero value" truthiness, `for` over arrays and objects with `else`, `template` includes (bindings never cross the edge, the depth cap names the chain), `{{- `-` -}}` trim markers and `{{! }}` comments; parse and render both strict, every failure a `(R.error, reason)` with the byte position; the goldens flushed two backend bugs — the IR's module-level def mangle skipped `sanitize_ident` (a `?` suffix leaking into TS/OCaml identifiers), and the BEAM emitter's threaded-chain case registered a branch's pattern bindings before the per-branch save, a sibling arm's bindings leaking into a later continuation's live set, dying as erlc `unbound variable` (`CHECK.md`). |
| M40 — The repl's line editor | 79 | The interactive session gains a real editor: the vendored upstream linenoise (BSD-2, pinned at `a473823d`, two marked patches — the temp history entry pops on Ctrl-C and end-of-input as ENTER pops it, and the blocking read's verdict errno survives the stop's terminal-probing cleanup) compiles into the CLI through dune's `foreign_stubs` — the first C the OCaml CLI links — behind a binding module whose stubs map the library's errno verdicts onto OCaml variants; the input seam carries the prompt text and distinguishes a completed line from Ctrl-C's abandonment and the input's end; the editor takes the seat only when stdin and stdout are both terminals, pipes and redirects keeping the plain path byte for byte; the history rides per line, saved at the session's end to the state file (`EMO_STATE_DIR` → `XDG_STATE_HOME` → `$HOME/.local/state/emo`), with the unreadable and unwritable cases warning on stderr and the missing file silent; Ctrl-C abandons the pending input instead of killing the process; the continuation prompt indents by two spaces per open bracket; the tests drive the real C editor over a pipe through upstream's `LINENOISE_ASSUME_TTY` hook — typed lines, up-arrow recall, the interrupt that leaks no empty history entry, and a two-session persistence round-trip (`CHECK.md`). |
| M41 — The standard library: `uuid` | 80 | The `uuid` package: the RFC 9562 identifier as one immutable 16-byte `Uuid` value rendering itself through the `to_string` protocol, answering `to_bytes`/`version`/`variant`/`is_nil?`/`is_max?` and sorting through the RFC 6.11 big-endian `compare`; `v4` drawing 122 random bits over `rand.bytes`, `v7(now_ms)` taking the Unix time in milliseconds from the caller's own clock over 74 random bits (a negative or 48-bit-overflowing timestamp raising), and `v3`/`v5` the deterministic name-based doors over `crypto.legacy` with the four IANA namespace IDs of Table 3; `parse` taking exactly the canonical 36-character form, case-insensitive on the digits, every rejection naming the first offending byte, and `from_bytes` refusing a length other than 16; scoped to Go's standard `uuid` spine, v1/v2/v6 and a v8 constructor out, named; `uuid_demo` riding the RFC's vectors with the random doors printed structure-only, byte-identical on all five target lists (`CHECK.md`). |

## Design gates

Open decisions tracked in `CHECK.md` that gate tasks below. Settle them
before starting the gated work:

| Decision | Gates | Provisional until settled |
| --- | --- | --- |
| CLI command names | T01.3, T08.1–T08.2 | settled in M1 — `run` / `repl` / `check` / `version` shipped |
| String escape rules | T02.3, T02.4 | Minimal set `\n \t \\ \' \"` |
| Self-pid mechanism | T12.1 | settled — `self_pid()` builtin, `Pid` type rendering as `<pid N>`, `halt()`; no user-facing kill/wait |
| Error-handling model (was: exception catch syntax) | T13.5, M10 | settled 2026-10-11 — no catch; `(R.ok, value)` / `(R.error, reason)` tuples plus the one `Exception` class (`CHECK.md`); Steps 28–29 land it |
| Manifest / lockfile names, scope-prefix format, version ranges, deps CLI names | T11.2, T11.5–T11.6, T11.8–T11.9 | `package.emo`, `package.lock`, `owner/name`, exact pins only, `emo deps *`; a deps key is a string literal (T11.9) |
| C FFI binding-surface syntax | T14.6 | settled — `foreign def name(params) Ret = "c_symbol"`, `Float`/`String`/`Bool` only, through generated C wrappers |
| Reclamation model for the dynamic world (no tracing GC) | T23.5 | settled — reference counting for identity objects, arena for value-semantic data (`CHECK.md`, at T23.5) |
| `emo build` default target | T24.1 | flip `ocaml` → `c`: a distributed binary carries no OCaml toolchain; the `ocaml` target stays for source installs |
| Stdlib: embed vs sidecar tree | T24.2 | embed as generated data inside the compiler (the C runtime's mechanism); `EMO_REGISTRY` override stays |
| `emo install` semantics | T24.4 | settled then superseded 2026-10-17 — the command was removed; `emo deps` and the build path own resolve/fetch/lock, and installing global executables stays out of scope for 1.0 |
| The runtime-independence principle | T25.1 | a target's runtime is written in the target's language, carried as generated data inside the compiler; the host contributes only the emitter |
| The ocaml runtime's dependency policy | T25.4 | the OCaml standard library plus `unix` for the core; `ssl` as the one opam dep, refused with a clear message when absent; no eio |
| EmoUI native UI packaging (per-package native fields) | T48.7–T48.9 | settled 2026-10-14 — the manifest grows per-package native fields; a native backend does not ship an app-level build script (`CHECK.md`, `docs/emo-ui.md`). **Landed 2026-10-18 (T48.7)**: `pkg_config` (bare modules; `--cflags` compile, `--libs` link), `frameworks` (bare names; `-framework NAME`), and `.m` collected beside `.c`/`.h` and compiled under ARC |
| `c` target long-running memory (value-family reclamation) | T48.8–T48.9 (demo scale), step 49 | settled 2026-10-14 — region reclamation is not viable; the value families need refcounting, scheduled as step 49 (`CHECK.md`, `spike/arena-scope/`). **Landed 2026-10-17 (T49.1–T49.4)**: the working set is flat and the demo-scale note is retired |
| EmoUI browser runtime path | T48.10–T48.11 | settled 2026-10-15 — the split route: a browser-safe subset of the TypeScript runtime, a `dom_*` family, and a bundling step, rather than new wasm host imports (`CHECK.md`, `docs/emo-ui.md`). **Landed 2026-10-18 (T48.10–T48.11)**: the bundling step is a build target (`emo build --target browser`), the split is a host-free core plus Node and page hosts, the `dom_*` family is thirteen calls over Int64 handles, and `emo/ui_browser` is the DOM backend over them, with the convergence corpus running in a stub page |
| Cross-target conformance (`c` raise, `c` send, `foreign def` on `wasm`/`beam`) | step 50 | settled 2026-10-15 — conformance to promises already made, not new design: a child's raise ends only that child, `send` snapshots, and the two emitters refuse `foreign def` by name (`CHECK.md`). Refined by T39.3: the declaration is inert off the native targets, and the refusal is at the call. The `typescript` target's share-on-send stays open |
| Array growth (O(1) append vs a builder) | T48.1, T49.4 | settled 2026-10-15 (T49.3) — a builder, as a new language-level `ArrayBuilder` type rather than an `Array` representation change (`CHECK.md`, `docs/intro/syntax.md`); the `List` → `Array` conversion half is deliberately not taken |
| The in-tree project layout (`projects/`) | all of M15 | settled 2026-10-15 — `projects/<repo-name>/` at the repository root holds each named Emo project (EmoUI, EmoOS, EmoShell), named for the repository it can later be split out into; EmoUI stays not a standard-library package (`CHECK.md`) |
| Terminal input's placement (T48.5) | T48.5 | settled 2026-10-15 — raw mode is a standard-library package in the `sqlite3` shape (package-carried `.c`/`.h` reached through `foreign def`, gated by `targets`), not a UI-framework or compiler-side artifact (`CHECK.md`, `docs/emo-ui.md`) |
| TLS on the `c` target (linkage detection, prototypes, Windows) | step 51 | settled 2026-10-17 — the three `net` TLS builtins land in the C runtime against the system OpenSSL/LibreSSL: the `c` emitter's IR walk gates `EMO_HAS_TLS` + `-lssl -lcrypto`, the prototypes are hand-declared (no OpenSSL headers anywhere), the floor is the API subset (OpenSSL ≥ 1.1.1 / LibreSSL ≥ 3.5.0), and Windows stays refused (`CHECK.md`, `plan/step-51-tls-c-target.md`) |

---

## M1 — MVP interpreter

### Step 01 — Project scaffold & CLI skeleton · `plan/step-01-project-scaffold.md`

**Prereq:** none.
**Done when:** `dune build` and `dune test` pass from a clean checkout; `emo version` prints `emo 0.0.1`; placeholder subcommands exit non-zero; CI green on Linux and macOS.

- [x] **T01.1** — Create `dune-project` and the `src/` library skeletons (`emo_support`, `emo_lexer`, `emo_parser`, `emo_ast`, `emo_eval`, `emo_check`, `emo_cli`) with placeholder modules that compile.
- [x] **T01.2** — Implement `emo_support`: span, severity, diagnostic, renderer; unit tests for the renderer.
- [x] **T01.3** — Implement `emo_cli` with cmdliner; wire the four subcommands to placeholder actions.
- [x] **T01.4** — Add alcotest smoke tests per library and the CI workflow (setup-ocaml, `dune build`, `dune test`, Linux + macOS).
- [x] **T01.5** — Add `.ocamlformat` (conventional profile); format the tree once (`dune build @fmt` passes).

### Step 02 — Lexer · `plan/step-02-lexer.md`

**Prereq:** Step 01.
**Done when:** suites cover every token kind, interpolation nesting (`"a ${ "b ${x}" } c"`), position fidelity on multi-line input, and every error case; `dune test` green.

- [x] **T02.1** — Token type + positioned token stream in `emo_lexer`.
- [x] **T02.2** — Identifier classes (`LOWER_IDENT` / `UPPER_IDENT`), keywords, operators.
- [x] **T02.3** — Numeric and char literals with escape handling.
- [x] **T02.4** — Interpolated-string token scheme with nesting tests.
- [x] **T02.5** — Newline-preserving stream API.
- [x] **T02.6** — Error cases: each rejects with correct line:col via `emo_support`.

### Step 03 — Parser: expressions · `plan/step-03-parser-expressions.md`

**Prereq:** Step 02.
**Done when:** every expression snippet in the README parses to the expected AST (golden tests); precedence pinned (`1 + 2 * 3`, `a && b || !c`, `x.foo(1)[i].bar?()`); `dune test` green.

- [x] **T03.1** — `emo_ast` expression/statement types with spans on every node.
- [x] **T03.2** — Pratt-style expression parser with the precedence table.
- [x] **T03.3** — Call parsing: positional + named args, trailing-block sugar.
- [x] **T03.4** — Arrow blocks; `if` / `else` (single shape, no chaining).
- [x] **T03.5** — Newline-termination rules with depth tracking.
- [x] **T03.6** — Interpolated-string reassembly from lexer parts.
- [x] **T03.7** — Parser tests: precedence table, dangling-operator continuations, malformed input errors.

Scope note: tuple literals under the content rule, tuple patterns, `case` / `receive` / `do` / send syntax all parse within this step (semantics stay "not yet" errors until steps 05 / 11).

### Step 04 — Parser: declarations · `plan/step-04-parser-declarations.md`

**Prereq:** Step 03.
**Done when:** the README's `User`, `Greeter` / `English`, `welcome`, and `Color` snippets parse to golden ASTs; negative tests (camelCase `def`, `UPPER` variable, enum payloads, duplicate `init`, a declared `init` return type) rejected with the right message and span; `dune test` green.

- [x] **T04.1** — Declaration AST nodes; top-level item sequence.
- [x] **T04.2** — `def` parsing with the `init` exemption and `?`-name rules.
- [x] **T04.3** — `class` (single-`init` rule, field collection from `self.x =`).
- [x] **T04.4** — `interface` signature-only bodies.
- [x] **T04.5** — `enum` member lists.
- [x] **T04.6** — `raise` statement.
- [x] **T04.7** — Naming-convention checks with spans; multi-error resync.
- [x] **T04.8** — Golden tests: README examples parse cleanly; convention violations produce the expected errors.

### Step 05 — Interpreter: core values & evaluation · `plan/step-05-interpreter-core.md`

**Prereq:** Step 04.
**Done when:** the acceptance program runs (`fib(20)` → 6765, interpolated greeting, `count_down(1000000)` with a flat stack); `dune test` green including the deep-recursion case.

- [x] **T05.1** — Value ADT + equality; environment chain.
- [x] **T05.2** — Expression evaluation with tag-checked operators.
- [x] **T05.3** — Interpolation; `print` builtin; `.to_string()`.
- [x] **T05.4** — Closure capture (lexical, by reference to the environment).
- [x] **T05.5** — Tail-call loop in the evaluator; deep-recursion test.
- [x] **T05.6** — `if` / `return` semantics; runtime type errors with spans.
- [x] **T05.7** — Alcotest suites running real programs end to end (assert on captured stdout).

Scope note: arrays, tuples, and `Box` (with its three-operation set) are part of this step's value model. `print` is a provisional name — promote it into the README once the I/O surface settles.

### Step 06 — Interpreter: classes, enums, interfaces · `plan/step-06-interpreter-objects.md`

**Prereq:** Step 05.
**Done when:** the README's object examples run verbatim (value-semantic `User`, `Color`, duck-typed `welcome`, structural `is()`); negative tests (`self.x =` outside `init`, missing method, uncaught raise) error as specified; `dune test` green.

- [x] **T06.1** — `ClassDef` / `Instance` values; `init` window flag; field freeze.
- [x] **T06.2** — Method dispatch + `self`; `NoMethodError`.
- [x] **T06.3** — Deep `==` on instances; shared-structure immutability tests.
- [x] **T06.4** — Enum singletons; `TypeValue`; `is()` with structural interface check.
- [x] **T06.5** — `raise`; builtin `Exception`; uncaught-exception termination.
- [x] **T06.6** — `.to_string()` for instances, enums, exceptions.

### Step 07 — Function groups (`emo` keyword) · `plan/step-07-function-group.md`

**Prereq:** Steps 01–06.
**Done when:** `emo Foo { def ... const ... }` declares a function group, `Foo.hello()` / `Config.version` resolve and run on the interpreter and all four backends (goldens in CI), and the README documents the syntax.

- [x] **T07.1** — Parser (`emo` keyword + group items), checker (group symbols, name/arity rules), IR lowering to mangled functions; `examples/function_group/` golden through `emo run`.
- [x] **T07.2** — TypeScript, wasm, and beam goldens for the example; README (English + zh-CN) documents the syntax.

Close-out: groups lower to mangled functions with double-keyed symbols (group-qualified and module-bare), so every backend got them without backend code. The showcase example (processes across files on all four targets) landed with the TS process support; the manifest-path bug it exposed (an entry lowered twice under a relative path) is fixed in `emo_project`. Decisions are in `plan/step-07-function-group.md` (Close-out). **Step 07 acceptance met.**

### Step 08 — CLI & diagnostics · `plan/step-08-cli-diagnostics.md`

**Prereq:** Steps 01–07.
**Done when:** every `examples/*.emo` runs with expected output in CI; a file with three parse errors reports all three at correct line:col, stable under `--no-color`; the REPL runs the step 06 acceptance block interactively. **M1 exit criteria met.**

- [x] **T08.1** — `run` command with stage pipeline and exit codes (lex/parse 65, eval 70, uncaught exception 1).
- [x] **T08.2** — REPL: multi-line reading, persistent environment, value echo.
- [x] **T08.3** — Diagnostic renderer completion (excerpts, codes, hints, colors, error limit); unit tests over golden renderings.
- [x] **T08.4** — Uncaught-exception trace plumbing in the evaluator.
- [x] **T08.5** — `examples/` golden tests wired into CI.
- [x] **T08.6** — Manual pass: run each example, use the REPL interactively.

Close-out note: promote the provisional decisions that M1 proved (`print`, trailing-block sugar) into the README.

---

## M2 — Compile-time experience

### Step 09 — Gradual type checker · `plan/step-09-type-checker.md`

**Prereq:** Steps 01–08.
**Done when:** every README example type-checks clean; the wrong-type-declaration corpus (wrong return type), bad named arg, `var` escape, narrowing misuse) is rejected with correct spans; the zero-false-positive corpus passes with no diagnostics; `emo check` works and `emo run` runs the pass first.

- [x] **T09.1** — Type representation + type declaration collection pass.
- [x] **T09.2** — Statement/expression checking with `Unknown` discipline.
- [x] **T09.3** — Signature checks; arrow-block inference.
- [x] **T09.4** — Branch-scoped environments with narrowing on `is()`.
- [x] **T09.5** — Structural interface conformance.
- [x] **T09.6** — `var`-escape detection.
- [x] **T09.7** — Call-site checking; named-argument validation.
- [x] **T09.8** — `case` checking: pattern typing, `when` guards as `Bool`, exhaustiveness on decidable enums and on the first tuple element of decidable `(Enum, ...)` scrutinees (guarded branches don't count).
- [x] **T09.9** — `emo check` command; wire into `emo run`.
- [x] **T09.10** — Test categories: strict type-declaration rejections, inference successes, zero-false-positive corpus.

Follow-up: the chosen `var`-escape approximation is documented in `docs/var-escape.md`.

### Step 10 — Structural module system · `plan/step-10-modules.md`

**Prereq:** Steps 01–09.
**Done when:** the README's `shop/` tree works verbatim (path-as-module, aliasing via `const`); referencing `shop.internal.discounts` from outside `shop` errors naming both modules; a two-module cycle is rejected with the full chain; multi-file fixtures green.

- [x] **T10.1** — Module path resolution (file ↔ module name; collisions are errors).
- [x] **T10.2** — Lazy `Module` values wired into the evaluator's member access.
- [x] **T10.3** — Load-order orchestration; load-once semantics.
- [x] **T10.4** — Reference-graph extraction during checking.
- [x] **T10.5** — `internal/` subtree-privacy check.
- [x] **T10.6** — Cycle detection with chain reporting.
- [x] **T10.7** — In-process caching keyed by content hash.
- [x] **T10.8** — Multi-file test project under `examples/` mirroring the README's `shop/` tree.

Caution: resolved in step 11 — a project roots at the working directory, which
must hold `package.emo` (T11.10); no ancestor is ever consulted.

### Step 11 — Packages & version resolution · `plan/step-11-packages.md`

**Prereq:** Steps 01–10.
**Done when:** the README's `require "acme/json_tools"` scenario runs against a fixture registry; removing a dep from `deps` while its `require` remains is a compile error; conflicting exact pins resolve to the highest and the lockfile checksums verify on a second run; a dep whose `targets` exclude the current target fails at resolution time. **M2 exit criteria met.**

- [x] **T11.1** — `require` parsing + scope rules.
- [x] **T11.2** — Manifest phase A: strict schema parser, errors with spans.
- [x] **T11.3** — Strict require/deps pairing check.
- [x] **T11.4** — MVS resolver with target-compatibility gate; unit tests over version lattices.
- [x] **T11.5** — Lockfile read/write/verify; mismatch errors.
- [x] **T11.6** — Registry client + content-addressed cache + directory registry for tests.
- [x] **T11.7** — Manifest phase B: restricted-profile evaluation with step budget.
- [x] **T11.8** — End-to-end fixture: two local packages, one requiring the other, resolved, locked, built, run.
- [x] **T11.9** — A `deps` key is a string literal: the deps block's one
      spelling, so a package name is never something the lexer must
      accept. **Landed 2026-10-15** across the parser, the manifest
      evaluator and `emo_pkg`. A manifest parses in its own profile
      (`parse_program_in ~manifest:true`, whose only caller is
      `Emo_pkg.parse_manifest`), where a string assignment target is a
      dependency's name and an identifier target stays a package field;
      the `a / b` fold that turned a scoped name into an `Ident` is
      deleted, along with the now-unreachable `E4015` scoped-name check
      it fed. A string-keyed field is `E5102`, so a mistyped field can no
      longer be silently dropped, an empty dependency name is `E5102`,
      and a stray statement inside `deps` is `E5104`. Reason: `emo` is a
      reserved word, so this repository's own
      packages could not pin their scope as `emo/ui` — and a name is
      already data everywhere else (the `name` field, `require`, the
      lockfile, the registry), which left the key as the single place it
      masqueraded as code. 29 manifests migrated (`examples/**`,
      `benchmarks/http_echo`, five stdlib packages, the emo-ui golden),
      every committed lockfile re-resolved, and `projects/emo-ui/` now
      names its package `emo/ui`. The same day, `emo check <FILE>` learned
      the rule the editor already applied: a `package.emo` is read as a
      manifest rather than as a module, so the two agree on what a
      manifest says (`Emo_pkg.is_manifest_file` is where the rule lives),
      and the token-level phase-A manifest helpers that T11.7 superseded
      are gone. `emo run` and `emo build` refuse a manifest named as the
      entry (66) instead of reading it as a program — a manifest is data
      wherever it is read, and a command that needs a program says which
      module to name.

- [x] **T11.10** — The root is where you stand: a project is the working
      directory, which must hold `package.emo`. **Landed 2026-10-16.** The
      nearest-manifest search above the entry file is deleted — the rule
      settled that day is cwd-only, so a missing `./package.emo` is **E5010**
      (``run `emo new <name>` to scaffold a project here``, spanned on the
      directory) and an entry that is not a module of the package rooted
      there is **E5011** (spanned on the entry), both through
      `Static_errors` → 65. Reason: the old search let a manifest-less tree
      silently become a project rooted at cwd — `emo check
      examples/alias_demo/main.emo` from the repository root checked the
      whole repository and reported other examples' errors — and let the
      same file mean different things depending on where the command was
      typed. Every runnable tree that lacked a manifest got one (16
      `examples/`, 7 `benchmarks/`, 6 `spike/`, the release workflow's smoke
      project), and every test invocation now stands in the directory it
      roots at. The LSP tightened the same way: it indexes a project only
      when the root it was handed holds `package.emo`, says so once per
      workspace, and `scan` skips a nested package the way the compiler's
      walk does. Also here: a foreign parameter's contract is now looked up
      under its qualified name, so `foreign def` on a type declared in the
      entry module resolves on the `c` target — a latent bug the standalone
      entry build had hidden.

Also here: swap step 10's transitional root rule for manifest-based roots — done; the root is the working directory, and it must hold `package.emo`.

---

## M3 — Concurrency & networking

### Step 12 — Processes & message passing · `plan/step-12-concurrency.md`

**Prereq:** Steps 01–11.
**Done when:** ping-pong (1M messages) and fan-out/fan-in (1000 workers) run correctly under both the Eio-based and own effects schedulers; a process that raises mid-message dies alone while the parent continues; sending a `Box` yields a snapshot; receive loops recursing millions of times keep the native stack flat; `dune test` green under the deterministic scheduler.

- [x] **T12.1** — Design pass: settle the self-pid mechanism in `CHECK.md` / README (`do`, `<-`, `receive { ... }`, and the `Box` operation set are already decided). Blocking gate for the rest of the step.
- [x] **T12.2** — Process/mailbox abstraction on Eio; spawn/send/receive.
- [x] **T12.3** — Crash isolation; process-exit signals for future supervisors.
- [x] **T12.4** — `Box` with snapshot-on-send semantics.
- [x] **T12.5** — Deterministic scheduler log for tests.
- [x] **T12.6** — Phase B: own effects-based scheduler beneath the same interface.
- [x] **T12.7** — Stress tests: ping-pong, fan-out/fan-in, deep receive-loop recursion.

### Step 13 — Networking library · `plan/step-13-networking.md`

**Prereq:** Steps 01–12.
**Done when:** an Emo HTTP server + client round-trip on localhost runs in one `emo run` program, entirely direct style; a timeout and a refused connection each raise an Emo exception with a precise message; a TLS handshake to a test certificate fails closed on verification error. **M3 exit criteria met.**

- [x] **T13.1** — TCP socket surface on the scheduler; graceful close semantics.
- [x] **T13.2** — UDP + Unix-domain sockets.
- [x] **T13.3** — DNS resolution through the same suspension path.
- [x] **T13.4** — OpenSSL TLS binding; certificate-verification errors surfaced as Emo exceptions.
- [x] **T13.5** — HTTP client; HTTP server with process-per-connection helper.
- [x] **T13.6** — Stdlib packaging with target metadata; fixture-based integration tests (loopback listeners, deterministic order).

Close-out: the exact `net.*` / `http.*` names are in the README (Networking); the stdlib ships as directory-registry packages under `stdlib/registry` with `targets = ["ocaml"]` at the time; the acceptance example is `examples/http_roundtrip`. Step decisions are in `plan/step-13-networking.md` (Close-out). **M3 exit criteria met.**

---

## M4 — Compilation targets

### Step 14 — Native backend · `plan/step-14-native-backend.md`

**Prereq:** Steps 01–13.
**Done when:** every `examples/*.emo` compiles to a native binary producing output identical to `emo run` (golden comparison in CI); specialized numeric code shows measurably better benchmark numbers than the unspecialized build; a process-per-connection HTTP server built with `emo build` sustains a load test; benchmark results recorded.

- [x] **T14.1** — IR definition + checked-AST lowering.
- [x] **T14.2** — Stage A: OCaml emission, runtime linking, single-binary output.
- [x] **T14.3** — `emo build` with incremental caching.
- [x] **T14.4** — Benchmark set wired into CI (numbers recorded, not just pass/fail).
- [x] **T14.5** — Stage B: type-driven specialization passes (unboxing, direct dispatch) behind completeness checks from step 09 data.
- [x] **T14.6** — C FFI linking path once the binding-surface syntax is decided (blocked — settle in `CHECK.md` first).
- [x] **T14.7** — Bootstrap test: the `examples/` suite as compiled binaries matches interpreter output byte-for-byte.

Close-out: Stage A emits OCaml source (tradeoff documented in `docs/ocaml-backend.md`); the IR lives in `src/emo_ir` with the Stage B `specialize` fixed point, and T14.5's specialization landed with the T14.1/T14.2 commits. `foreign def` settled as above, marshaling through generated C wrappers (`emo build` compiles them with `cc`); `Float`/`String`/`Bool` cross the boundary, everything else refuses with E4200. Benchmarks: `benchmarks/results.md` records fib(30) 345ms unspecialized vs 212ms specialized (~1.6x), ping-pong, JSON scan, and an HTTP echo load test at 112 req/s. Bootstrap: all five examples build to binaries matching `emo run` byte-for-byte (the `bootstrap` suite in `test/emo_project`). Decisions are in `plan/step-14-native-backend.md` (Close-out). **Step 14 acceptance met.**

### Step 15 — Other targets: Wasm, TypeScript, BEAM, RISC-V · `plan/step-15-other-targets.md`

**Prereq:** Steps 01–14 (per target). These began as roadmap entries, not execution-ready plans; all four are now promoted to their own step files — TypeScript first (the lowest toolchain risk, 2026-10-02), then Wasm, BEAM, and riscv64.

- [x] **T15.1** — When a target is scheduled, split it into `step-NN-<target>.md` with the full standard format (goal / scope / tasks / acceptance) and update `plan/README.md`'s status table; its tasks continue the numbering (`T17.*`, …).
- [x] **T15.2** — Record which key decision each target settled and where (README / `CHECK.md` / docs) — keep the trail. (Done 2026-10-17: the promotion trail below now covers all four targets and points at each step file's "Decisions settled here" section plus the cross-cutting `README.md` / `CHECK.md` / `docs/numeric-width.md` records.)

Key decisions each target settled: Wasm — **WasmGC** (structs and arrays with RTT dispatch, no custom heap; the custom-GC branch removed) and Int boxing an i64; TypeScript — lowering from the IR, a uniform `async`/`await` mapping with no coloring analysis, and cooperative tasks rather than workers; BEAM — class instances as tagged maps (map equality is Emo's content equality), Core Erlang text assembled by `erlc`, and processes mapped natively; riscv64 — boot profile A, tagged-word dynamic values with boxed `Int64`/`Float64`, the psABI as Emo's internal convention, and a whole-program single artifact.

Promotion trail: **TypeScript → `plan/step-17-typescript.md`** (2026-10-02, first target; its key decisions — IR lowering, uniform async, cooperative tasks, Node networking — are settled in that file). **Wasm → `plan/step-16-wasm.md`** (2026-10-02, second target; GC settled as WasmGC, structs and arrays with RTT dispatch, no custom heap; T16.5's WASI/IO audit closed in favor of refusing `net`/`http` — no usable socket path on the reference host). **BEAM → `plan/step-18-beam.md`** (Core Erlang emission, the value model, native process mapping; net/http and FFI explicitly out). **riscv64 → `plan/step-19-riscv64.md`** (2026-10-05, last; per-task decision trails, close-out recorded, the `%g` float to-string follow-up landed 2026-10-17). Full pointers, including `CHECK.md`'s cross-target entries, are in `plan/step-15-other-targets.md`.

### Step 16 — Wasm target (WasmGC) · `plan/step-16-wasm.md`

**Prereq:** Steps 01–15.
**Done when:** `emo build --target wasm` produces a `.wasm` (plus its `.wat` sibling) that runs on Node's WasmGC, the core subset (hello_world, fib, objects, language_tour, shop) prints byte-for-byte what `emo run` prints (golden in CI), and a package lacking the target fails resolution before any emission.

- [x] **T16.1** — Backend skeleton: `--target wasm` plumbing (resolution gate reads the target); the WAT intermediate; the binary encoder; the boxed-struct value model with RTT dispatch. Golden: hello_world, fib, objects.
- [x] **T16.2** — Full core semantics: patterns and guards, tuples, arrays, Box, interpolation, content equality, interface narrowing, multi-file module references. Golden: language_tour, shop.
- [x] **T16.3** — Bootstrap: the wasm subset in CI, plus the resolution-gate refusal test for packages lacking `"wasm"`.
- [x] **T16.4** — Concurrency: a cooperative driver for `do` / `<-` / `receive`, host-timer preemption points. Golden: pipeline. (Gated on T16.2.)
- [x] **T16.5** — The WASI and IO audit: stdlib metadata for `"wasm"`, and the io goldens where the host supports it. (Done 2026-10-17: the host supports neither network golden. Node's preview1 WASI has no usable socket calls, and the working socket API — preview2's `wasi:sockets` — is component-model-shaped, unreachable from this core WasmGC module; wasmtime's preview1 answers the legacy call `notsock`. `net`/`http` stay undeclared and refuse at resolution; the pure stdlib packages already declare `"wasm"` and run in the golden group, now pinned by resolution tests on both sides.)

**Step 16 acceptance met.** `emo build --target wasm` emits a `.wasm` plus its `.wat` sibling that runs under Node's WasmGC; the core subset and the pure stdlib demos print byte-for-byte what `emo run` prints; packages lacking `"wasm"` fail resolution before emission. The WASI/IO audit closed with an honest refusal: no network goldens are possible on the reference host, and the IO packages' metadata says so.

### Step 17 — TypeScript target · `plan/step-17-typescript.md`

**Prereq:** Steps 01–16.
**Done when:** `emo build --target typescript` emits TypeScript that runs on Node, the examples subset (hello_world, fib, objects, language_tour, shop, pipeline, tcp_echo, http_roundtrip) prints byte-for-byte what `emo run` prints (golden in CI), and a package lacking the target fails resolution before emission.

- [x] **T17.1** — Target plumbing and core emitter: `--target` through CLI, project, and the resolution gate; the IR → TypeScript emitter for the core subset; the tagged-value runtime. Golden: hello_world, fib, objects.
- [x] **T17.2** — Full core semantics: patterns and guards, tuples, arrays, Box, interpolation, content equality, multi-file module references. Golden: language_tour, shop. (Done 2026-10-17: both examples join `ts_golden_tests` and declare `"typescript"` in their manifests. The emitter already handled the surface — the gap was the pin, so no backend change.)
- [x] **T17.3** — Concurrency: cooperative tasks, mailboxes, selective receive, `self_pid`, `halt`. Golden: pipeline.
- [x] **T17.4** — Direct-style IO: sockets and HTTP over Node's APIs as awaited promises; stdlib target metadata gains `"typescript"`. Golden: tcp_echo, http_roundtrip. (Done 2026-10-12: the whole `net` surface rides `node:net`/`node:dgram`/`node:tls`/`node:dns` behind `E.builtin` with one persistent per-connection reader; the root process finishing releases the live handles so the loop drains, matching the native rule. `net` and `http` declare `"typescript"`; tcp_echo and http_roundtrip join the target's goldens. The `c` target stays TCP-only, and the `http` server block's double close — hidden by the native scheduler, surfaced by the TypeScript target — is fixed.)
- [x] **T17.5** — Bootstrap: the target-aware golden suite in CI, plus the resolution-gate test for packages lacking the target. (Done 2026-10-17: `pipeline` joins the `ts_golden` group, completing the subset above; the gate now has a refusing and an accepting test, mirroring the `wasm` pair.)

Close-out: the target-aware golden group (`ts_golden`) pins the subset named above — 25 examples — and the resolution gate is tested both ways. Decisions are in `plan/step-17-typescript.md` (the trail). **Step 17 acceptance met.**

### Step 18 — BEAM target (Core Erlang) · `plan/step-18-beam.md`

**Prereq:** Steps 01–17.
**Done when:** `emo build --target beam` emits Core Erlang text that `erlc` assembles to a `.beam`, and the core subset (hello_world, fib, objects, language_tour, shop, pipeline) prints byte-for-byte what `emo run` prints (golden in CI), with the resolution gate reading `"beam"`.

- [x] **T18.1** — Backend skeleton: `--target beam` plumbing; the Core Erlang emitter (module, defs, literals, call/apply, sequencing) against the probed OTP 29 grammar. Golden: hello_world.
- [x] **T18.2** — The value model and arithmetic: masked i64 wrap-around Int64, binary Strings with interpolation, tuples, arrays, enums, deep content equality. Golden: fib.
- [x] **T18.3** — Classes/instances (tagged maps), Box holding processes, closures as funs, case patterns with guards. Golden: objects, language_tour.
- [x] **T18.4** — Processes (`do` / `<-` / `receive` via the compiler's receive primops), shop multi-module, pipeline golden; the CI `beam_examples` group and the resolution-gate test for `"beam"`.

### Step 19 — RISC-V target (freestanding RV64) · `plan/step-19-riscv64.md`

**Prereq:** Steps 01–14 (the specialization pass); the step-15 RISC-V
reference note is the design record.
**Done when:** `emo build --target riscv64` produces a freestanding ELF
that boots under `qemu-system-riscv64 -machine virt`; every example in
the core subset prints exactly what `emo run` prints (goldens in CI);
`spawn`/`send`/`receive` and `foreign def` refuse with clear
diagnostics; packages without `"riscv64"` fail resolution; `dune test`
green.

- [x] **T19.1** — The backend skeleton: `--target riscv64` plumbing
      (emitter module; the CLI arm writing `main.s`, invoking
      `as`/`ld` with the generated linker script; `emo run` booting the
      ELF under QEMU); the entry stub, BSS clear, SBI console.
      Golden: hello_world (serial output byte-for-byte vs `emo run`).
- [x] **T19.2** — The value model and arithmetic: the tagged-word
      dynamic representation (`Int64`/`Float64` boxed cells, Bool/Char
      immediates) and the bump allocator; wrap-around arithmetic,
      comparisons, `if`, integer formatting (`INT64_MIN` correct);
      guaranteed tail calls as `tail`. Golden: fib.
- [x] **T19.3** — Dynamic-world data structures: tuples, arrays, Box,
      enums, instances with vtable dispatch, closures and first-class
      functions; patterns with guards; interpolation with the `%g`
      float rule. Goldens: objects, language_tour, floats.
- [x] **T19.4** — Bootstrap: the `riscv64_examples` CI group (QEMU +
      cross-binutils on the runner), the resolution-gate refusal test
      for packages lacking `"riscv64"`, the emission-time refusal
      diagnostics, close-out.

**Step 19 acceptance met.** The freestanding RV64 backend
ships — hello_world, fib, objects, language_tour, and floats boot
under QEMU as byte-for-byte goldens, the refusals are loud, and
resolution gates packages. The `%g` float to-string follow-up landed
2026-10-17 (plan/step-19 close-out).

## M5 — Wasm Runtime

The layer is a WebAssembly decoder, validator, and interpreter written
in Emo. It is designed once under a unification gate — a primitive
lands only when it names a concrete near-term need;
`plan/step-20-wasm-runtime.md` holds the project decisions, the
mechanism matrix, and the ladder.

### Step 20 — The systems layer (wasm runtime) · `plan/step-20-wasm-runtime.md`

**Prereq:** Steps 01–19.
**Done when:** `& | ^ << >> ~` work on integer types across the interpreter and all four backends; the `Bytes` core type with little-endian accessors exists; `file.read` loads a file from disk under the scheduler; `Int64` and `Byte` arithmetic wraps on all targets (goldens in CI); `runtime/wasm/` exists as a real package.

- [x] **T20.1** — Bitwise operators (`& | ^ << >> ~`) on integer types: lexer, parser, checker, interpreter, and all four backends; `examples/bit_ops/` golden through `emo run` and every target's CI group.
- [x] **T20.2** — The `Bytes` core type: construction, bounds-checked get/set, little-endian accessors, String interop; all four backends; golden example. (u64 accessors landed with Int64 in T20.4; printing a raw `Bytes` value on wasm shows the buffer's bytes instead of the `Bytes[n]` label — known gap.)
- [x] **T20.3** — `file.read` stdlib package (native, scheduler-direct); a golden example reading a file from disk. Ships `file.write` too (the demo writes its own data file, keeping the golden CWD-independent); the write closes before resuming so read-your-own-write holds; tests resolve the registry via EMO_REGISTRY.
- [x] **T20.4** — `Int64` and `Byte`: literals, wrap-around arithmetic, comparisons, explicit conversions; all four backends; golden example. `runtime/wasm/` package skeleton created here.

Close-out: `Int64` and `Byte` ride the integer representations each target already had — OCaml `int64`/`int`, Erlang integers masked to signed 64 bits, wasm's `$vint`, TS `BigInt`/`number` — so no backend grew a second value model; what each added was the wrap rule (Byte masks to 256 after add, sub, mul, shl, bnot) and the explicit conversions, and `examples/fixed_width/` runs on all four targets. The `Bytes` u64 accessors deferred by T20.2 landed here, since `Int64` is the carrier they needed, and the golden exercises them everywhere. Two backend notes: OTP 29's `erlc` cannot compile a float bit-string pattern, so `Float.from_bits` goes through `binary_to_term` on an ETF float header; and Emo prints floats by OCaml's `%g` rule, which neither Erlang's nor JavaScript's native formatting matches, so both the BEAM runtime and the wasm host implement it. The wasm golden flushed out two runtime bugs the earlier examples never reached: `bytes_from_mem` read linear memory at `i` instead of `ptr + i`, and `int_str` took its digits with signed division, which mangles `INT64_MIN`. Decisions are in `plan/step-20-wasm-runtime.md` (Close-out). **Step 20 acceptance met.**

### Step 21 — Wasm runtime: decoder & validator · `plan/step-21-wasm-decoder.md`

**Prereq:** Step 20.
**Done when:** `runtime/wasm/` decodes and validates the vendored spec suite's binary-form cases — every valid module accepted, every `assert_malformed` case rejected in the decode phase, every `assert_invalid` case in the validation phase; the default `dune test` runs a smoke subset through the Emo-written runtime, and the `wasm_spec` alias runs the full list with nothing pending.

- [x] **T21.1** — The smoke rule: `runtime/wasm/main.emo`, its golden, and a `runtest` rule that runs `emo run main.emo` in the sandbox. The package stops being inert; no registry and no native toolchain (deps are `{}`).
- [x] **T21.2** — The case-list format and its hex codec, the corpus runner, the `main.emo` / `spec.emo` drivers, and the `wasm_spec` alias. Both lists start empty; the summary reports `pending 0`.
- [x] **T21.3** — `devtools/vendor-wasm-spec` (a pinned wasm-spec checkout through `wast2json --no-check`) and the first corpus: `binary.wast`'s binary-form cases, vendored as `pending`. Independent of every decoder task.
- [x] **T21.4** — The diagnosed-failure value and the `Bytes` reader, bounds-checked before every access; the truncated-read fixtures.
- [x] **T21.5** — LEB128 (`u32`/`u64`/`s32`/`s64`) with the spec's length caps; `binary-leb128.wast` plus hand-written boundary vectors.
- [x] **T21.6** — The header and the section walk: magic, version, section id and size, ordering, custom sections, unknown ids, trailing bytes.
- [x] **T21.7** — The type section, and the tag-tuple / cons-list shape the rest of the module model copies.
- [x] **T21.8** — The declaration sections: function, table, memory, global, import, export.
- [x] **T21.9** — Element, data, and constant expressions.
- [x] **T21.10** — The opcode table and the numeric instructions.
- [x] **T21.11** — The parametric, variable, and memory instructions.
- [x] **T21.12** — The structured instructions: block/loop/if/else/end, br/br_if/br_table, and the matching-`end` bookkeeping.
- [x] **T21.13** — `decode(bytes)` on the package's surface, and the valid-module corpus.
- [x] **T21.14** — The validation context, the index spaces, and function typing.
- [x] **T21.15** — The operand type stack for the plain instructions.
- [x] **T21.16** — Control frames: label depths, branch operand types, and the polymorphic stack after a branch.
- [x] **T21.17** — Cross-section rules: start function, element/data offsets, limits, global initializers.
- [x] **T21.18** — The corpus sweep with nothing pending, the smoke subset, `runtime/wasm/README.md`, close-out.

Close-out: the sweep left nothing behind — `wasm_spec` reports 3456 claimed, 0 pending, 0 failed, and the smoke subset (forty cases, every decoder and validator family) rides the default `dune test`. Getting there flushed out bugs older than the validator: br_table's immediate never consumed its default index (present since T21.12 — the leaked byte parsed as an opcode and desynced whole bodies), and the final bulk-memory opcode numbering replaced the pre-merge proposal's. The validator's frame stack carries a logical top (rebuilding per pop was exponential on nested blocks) and pushes land only after truncating to the live prefix; block parameters live inside their frame (push_ctrl semantics), and unreachable frames keep pushed values concrete so `type-num-vs-num` cases still reject. One interpreter limit shaped the code: a method call on a recursive result (`f(n-1).append(x)`) spins past roughly 25 nesting levels, so every array-returning recursion is a tail-accumulator loop — recorded as language pressure. The datacount rule splits by phase: with a data section present, bulk-memory use without a datacount is malformed; without one, the validator's unknown-segment check makes it invalid — both pinned by the corpus. The declared-reference set (globals, exports, element segments — not the start function) types `ref.func`. **Step 21 acceptance met.**

The boundaries that keep the in-repo runtime from becoming an in-repo language — the package edge, the spec data off the default test path, and the condition for the runtime leaving this repository — are in the plan file, with the surface pressure the runtime runs into and the sizes that make the list workable in spare sittings.

### Step 22 — Wasm runtime: interpreter core & spec-suite goldens · `plan/step-22-wasm-interpreter.md`

**Prereq:** Step 21.
**Done when:** `runtime/wasm/` executes a validated module — instantiate (imports resolved through a register namespace and the `spectest` host module, segments laid out with the spec's trap-on-overflow, start run), invoke exports, and report values or the first trap. The `wasm_runs` alias runs the vendored run corpus (every `assert_return` bit-exact including NaN payload classes, every `assert_trap` and instantiation failure where the spec says) with nothing pending; the default `dune test` runs a smoke slice of both corpora.

- [x] **T22.1** — The run-list format and its codec (type-tagged bit-pattern words, NaN tokens, verdict prefixes), the run runner beside step 21's, the `runs.emo` driver, the `wasm_runs` dune rule, and `vendor-wasm-spec runs` writing the command corpus as all-`pending`. Independent of every execution task.
- [x] **T22.2** — The instance model: a validated module materialized as frozen records — functions as signature + body byte range, the index spaces, the segments, imports, exports, start, the declared reference set — with `wasm.load(bytes)` on the package surface returning module-or-verdict.
- [x] **T22.3** — The value model: i32/i64 as masked patterns, f32/f64 as bit patterns that convert to `Float64` only at an operation, references as tagged pairs; the NaN payload discipline and the comparison codec. Fixtures first — no execution yet.
- [x] **T22.4** — The integer families as pure functions: wrap-around arithmetic, shifts and rotates, clz/ctz/popcnt, division and remainder with their traps, sign extension, saturating truncation, wrap and extends. Boundary fixtures from the spec.
- [x] **T22.5** — The float families: arithmetic and comparisons through the bridge; conversions including truncation traps, promote/demote with correctly-rounded bit surgery (no `Float32` in the language), reinterpret as a pattern move. Conversion-boundary fixtures, NaN classes included.
- [x] **T22.6** — The store: linear memory on `Bytes` (page-granular grow, bounds before access, little-endian widths), tables with grow/size/fill/copy/init, mutable globals; traps as values. Fixtures at the OOB edges.
- [x] **T22.7** — The frame machine: the operand arena of u64 slots, locals and the variable instructions, structured control by recursion with branches as unwind signals, `call`/`call_indirect` with their traps, `return`, `unreachable`. A `fac` fixture proves the tail-call chain.
- [x] **T22.8** — Instantiation and linking: import resolution through the register namespace and host, global initializers, segment layout with trap-on-overflow (`assert_uninstantiable` fails here, store discarded), the start function, `register`. Link failures for missing or mismatched imports.
- [x] **T22.9** — The `spectest` host module: the print functions, typed globals, table, and memory behind the same import interface.
- [x] **T22.10** — Sweep I: the run families claimed in order — integers, floats, conversions, control flow, calls — each flip its own sitting; residuals stay pending.
- [x] **T22.11** — Sweep II: addressing and endianness, memory and table operations, segment initialization, linking through the register namespace, imports through spectest, the trap cases, and the leftovers — the run list ends at zero pending and zero failed.
- [x] **T22.12** — Close-out: the run-list smoke slice rides `dune test`, `runtime/wasm/README.md` grows the execution surface, acceptance recorded here and in `docs/TASKS.md` (both languages).

Close-out: the sweep ends at **25135 claimed, 0 pending, 0 failed** over the vendored run corpus — every `assert_return` bit-exact (NaN classes for the NaN tokens), every `assert_trap` and instantiation failure where the spec says, `register` and linking behaving — and the default `dune test` runs a smoke slice of both corpora. The gate produced one language addition, the float primitives `Float64.sqrt`/`floor`/`ceil`/`trunc`, `Float64.to_int64`, and `Int64.to_float64` (`CHECK.md`). The run driver is compiled: the evaluator is correct but cannot carry the loop-heavy memory tests past its recursion limit, and native compilation needed the boxed-`Int64` route plus module-level-`var` support, both landed here. **Step 22 acceptance met.**

The boundaries step 21 recorded bind unchanged (package edge, spec data off the default test path, the split condition), and the standing rule from step 21's sweep — no method call on a recursive result — is formal in the plan. The pressure notes (`Int32`/`Float32` masking, the growable-buffer arena, the recursion limit, argv) are the gate's raw material, not tasks.

## M6 — Self-contained hosted backend

The hosted half of the self-contained story: Emo's own runtime, the
C ABI as the FFI surface, and no OCaml toolchain in the produced
binary — once this ships, building Emo programs no longer requires an
OCaml toolchain either (CHECK.md, tool distribution). The hosted-native-FFI assessment
(`plan/hosted-native-ffi.md`) is this milestone's design record — an assessment, not a task-bearing step,
which is why no section appears in this file. Step 19's study
shares the tagged-word value model.

### Step 23 — C target (emit C) · `plan/step-23-c-target.md`

**Prereq:** Steps 01–14 (the IR); `plan/hosted-native-ffi.md` is the design record this step schedules.
**Done when:** `emo build --target c` emits C, compiles with the system `cc`, and links a standalone binary with no OCaml runtime; the golden subset (hello_world, fib, objects, language_tour, shop, pipeline, function_group, bit_ops, bytes, fixed_width, file_read) prints byte-for-byte what `emo run` prints (golden in CI); `foreign def` crosses the direct C ABI; a package lacking `"c"` fails resolution; `dune test` green.

- [x] **T23.1** — Design-gate closure (CHECK.md: route confirmed emit-C, trampoline settled, arena provisional) and the backend skeleton: the emitter module in `src/emo_codegen` + the `--target c` CLI arm invoking `cc`; entry stub, hosted startup, `println`; `"c"` enters `known_targets` with the resolution-gate refusal test. Golden: hello_world.
- [x] **T23.2** — Tail calls and the integer core: the trampoline (self/mutual tail calls, `return` as branch-to-epilogue — the fix for the current backend's ~4x loop regression); wrap-around `Int64` on `uint64_t`; comparisons, `if`, `INT64_MIN`-correct formatting. Goldens: fib; the 1M-deep `count_down` stays flat on the C stack; `loops_tail` recorded in `benchmarks/results.md` (4 ms — the OCaml backend's specialized build takes 1910 ms). The examples/fib golden itself waits on closures (T23.5) — its `greeting` needs them; the `c_integer` fixture covers fib, count_down, a mutual-tail cluster, and wrap-around, under a 1MB C stack. Also fixes the checker's span-type table (keyed by start offset alone, later checks overwrote nested expressions' types) and the wasm/beam backends' ClassType dispatch that the fix exposed.
- [x] **T23.3** — The scalar runtime: length-prefixed strings (NUL-terminated only at the FFI boundary), the `%g` float rule, `Bool`/`Char`, interpolation, scalar content equality. Goldens: numerics, if_expr. (Done 2026-10-06: if_expr is the first full-example golden; numerics itself waits on `foreign def` (T23.8) and tuples (T23.4) — the `c_scalar` fixture cross-checks the printing rules against the interpreter's own rendering instead. The string layout and the runtime-in-C decisions are recorded in CHECK.md.)
- [x] **T23.4** — The dynamic value model: step 19's tagged word (8-byte-aligned cells, 3 tag bits; `Int64`/`Float64` boxed two-word cells; no NaN-boxing), bump/arena allocator (provisional), tuples, value-semantic arrays, `Box`. Golden: objects. (Done 2026-10-06: the tagged word is live — one `emo_value` word, low bits 000/001/011 for pointer/Bool/Char, cell kinds in the header word — with bump allocation and malloc-leak documented in CHECK.md's provisional profile. Regime conversion (`emo_box_*`/`emo_unbox_*`) bridges native and dynamic code at every call, binding, return, and operator; dynamic `+`/comparisons/equality dispatch in the runtime per the interpreter's rules; `to_string` renders tuples `(a, b)`, arrays `[a, b]`, Box as `<box>`. The objects golden waits on classes (T23.5) — the `c_dynamic` fixture cross-checks the dynamic world against the interpreter's own rendering instead.)
- [x] **T23.5** — Classes, enums, interfaces, closures: instances with compile-time vtables, enum singletons, structural `is()`, patterns with guards; the reclamation decision lands in CHECK.md before this merges. Golden: language_tour. (Done 2026-10-06: language_tour AND objects both full-example goldens, byte-for-byte. Vtables carry method sigs with dynamic-convention thunks — class-typed receivers dispatch directly, interface/Unknown receivers through `emo_send`; `is()` compares vtable identity (classes) or shape (interfaces); closures take the canonical dynamic convention `[header][fn][captured...]` with creation-site capture analysis and direct dynamic returns; `case` lowers to sequential test/bind/guard blocks with goto-chained fall-through. The reclamation decision settled in CHECK.md: reference counting over the identity objects, arena for value-semantic data — the retain/release emitter work lands before T23.9 makes long-running programs real.)
- [x] **T23.6** — Modules and exceptions: multi-file module references, `raise`, uncaught-exception exit codes (`begin`/`catch`/`ensure` stays unscheduled — out of scope). Goldens: shop, function_group (free via IR lowering — claim the golden). (Done 2026-10-06: both goldens claimed byte-for-byte. Multi-file references needed two call-site fixes — funsigs now carries the callee's declared result so a cross-module call the checker types Unknown still converts, and the IR no longer lowers module-alias const bindings as thunks (they bound a path, not a value); group-const thunks return Unknown, not Void. `raise` renders the interpreter's E3010 message to stderr and exits 1 in the root process — no unwinder until `begin`/`catch` lands; a spawned process's raise ends only that process, per step 50.)
- [x] **T23.7** — The systems-layer surface: `Bytes` with little-endian accessors, the bitwise operators, `Byte`, `Int64`/`Float64` bit-casts. Goldens: bit_ops, bytes, fixed_width. (Done 2026-10-06: all three full-example goldens byte-for-byte. `&`/`|`/`^` are exact two's-complement on int64_t; `<<`/`>>` guard the count (negative errors, ≥64 gives 0/sign-fill) in the runtime; Byte is uint8_t with wrap-by-truncation and the Int64 div/shift guards; a Byte in the dynamic world materializes as an Int64 cell. Bytes is a new cell kind with in-cell storage, `to_bytes`/`to_string` interop, and a runtime `to_string` method dispatch (Bytes content vs value rendering) — the interpreter's runtime dispatch, mirrored. The checker now types `Unknown + Unknown` as Unknown (the runtime dispatches `+` per the values — neither result is provable); C reserved words in Emo defs get a `_c` suffix.)
- [x] **T23.8** — C FFI rungs 1–3 on the direct C ABI (no wrapper generator): scalars, width types as they land, opaque handles + copied buffers; the capability table flips `c` to honoring `foreign def`. Goldens: a libm `sqrt` fixture and a tiny C opaque-handle fixture under `test/`. (Done 2026-10-06: the c backend emits `extern` declarations and calls the symbol directly — no wrappers. Strings cross with a NUL terminator (`emo_str_cstr` out, `emo_str_from_cstr` in, per CHECK.md's layout decision); Int64 crosses as `int64_t` — the capability table is now target-aware in the checker (`c` admits Int64, the OCaml backend stays Float64/String/Bool); opaque handles ride pointer-sized Int64s behind a tiny externally-owned counter library, explicitly closed, in the `c_foreign` test group alongside the libm fixture.)
- [x] **T23.9** — Processes and the cooperative scheduler: `do` / `<-` / `receive`, mailboxes, selective receive, `self_pid`, `halt`; single-threaded cooperative loop; traces diffed against `emo_sched_det`. Goldens: pipeline, showcase. (Done 2026-10-06: both full-example goldens byte-for-byte. Each Emo process is a ucontext fiber with its own stack; the scheduler keeps emo_sched_det's policy — FIFO run queue, spawn enqueues the child without suspending the spawner, send delivers + wakes + re-queues the sender at the tail, receive scans the mailbox in generated code for the first message a branch accepts (a failed guard leaves the message queued) and parks the fiber when nothing matches; an empty run queue with parked fibers is a reported deadlock. Pids are an EMO_PID cell (rendered `<pid N>`); `EMO_TRACE=1` prints spawn/send/park/dispatch/exit/reap events for diffing. Also fixed en route: the entry file discovered twice (root + tree copies, keyed by a `/.`-carrying path) lowered every symbol under two manglings — the walk now normalizes file paths and the IR dedupes module copies by the parsed items' physical identity.)
- [x] **T23.10** — Hosted IO and stdlib metadata: `file.read`/`file.write`, TCP/UDP sockets, the HTTP client/server over the hosted OS; stdlib gains `"c"` in `targets`. Goldens: file_read, tcp_echo, http_roundtrip. (Done 2026-10-06: all three full-example goldens byte-for-byte, including the stdlib http/net packages compiling on the c target. Sockets are non-blocking fds whose would-block reads park the fiber — the scheduler polls parked descriptors while the run queue is empty; the root process finishing ends the program. Cross-module Unknown receivers dispatch by method/field NAME (globally runtime-owned names, runtime helpers; instance fields by vtable name). Unix sockets, TLS, DNS resolve, and UDP compile as honest runtime refusals. The stdlib file/net/http packages and the three examples declare `"c"`, lockfiles regenerated.)
- [x] **T23.11** — Bootstrap, benchmarks, close-out: the `c_examples` CI group; specialization (unboxing, direct dispatch) with `restrict` on hot loops; `benchmarks/results.md` gains the `c` column; the `native` → `ocaml` rename lands here or in its own step; close-out records the decisions. (Done 2026-10-06: all six benchmarks recorded on the c target — fib 7 ms, tail loop 4 ms (470x under the OCaml backend's specialized build, 1.3x from the C baseline), ffi 46 ms, bytes 43 ms, json 3 ms, http 83 req/s. Specialization is structural: the two-regime emitter already unboxes natives and dispatches directly where types are known; `restrict` waits for pointer-parameter loops (the buffer rung). The rename is its own step, next.)

## M7 — Toolchain

The last mile of the self-contained story, and the toolchain
release, with the official 1.0 following.
M6 removed the OCaml toolchain from the *programs*; M7 removes the
installation burden from the *tool* — the release engineering
`CHECK.md` left unscheduled, on the decided direction
(`docs/toolchain-distribution.md` is the design record): prebuilt
binaries per platform on GitHub Releases as the primary channel,
`opam` and a Homebrew formula as the source-building alternatives,
and the command set a product needs — `emo new`, `emo deps`,
`emo doctor` join `run`/`repl`/`check`/`build`/`publish` — so
a machine with nothing but the binary runs, checks, builds (through
the `c` target), pins and resolves dependencies, and publishes.

Boundaries, stated plainly: the public registry *service* is a
separate milestone — the tool ships speaking the filesystem registry
plus the bundled stdlib (`publish` already speaks HTTP; fetching
over HTTP lands with the service it talks to); native Windows is not
this release — WSL2 is the supported Windows path, and the
ucontext/socket port of the C runtime is the recorded blocker
(Microsoft Trusted Signing stays the recorded signing route for when
it lands); the c backend's recorded follow-ups (retain/release
emission, the zero-copy buffer rung, cross-module type propagation)
are backend work and stay with the backend line.

### Step 24 — Toolchain distribution & release · `plan/step-24-toolchain.md`

**Prereq:** Step 23 (the `c` target; the `native` → `ocaml` rename landed with it).
**Done when:** the release workflow, run on a version tag, produces
signed per-platform archives (Linux x86_64/aarch64, macOS
x86_64/arm64) whose binaries pass the end-to-end acceptance on every
platform; a machine with only the installed binary — no OCaml, no
opam, no repository — runs, checks, and builds Emo programs through
the `c` target, scaffolds with `emo new`, pins dependencies with
`emo deps add`, and diagnoses its environment with `emo doctor`;
`dune test` green.

- [x] **T24.1** — Design-gate closure and the default target: the
      four settlements recorded in `CHECK.md` — the build default
      flips `ocaml` → `c`; the stdlib embeds as generated data (the
      C runtime's mechanism) over a sidecar tree; `emo install` is
      the project-dependencies frontend (global executable
      installation out of scope for 1.0); the dependency cache
      leaves the temp directory for a durable user location. The
      flip lands here, with the resolution-gate tests and the CI
      groups re-pointed — the c goldens already cover the target;
      only the default moves. (Done 2026-10-07: all four settled in CHECK.md; the flip moved every default path to c and exposed that the content-hash cache lived only in the ocaml arm — the c arm gained it; ocaml-backend harnesses and benchmarks pinned --target ocaml; tree-wide @fmt drift promoted. Amended 2026-10-17: the `emo install` command was removed; `emo deps` and the build path own resolve/fetch/lock.)
- [x] **T24.2** — The self-contained binary: the bundled stdlib as
      generated data inside the compiler; the registry endpoint
      becomes a filesystem directory or the embedded stdlib;
      `EMO_REGISTRY` still overrides. Verification: a lone `emo`
      copied into an empty directory runs, checks, and builds a
      stdlib-importing program — and `publish`'s embedded uploader
      works from it. (Done 2026-10-07: generated data via devtools/gen-stdlib-data.sh; the macOS sandbox materializes the source_tree dep as symlinks — the generator walks -type f -o -type l, found by probe; endpoint is Fs_dir or Embedded; lone-binary verification passed (run/check/build/publish); embedded-vs-filesystem checksum parity pinned by a test.)
- [x] **T24.3** — `emo new <name>`: the scaffold — `package.emo`
      (name, version, targets) and a hello-world `main.emo`, plus
      `.gitignore`. Strictness holds: an existing directory or
      clashing files refuse with clear errors, no `--force`. The
      scaffold is green the moment it exists — CI creates, checks,
      runs, and builds one. (Done 2026-10-07: CI scaffolds/checks/builds/runs one; owner/name taken as given on relative single-slash args; refusals exit 65.)
- [x] **T24.4** — `emo install`: read the manifest, resolve against
      the registry, fetch into the user cache, write
      `package.lock`; idempotent re-runs change nothing; each
      failure mode — no registry configured, unsatisfiable pin, a
      dependency lacking the requested target — gets its own clear
      message. `emo deps` keeps resolve/update/list as the explicit
      paths. (Done 2026-10-07: idempotent; lockfile written only when it would change; cache default moved to ~/.cache/emo (XDG honored, EMO_CACHE_DIR overrides). Amended 2026-10-17: the `emo install` command was removed; the resolve/fetch/lock behavior it fronted lives in `emo deps resolve` and in the build path's own resolution.)
- [x] **T24.5** — `emo doctor`: the target-aware environment check,
      replacing the interim ocaml-only shape in `CHECK.md`. Per
      target: `c` — a cc compile-and-run smoke; `ocaml` — the
      runtime `.cmxa` found in the switch, or the honest "prebuilt
      installation: the ocaml target needs a source install
      (`opam install emo`)"; `typescript` — node; `beam` — erlc;
      `wasm` — nothing. Plus the installation shape (prebuilt vs
      source), stdlib presence, and version. Exit non-zero only on
      what is actually broken. (Done 2026-10-07: source-vs-prebuilt via the runtime .cmxa set; the c smoke decides the exit code; ocaml unavailable reports the opam install fix.)
- [x] **T24.6** — Release packaging and CI: the tag-triggered
      workflow beside the existing CI — per-platform matrix builds
      (Linux x86_64/aarch64, macOS x86_64/arm64), release binaries
      through dune, the archive layout T24.1 settled, `SHA256SUMS`,
      a drafted GitHub Release. The Linux binary is portable —
      static or the oldest viable glibc — verified in clean
      containers, not on the builder. (Done 2026-10-07: package-release.sh verified end to end locally; matrix = linux x86_64/aarch64 (ubuntu-22.04, glibc 2.35) + macOS x86_64/arm64, suite run before packaging, Linux verified in a clean ubuntu:22.04 container.)
- [x] **T24.7** — Signing and the platform gates: macOS codesign
      (hardened runtime) → notarytool → staple, credentials in CI
      secrets — the solved-not-a-blocker from `CHECK.md`, now
      scheduled. Windows: WSL2 documented as the supported path,
      the native prebuilt recorded as deferred with the
      ucontext/socket port named as the blocker;
      `docs/toolchain-distribution.md` updated (both languages). (Done 2026-10-07: four secrets gate codesign → notarytool → staple; absent secrets ship unsigned with a notice; distribution docs updated both languages.)
- [x] **T24.8** — Provisioning channels and install docs: the
      Homebrew formula (own tap; core when the project qualifies)
      and the opam package — the source channel that brings the
      `ocaml` target. README install sections in both languages:
      prebuilt archives first, then brew, opam, WSL2. (Done 2026-10-07: formula at devtools/homebrew/emo.rb for the own tap, checksums filled at release; dune-project generates emo.opam (no dev_repo field in the stanza — dropped); README install sections in both languages.)
- [x] **T24.9** — Release acceptance and the release cut: on every shipped
      artifact, end to end — download, unpack, `emo doctor`,
      `emo new`, `emo run`, dependency resolution, `emo build` (the `c`
      target) — including a stdlib-importing program and the golden
      subset executed from the installed binary. the release commit
      carries the released VERSION; annotated tag, release notes,
      close-out. (Done 2026-10-07: acceptance ran against the packaged-and-unpacked archive — doctor healthy in the prebuilt shape; new → run → build green, with `emo install` resolving through the embedded stdlib (the `emo install` command was removed 2026-10-17; `emo deps resolve` and the build path now own that step); goldens 14/14 from the installed binary (13 via emo run byte-for-byte, numerics via its designed compiled path — it crosses foreign def, which emo run refuses; http_roundtrip/tcp_echo ride the in-tree suite).)

Close-out: recorded 2026-10-07 in `plan/step-24-toolchain.md` — the
acceptance ran against the packaged artifact, not the build tree; the
default-target flip moved every default path to `c` (and flushed out
that the content-hash cache had only ever lived in the ocaml arm),
the embed's dune rule needs `-type f -o -type l` because the macOS
sandbox materializes `source_tree` deps as symlinks, and the archives
ship without an install script. **Step 24 acceptance met.** M7 is
done: the toolchain release accompanies the official 1.0.

## M8 — Target independence

The host/target distinction made load-bearing. The host language (how
emo was built — today OCaml) answers one question; the targets (what
emo turns your program into) answer another. Fully honoring the split
means the host contributes only the emitters: every target's runtime
lives in the target's own ecosystem, never beside the binary and never
in the host build tree — so a future host rewrite (Go, or another
host entirely) touches only the emitters.

The audit found three of five targets already there — **c** (standalone
C runtime embedded as generated data, the pattern to generalize),
**wasm** (runtime compiled into the module; the 3 imports are the ABI
with the wasm engine, a different axis), **beam** (one self-contained
Core Erlang module standing on OTP). Two are not: **typescript** ships
its runtime prelude as a side file and is therefore broken on every
installed binary (the release layout carries only `bin/emo`), and
**ocaml** links the host's own eight libraries out of the host build
tree, which is why it works only in-tree — and why `opam install emo`
does not bring it (verified: the opam install set is seven files, zero
`.cmxa`).

### Step 25 — Target independence · `plan/step-25-target-independence.md`

**Prereq:** Step 24 (the toolchain whose claims this step corrects).
**Done when:** no target reads its runtime from beside the binary or
the host build tree — c, ocaml, and typescript runtimes ride inside
the compiler as generated data, wasm and beam inside the emitted
module; `emo build --target ocaml` works on any installation where
the OCaml toolchain is on PATH, with no `.cmxa` lookup and no
installation-shape conditionals; the typescript target works from the
release layout; all goldens byte-for-byte; `dune test` green.

- [x] **T25.1** — The principle and the ts embed: the
      runtime-independence principle recorded in `CHECK.md`; the ts
      prelude embedded as generated data (the C runtime's dune rule
      pattern), the typescript arm stopped from reading the
      filesystem. Verification: a lone release-layout binary compiles
      a typescript program; the ts goldens byte-for-byte. (Done
      2026-10-07: the prelude rides `emo_codegen/ts` as generated data
      and the CLI never touches the filesystem for it; a lone binary
      compiles and runs a ts program; the seven ts goldens green.)
- [x] **T25.2** — The emitted-code inventory and the standalone
      skeleton: emit the golden subset through the ocaml emitter,
      collect mechanically every host symbol the emitted code
      references, and record the inventory as the standalone runtime's
      contract; the skeleton compiles with plain `ocamlopt`, zero
      `emo_*` dependencies, proven by a fixture from the build
      directory alone. (Done 2026-10-07: two modules and 70-odd
      symbols recorded in the plan as the contract, collected by
      `devtools/ocaml-runtime-inventory.sh` over the sixteen-example
      golden corpus with a stray-module alarm; the skeleton lands with
      the ADT, signals, and effects final.)
- [x] **T25.3** — The value and scalar core: the value ADT, strings,
      print/interpolation rendering, arithmetic/comparison dispatch,
      and the case/error paths the inventory names, standalone. Each
      piece covered by a fixture compiled against the runtime alone.
      (Done 2026-10-07: five fixture programs in the emitter's call
      shape, compiled with `ocamlopt -open Emo_ocaml_runtime` against
      the extracted runtime alone.)
- [x] **T25.4** — The scheduler and IO: the effects-based scheduler,
      file IO, and networking, per the dependency policy (the OCaml
      standard library plus `unix`; `ssl` as the one opam dep; no eio).
      Fixtures: a process program and an HTTP roundtrip compiled
      against the standalone runtime alone. (Done 2026-10-07: the det
      scheduler ports whole — spawn/send/receive, fd and timer parking,
      TLS, UDP, file IO; eio drops out, the policy settles on unix plus
      ssl; four more fixtures ride the scheduler.)
- [x] **T25.5** — The cutover: the ocaml emitter's references flip to
      the standalone runtime; the arm emits runtime + `main.ml` and
      invokes `ocamlopt` (ocamlfind only for the runtime's own
      packages); the `.cmxa` machinery, the library scan, and the
      beside-binary lookup are deleted; refusal and doctor wording
      become installation-independent. All ocaml goldens and tests
      byte-for-byte; an installed binary with an OCaml toolchain
      builds the golden subset. (Done 2026-10-07: the arm writes
      runtime + main.ml and compiles them with the target's own
      ocamlopt; the cmxa machinery, the library scan, and the
      beside-binary lookup are deleted; all sixteen goldens match
      byte-for-byte and the emitted main.ml is unchanged; a lone
      release-layout binary builds the golden subset.)
- [x] **T25.6** — The independence audit and close-out: wasm and beam
      recorded as verified-independent (no tasks — evidence noted);
      the docs corrected (`docs/toolchain.md`,
      `docs/toolchain-distribution.md` — the true ocaml-target story
      replaces "a source install brings the ocaml target");
      `benchmarks/results.md`'s ocaml column re-run against the
      standalone runtime; close-out. (Done 2026-10-07: wasm and beam
      recorded verified-independent in the plan; both toolchain docs
      corrected bilingually — the true ocaml-target story replaces the
      source-install story, and doctor lost its installation line; the
      benchmark suite re-ran on the standalone runtime with the ocaml
      rows within the machine's observed run-to-run noise; plan status
      done.)

Step 25 complete 2026-10-07 (T25.1–T25.6 on
`feat/target-independence`): no target reads its runtime from beside
the binary or the host build tree; the ocaml target works from a lone
release-layout binary wherever the OCaml toolchain is on PATH; the
typescript target likewise; all goldens byte-for-byte and `dune test`
green.

## M9 — For / While loops

The loop surface `CHECK.md` settled (2026-10-06): guaranteed tail calls
stay, and `for` / `while` join them. `for var i = 0; i < n; i = i + 1 { ... }`
is paren-less with exactly three clauses, the header `var` scoped to
header and body; `while cond { ... }` is condition-only; `break` and
`continue` are bare statements bound to the nearest enclosing loop; no
`do`/`while`, no `+=`/`++`. The rationale: loops are the native shape
for the vectorizer and the OpenMP parallel-loop rung (the HPC gate),
they remove the tail-position proof burden from loop code, and they
pair with `var` — while the var-escape rule (E4012) already fences the
Go loop-capture trap. The design lives in `CHECK.md` and the README;
each step's plan file is written when the step starts.

### Step 26 — Loop surface: lexer, parser, checker, interpreter

**Prereq:** Step 25.
**Done when:** the README's loop snippets run verbatim through
`emo run`; the CHECK.md worked example (`for var i = 0; i < 100;
i = i + 50`) prints `i = 0` then `i = 50`; a 10M-iteration `while`
keeps the stack flat; every refusal — a reserved word used as an
identifier, a missing clause, `;` outside a `for` header,
`break`/`continue` outside a loop — has its own diagnostic;
`dune test` green.

- [x] **T26.1** — Keywords: reserve `for`, `while`, `break`,
      `continue` in the lexer; the LSP completion list and the VS Code
      grammar flip in lockstep; code using the four words as
      identifiers reports a clear reserved-word diagnostic. (Done 2026-10-11.)
- [x] **T26.2** — Parser: `while cond { }` and the three-clause `for`
      — no omissions, the post clause an assignment, `;` a token legal
      only inside a `for` header, `suppress_block_sugar` set on the
      `while` condition and all three `for` clauses so the trailing
      `{` opens the body; AST nodes for the four statements. (Done 2026-10-11.)
- [x] **T26.3** — Checker: the header `var` scoped to header+body in
      the existing depth model; `break`/`continue` bind to the nearest
      enclosing loop and are rejected outside one; `definitely_returns`
      accounts for loops so `return`-reachability stays sound;
      capturing the header `var` in an arrow block stays E4012. (Done 2026-10-11.)
- [x] **T26.4** — Interpreter: the four statements in `eval_stmt`; the
      iteration runs a host loop, never recursion — 10M iterations
      flat; `continue` runs a `for`'s post clause first; the step
      budget counts each iteration. (Done 2026-10-11.)
- [x] **T26.5** — Example and rejections: `examples/loops` — the
      worked example, `while` counting, `break`/`continue`, nested
      loops — golden through `emo run`; the parser and checker
      rejection corpus pinning every refusal. (Done 2026-10-11.)
- [x] **T26.6** — README alignment: the README (English + zh-CN)
      already documents the settled syntax — verify it against the
      implemented surface and reconcile any drift. (Done 2026-10-11.)

Step 26 close-out (2026-10-11, on `feat/loops`): the loop surface is
live in the lexer, parser, checker, and interpreter, one commit per
task. `;` became a token whose only legal home is a `for` header
(E2025), and the header's shape is parse-time law — the init clause a
`var`, the post clause an assignment, no clause optional (E2026), with
block sugar suppressed in every clause. The checker splits the loop
into two scopes — header, then body as its child — so the header `var`
sits a level below any arrow block in the body and capturing one is
the ordinary var-escape error (E4012); `break`/`continue` bind to the
nearest loop through a `loop_depth` field that arrow blocks reset to
zero (E4022 outside a loop), and no loop shape counts as a return
point. The interpreter runs each iteration as an OCaml tail loop with
a fresh body frame — 10M iterations verified flat — `continue` still
runs a `for`'s post clause, and the step budget counts every
iteration, which is what keeps the restricted config profile
terminating now that loops exist. `examples/loops` is golden through
the interpreter; the six backends refuse the loop statements loudly
until step 27 lowers them.

### Step 27 — Loops on every target: IR and the six backends

**Prereq:** Step 26.
**Done when:** `examples/loops` compiles on c, ocaml, typescript,
wasm, beam, and riscv64, each printing byte-for-byte what `emo run`
prints (goldens in CI); a 10M-iteration loop stays flat on every
target; the tail-call guarantee is untouched (`loops_tail` unchanged);
`dune test` green.

- [x] **T27.1** — IR: the loop statements in `emo_ir`'s `stmt` and the
      Ast→IR lowering — the header `var` as a loop-scoped mutable
      binding; one node set, every backend a case. (Done 2026-10-11.)
- [x] **T27.2** — c: the emitted C's own `while`/`for` with native
      `break`/`continue`; `return` inside a loop rides the existing
      branch-to-epilogue. (Done 2026-10-11.)
- [x] **T27.3** — ocaml: native `while`/`for` over the existing `ref`
      discipline for the header `var`; `break`/`continue` lower
      through the one mechanism the plan file records (a done flag or
      a local exception — decided, never a silent fallback).
      (Done 2026-10-11 — the mechanism: one pair of local exceptions
      per loop, `Break_N`/`Continue_N`; `continue` unwinds to the
      handler above the post, `break` past the whole while.)
- [x] **T27.4** — typescript: native `while`/`for` in the emitted
      body; `break`/`continue` are the target language's own.
      (Done 2026-10-11. Also fixed a pre-existing backend bug the
      loops golden exposed: `stmts` emitted the rest of a chain before
      its head — sprintf arguments evaluate right-to-left — so a `var`'s
      ref registration landed after the statements that needed it; the
      head now emits first. The self-tail-call driver loop gained the
      `__emo_driver` label so a tail call inside a loop continues the
      driver, not the Emo loop.)
- [x] **T27.5** — wasm: structured control flow — `Loop` with `Br_if`
      on the condition; `break` branches out of the loop block,
      `continue` to the head, the post clause running first.
      (Done 2026-10-11. For lowers to `block $exit { init; loop $head {
      test; br_if $exit; block $post { body } post; br $head } }`, so a
      `continue` lands on the post and a `break` leaves past it; frame
      depths are tracked for statement-level ifs and case dispatches so
      branch depths stay relative-correct inside nested control flow.)
- [x] **T27.6** — beam: the loop lowers to a tail-recursive local
      function — condition guard, body, recursive call with the
      rebound variables; `break` threads a done marker.
      (Done 2026-10-11. Each loop is a hidden module function taking
      the header `var` plus every outer binding the body reads or
      assigns, threaded through the recursive calls; a done flag
      marks `break`, `continue` applies the post first. The body
      emits as a tail chain — ifs weave the rest into their arms,
      jumps truncate the dead rest — so every jump is a genuine tail
      call; Core Erlang's `do` only tail-calls its last operand.)
      (Also fixed: the single-statement `Assign_var` path registered
      the shadow before evaluating the value, so `n = n + 1` read the
      variable it was defining.)
- [x] **T27.7** — riscv64: labels and conditional branches — the loop
      head a label, `break`/`continue` jumps.
      (Done 2026-10-11. While is `head: test; beqz exit; body; j head`;
      a `for` puts a post label between the body and the jump back, so
      `continue` lands on the post and `break` leaves past it. The
      header `var` is a frame slot, the existing discipline. The value
      heap's no-reclamation arena — shared with the pre-loop
      tail-recursive idiom — still bounds long-running programs;
      unchanged by this task.)
- [x] **T27.8** — Goldens and benchmarks: `examples/loops` on all six
      target golden lists; a plain-loop row beside `loops_tail` in
      `benchmarks/results.md`; the CI groups; close-out. (Done
      2026-10-11. The riscv64 target gained `/` and `%` — `div`/`rem`
      with a zero-division abort — so the example boots there; the
      plain-loop benchmark records the ocaml target's dynamic-by-
      construction number beside the c target and the interpreter.)

Step 27 close-out (2026-10-11, on `feat/loops`): the loop statements
lower on all six targets, one commit per task. The IR carries
While/For/Break/Continue with the header `var` as a loop-scoped mutable
binding, and assignment lowering resolves innermost-first so a header
`var` updates itself under a same-named module-level `var`. c emits its
own `while` and a `while(1)` form whose continue label runs the post;
ocaml uses the ref discipline and a pair of local exceptions per loop;
typescript uses the target's native `for` with a labeled driver loop
for tail calls; wasm lowers to block/loop/br_if with a post block;
beam threads every free variable through a hidden recursive function
with a done flag; riscv64 uses labels and jumps — and gained `/` and
`%` so the example boots. `examples/loops` is golden on all six targets
plus the interpreter, and the plain-loop benchmark row records the
dynamic-by-construction ocaml number beside the c target.

## M10 — Error handling

The error model `CHECK.md` settled (2026-10-11): expected failures are
values — `(R.ok, value)` / `(R.error, reason)` off the built-in `R`
enum — matched in `case` or assert-bound through a binding pattern
(`const (R.ok, body) = f()`); a violation raises the one `Exception`
class, and a raise ends the process — no catch construct, on any
target. `R` sits in the spec-core tier (`CHECK.md`, type layering), so
every target including riscv64 gets it; the stdlib migration moves the
~220 raise sites to the convention, package by package. The design
lives in `CHECK.md` and the README (both languages); each step's plan
file is written when the step starts.

### Step 28 — Error-handling surface: R, binding patterns, raise discipline

**Prereq:** Step 27.
**Done when:** the README's exception snippets run verbatim through
`emo run`; an error tuple flowing into `const (R.ok, body)` ends the
process with the case-no-match runtime error; `raise "str"` and
`raise user` each get their own diagnostic; the built-in names `R` and
`Exception` refuse user redeclaration; the uncaught report prints
non-empty `data`; `dune test` green.

- [x] **T28.1** — Built-in `R { ok, error }`: bound in the checker's
      root env and the interpreter's global frame (the `Exception`
      precedent); `R.ok` / `R.error` construct and pattern-match
      everywhere enum members already do; `enum R` / `class R` report
      a reserved-name diagnostic.
- [x] **T28.2** — Parser: `const`/`var` accept a full pattern in
      place of the name (`Ast.Binding` carries it); the `const (`
      form stops being a hard error, breaking no grammar.
- [x] **T28.3** — IR: the pattern binding desugars to a one-arm
      `case` wrapping the block remainder — no new IR nodes, the six
      backends see only existing ones.
- [x] **T28.4** — Checker: pattern bindings check through
      `check_pattern` against the initializer's type; `raise`'s
      operand must be an `Exception` instance (its own E-code for
      everything else); the uncaught diagnostic appends non-empty
      `data`.
- [x] **T28.5** — Interpreter: pattern-binding evaluation, mismatch
      riding the case-no-match runtime error; the raise-operand
      discipline at run time; existing goldens re-recorded where the
      uncaught format changed.
- [x] **T28.6** — Example and rejections: `examples/errors` — the
      README snippets verbatim (ok/error matching, the assert-match
      binding, a violation raising) — golden through `emo run`; the
      matching example golden on all six targets byte-for-byte
      (riscv64 runs the matching half; its raise refusal unchanged);
      the rejection corpus pinning every new diagnostic.
- [x] **T28.7** — README alignment: the README (English + zh-CN)
      already documents the settled surface — verify it against the
      implemented one and reconcile any drift.

### Step 29 — The stdlib migration: tuples replace raises, package by package

**Prereq:** Step 28.
**Done when:** every stdlib package's data-driven failures return
`(R.error, reason)` and only contract violations raise; every package
golden green on its declared targets; `dune test` green.

- [x] **T29.1** — `file` + `os`: open/read/write and permission
      misses, missing paths return tuples; the native raise sites (os
      runtime, interp + ocaml + c) return instead; waitpid decoding
      untouched.
- [x] **T29.2** — `json` + `yaml` (+ `internal/float`): parse and
      accessor failures return tuples — the two biggest sites, ~150.
- [x] **T29.3** — `xml` + `base64` + `bufio` + `slog` + `http` +
      `sync`: the same split; `http`'s refused/unresolved/deadline
      failures become tuples, per the README's network section.
      (`xml`/`base64` decode failures and the whole `net` surface
      return tuples; `bufio`/`slog`/`sync` keep their raises — every
      one is a caller mistake.)
- [x] **T29.4** — Goldens: every touched package's error-path
      fixtures re-recorded to match `(R.error, why)`; package goldens
      green on all declared targets.
- [x] **T29.5** — Docs: the per-package pages under `docs/stdlib/`
      (and the zh-CN mirrors) reworded raise → returns; error-message
      tables updated.

### Step 30 — Checker strictness: Box typing and cross-module value signatures

The checker pass on `feat/checker` (2026-10-11): the two divergences the
loops step recorded, plus what unblinding them exposed. Decisions in
CHECK.md.

- [x] **T30.1** — `Box.new` types as `Box[T]`: the checker's constructor
      special case beside `List.new`/`Map.new`, so `read`/`replace`
      check against the cell and every other member — including a bare
      member access — is refused at check time (the bare `x.v`
      divergence; the stdlib's Box state was wholly unchecked). Two
      latent c-side deviations fell out the moment receivers carried
      types: `emo_box_replace` answered with the box while every other
      target answers with the new value (aligned), and the emitter's
      `to_string` dispatch arm hijacked statically-typed instance
      receivers, printing the debug repr instead of calling the class's
      method (instances now dispatch by class first, the conversion
      only when no method carries the name).
- [x] **T30.2** — Cross-module value signatures: defs and foreigns as
      their declared `FuncType`s, consts/vars as their initializer's
      types, and the `emo` groups into a program-wide registry — all
      pre-registered beside the type tables. A qualified call checks
      through `check_apply`; a bare member read resolves or reports
      E5004 statically; group members type (a bare `Math.tau` read as
      Unknown even same-module before); a local shadows a module of the
      same name, the runtime's rule. Two pre-existing checker bugs fell
      out: `longest_module_prefix` walked the path's suffixes, never its
      prefixes, and the empty dotted path passed as a module prefix —
      bare member access on any non-simple receiver (`foo(1).field`)
      read as Unknown.
- [x] **T30.3** — A capitalized value name resolving to no type, group,
      or module reports E4003 where it is written, in a program check
      (the runtime's value-carrying builtins stay legal); the lone-file
      view keeps the old silence, like every cross-file gap it cannot
      see through. The json/yaml interfaces declare `get` (a
      self-referencing signature; json gains the four raising scalar
      variants its classes already answered with). Checker and project
      tests; the CHECK.md entry; every target's goldens green.

## M11 — The standard library

The bundled stdlib is a milestone of its own: one package per step, each
shipping its API reference and a runnable golden. The steps run `json`
(31) through `bufio` (37), then the native-binding `sqlite3` (38) and
the SQL parser `sql`.

### Step 31 — The standard library: `json` · `plan/step-31-stdlib-json.md`

**Prereq:** Step 11 (packages) + step 25 (target independence).
**Done when:** `require "json"` decodes and encodes JSON on every
target the compiler ships, byte-identically — strict offset-bearing
errors, exactly round-tripping numbers, a value tree of ordinary Emo
data over the shared runtimes, zero per-target runtime work beyond the
typescript UTF-8 bytes fix; goldens on all six paths; `dune test`
green.

- [x] **T31.1** — The spec and the skeleton: the package
      `stdlib/registry/json/0.1.0` (`package.emo` over the five tested
      targets, `json.emo` with the value model — `JsonKind`, the
      `Json` interface, seven payload classes, the factories — and
      `internal/float.emo` for the numeric machinery) embedded by
      rebuild. Verification: a factory-built value encodes,
      interpreted. (Done 2026-10-09.)
- [x] **T31.2** — The typescript bytes fix: `to_bytes` encodes UTF-8
      and `Bytes.to_string` decodes UTF-8 in the ts prelude; all
      existing ts goldens byte-for-byte. (Done 2026-10-09: the
      interpreter, c, and typescript agree on a non-ASCII
      round-trip.)
- [x] **T31.3** — The decoder: the byte-level scanner and
      recursive-descent parser over the RFC 8259 grammar — escapes
      with surrogate pairs, exact `Int64`/`Float64` numbers, the depth
      cap, offset-bearing errors. (Done 2026-10-09: decode rounds
      decimals once, to nearest with ties to even — `strtod`'s
      answer — via exact long division in `internal/float.emo`.)
- [x] **T31.4** — The encoder: compact and pretty forms; string
      escaping; integers through `Int64.to_string`; the
      shortest-round-trip float formatter. (Done 2026-10-09: π prints
      `3.141592653589793`, denormal-min prints `5.0e-324`, max prints
      `1.7976931348623157e+308`; a float always stays visibly a
      float.)
- [x] **T31.5** — The golden example: `examples/json_demo` wired into
      the interpreter-bootstrap and typescript golden lists (one
      `expected.txt`); c, wasm, and beam wait on the cross-module
      follow-up below. (Done 2026-10-09.)
- [x] **T31.6** — The edge fixtures: `examples/json_edge` — escape
      matrix, surrogate pairs, the 512-array cap round-tripped,
      duplicate keys, number boundaries, round-trips, pretty form —
      wired into the interpreter-bootstrap list. (Done 2026-10-09;
      flushed out the missing empty-container guards in the compact
      encoder.)
- [x] **T31.7** — The docs and close-out: `docs/stdlib/json.md` and
      its zh-CN mirror; `dune build @fmt` and `dune test` green.
      (Done 2026-10-09.)

Step 31 close-out (2026-10-09, on `feat/stdlib`): `require "json"`
decodes and encodes byte-identically on the interpreter, the ocaml
target, and the typescript target — goldens `json_demo` (bootstrap +
ts) and `json_edge` (bootstrap) green, `dune build @fmt` and
`dune test` green end to end. The package is ordinary pure Emo; the c,
wasm, and beam targets stay blocked on one checker step — cross-module
type names ("cross-module types stay unchecked this step", step 10) —
with the minimal repros and the backend fixes this step already landed
recorded in `plan/step-31-stdlib-json.md`. Compiler fixes riding this
step: the span type table keyed by file (multi-module type
corruption), the typescript tail-call rewrite's argument
temporaries + string escapes + interface separators, the c `emo_send`
argument array + unknown-receiver vtable fallback + mutual-tail
cluster entry dispatch, and the wasm interface-dispatch `Ref_cast` +
field display-name resolution.

### Step 32 — The standard library: `yaml` · `plan/step-32-stdlib-yaml.md`

**Prereq:** Step 31 (the json package — the tree design and the float
machinery this package mirrors). **Done when:** `require "yaml"`
decodes and encodes YAML 1.2 (core schema) byte-identically on the
targets the checker carries — block/flow, quoted scalars with the
YAML escape set, block scalars with chomping, duplicate keys
last-win, numbers at their boundaries; goldens green on
interpreter/ocaml/typescript; c, wasm, and beam wait on the
cross-module-types follow-up shared with step 31.

- [x] **T32.1** — The package and the parser: `stdlib/registry/yaml/
      0.1.0` embedded by rebuild; the value model, the block/flow
      parser. (Done 2026-10-09.)
- [x] **T32.2** — The encoder: block style; plain-when-unambiguous
      strings; empty-container flow forms. (Done 2026-10-09.)
- [x] **T32.3** — The goldens: `examples/yaml_demo` (bootstrap +
      typescript) and `examples/yaml_edge` (bootstrap). (Done
      2026-10-09.)
- [x] **T32.4** — The docs: `docs/stdlib/yaml.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 32 close-out (2026-10-09, on `feat/stdlib`): the yaml package
mirrors the json package's tree design and passes its goldens on the
interpreter, ocaml, and typescript; c, wasm, and beam remain gated on
the cross-module-types checker step shared with step 31. The package
also flushed out the typescript runtime's field-shadows-method
dispatch bug (fixed in `ts_runtime.ts`: E.method now falls through to
the prototype's method when the own property is not a function).

### Step 33 — The standard library: `xml` · `plan/step-33-stdlib-xml.md`

**Prereq:** Step 31 (the json package — the tree design and the
byte-scanner patterns this package follows). **Done when:**
`require "xml"` decodes and encodes well-formed XML byte-identically
on the verified targets — elements with quoted attributes, self-
closing form, the five entities plus character references, CDATA as
raw text, comments / PIs / declaration / DOCTYPE skipped, mixed
content, offset-bearing errors; goldens green on
interpreter/ocaml/typescript/c; wasm and beam wait on the
cross-module-types follow-up shared with steps 31–32.

- [x] **T33.1** — The package, the value model, and the decoder.
      (Done 2026-10-09.)
- [x] **T33.2** — The encoder. (Done 2026-10-09.)
- [x] **T33.3** — The goldens: `examples/xml_demo` (bootstrap + c +
      typescript) and `examples/xml_edge` (bootstrap). (Done
      2026-10-09.)
- [x] **T33.4** — The docs: `docs/stdlib/xml.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 33 close-out (2026-10-09, on `feat/stdlib`): the xml package —
the leanest of the three format packages (XML is all text, so no
float machinery) — passes its goldens on the interpreter, ocaml,
typescript, AND c (xml_demo rides the c_goldens list). The package
also flushed out the exact-buffer `to_string().substring(byte_count)`
out-of-bounds pattern across all three format packages (fixed:
exact-fill buffers return `to_string()` directly). wasm and beam
remain gated on the cross-module-types checker step.

### Step 34 — The standard library: `os` · `plan/step-34-stdlib-os.md`

**Prereq:** Step 23 (the c target) and step 25 (target independence —
the standalone ocaml runtime needs the dispatch too). **Done when:**
`require "os"` gives a program process identity, fork / execv /
waitpid / _exit, a pipe, raw unbuffered fd file IO, and the directory
surface; every failing call raises naming the system call; waitpid
answers the kernel's raw 16-bit status with pure-Emo decoders;
list_dir answers byte-order-sorted names without `.` and `..`;
goldens green on interpreter/ocaml/c; ts/wasm/beam refuse the package
by declaration.

- [x] **T34.1** — The checker signatures, the `os_` runtime
      implementation prefix, and the interpreter's Unix-backed
      dispatch. (Done 2026-10-09.)
- [x] **T34.2** — The c runtime's `emo_os_*` POSIX implementations
      and the c emitter's dispatch. (Done 2026-10-09.)
- [x] **T34.3** — The standalone ocaml runtime's dispatch. (Done
      2026-10-09.)
- [x] **T34.4** — The package: thin wrappers, the wait-status
      decoders, the fork/pipe discipline. (Done 2026-10-09.)
- [x] **T34.5** — The golden: `examples/os_demo` on the bootstrap
      and c_goldens lists. (Done 2026-10-09.)
- [x] **T34.6** — The docs: `docs/stdlib/os.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 34 close-out (2026-10-09, on `feat/stdlib`): the os package —
the second runtime-backed package after net, and the first reaching
into process machinery — verified on the interpreter, ocaml, and c
targets; the os_demo golden exercises fork+pipe+waitpid (child exits
7 through _exit, the parent decodes the raw status) beside the raw IO
and directory surfaces. Unlike the format packages, os crosses
modules with native types only, so the c target takes it without the
cross-module-types checker step; ts/wasm/beam are refused by the
package's targets declaration.

### Step 35 — The standard library: `base64` · `plan/step-35-stdlib-base64.md`

**Prereq:** Step 31 (the json package — the byte-scanner discipline).
**Done when:** `require "base64"` encodes with the standard alphabet
and `=` padding and decodes strictly — alphabet-only, padding only in
the final quantum, canonical zero padding bits — with the offending
byte offset on every rejection; the golden rides ALL five lists
(bootstrap, c, typescript, wasm, beam), byte-identical everywhere.

- [x] **T35.1** — The package: the arithmetic alphabet both
      directions, the strict decoder, offset-bearing errors. (Done
      2026-10-09.)
- [x] **T35.2** — The wasm fixes: the `&&`/`||` left-operand cast and
      the zero-length byte-copy guard. (Done 2026-10-09.)
- [x] **T35.3** — The beam fixes: the logical operators, the tuple
      index, and `Make_exception`. (Done 2026-10-09.)
- [x] **T35.4** — The golden: `examples/base64_demo` on all five
      lists. (Done 2026-10-09.)
- [x] **T35.5** — The docs: `docs/stdlib/base64.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 35 close-out (2026-10-09, on `feat/stdlib`): the base64 package
is the first standard-library package on all five goldens — and the
step flushed out four latent backend bugs no shipped example had ever
reached: the wasm `&&`/`||` left operand skipped its `ref.cast` (this
was the wall gating json/yaml/xml out of the wasm goldens), the wasm
zero-length byte copies were do-whiles that trapped on
`"".to_bytes()`, the beam logical operators called `emo_add` on two
booleans, and the beam tuple index used `lists:nth` on an Erlang
tuple; beam also gained `Make_exception` (the exception object is its
message). The json/yaml/xml wasm gate should be re-examined against
these fixes — the `&&` wall is gone, though their cross-module class
types may still be gated by the step-31 follow-up.

Format-package backend follow-up (2026-10-14, on `develop`): the
re-examination is done — `json_demo`, `yaml_demo`, and `xml_demo` now
ride the wasm, beam, and c golden lists. `String.substring` had no
wasm or beam runtime; wasm gained an in-bounds byte copy and beam a
`binary:part/3` behind the interpreter's range check. Two wasm class
bugs surfaced behind it: the class-pad formula `ordinal * (max_fields
+ 1) + field_count` gave (ordinal 0, one field) and (ordinal 1, zero
fields) the same two-field struct, so WasmGC merged their RTTs and
`ref.test` could not tell `YamlNull` from `YamlBool` (a decoded null
answered as `YamlBool`, which read as a dispatch bug); each class's
total field count is now `(ordinal + 1) * (max_fields + 1) + 2`,
unique per class and clear of the two all-anyref runtime shapes. The
`get` method in the runtime also shadowed every class's `get` method on
both targets (`doc.get("k")` lowered to Bytes indexing); both backends now test
Bytes/instance at runtime and fall back to the Bytes accessor.

### Step 36 — The standard library: `slog` · `plan/step-36-stdlib-slog.md`

**Prereq:** Step 35 (base64 — the native-types-only surface shape).
**Done when:** `require "slog"` logs one line per record, logfmt or
JSON, filtered by a minimum level; loggers are ordinary values — an
opaque handle carrying name, level, and format — attrs are a
`Map[String, String]` with keys strict to one alphabet, and the golden
rides the bootstrap, c, and typescript lists byte-identical; wasm and
beam refuse the package until their runtimes implement `Map`.

- [x] **T36.1** — The package: the ordered levels and the two
      formats, the handle pack/parse, the logfmt and JSON renderers,
      strict keys and exact errors. (Done 2026-10-09.)
- [x] **T36.2** — The golden: `examples/slog_demo` — both formats,
      filtering, a child logger, quoting and escaping, UTF-8, and
      `enabled` — on the bootstrap, c, and typescript lists. (Done
      2026-10-09.)
- [x] **T36.3** — The docs: `docs/stdlib/slog.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 36 close-out (2026-10-09, on `feat/slog`): the slog package is
the first standard-library package whose golden needed zero compiler
changes — the step-35 wasm/beam fixes held, and `Map` on
interp/ocaml/c/typescript carried the whole surface. The design
answers "a logger without a framework": the handle packs
`name/level/format` in plain sight so the package holds no state at
all, records carry no timestamp (no clock — deterministic output, a
caller with a time passes it as an attribute), and attribute keys are
strict to one alphabet shared with the handle's percent-escaping. The
manifest declares the three targets that work today and widens when
the wasm/beam `Map` gap closes.

### Step 37 — The standard library: `bufio` · `plan/step-37-stdlib-bufio.md`

**Prereq:** Step 36 (slog — the zero-compiler-change golden shape).
**Done when:** `require "bufio"` reads and writes through a
fixed-size buffer over two one-method structural interfaces —
`Reader` with line, delimiter, peek, discard, and one-level unread;
`Writer` with coalescing writes, explicit flush, and never a silent
discard — the fd and in-memory adapters cover the concrete streams,
the golden rides the bootstrap and c lists byte-identical, and the
c-backend cross-module dispatch is sound (an instance answers through
its vtable, once, and Void method statements keep their calls).

- [x] **T37.1** — The package: the two interfaces, the four
      adapters, the `Reader` and `Writer` surfaces, strict sizes and
      exact errors. (Done 2026-10-09.)
- [x] **T37.2** — The golden: `examples/bufio_demo` — in-memory
      streams, an 8-byte buffered file write that really flushes,
      read back through two stacked readers — on the bootstrap and c
      lists. (Done 2026-10-09.)
- [x] **T37.3** — The c-backend fixes: the runtime dispatch for
      untyped receivers (`emo_dynamic_builtin` + the runtime method
      table), the single evaluation of the receiver, and the Void
      statement-method emission. (Done 2026-10-09.)
- [x] **T37.4** — The docs: `docs/stdlib/bufio.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 37 close-out (2026-10-09, on `feat/bufio`): the bufio package is
the first standard-library package whose state isBoxes inside an
ordinary class — the buffer, cursor, source, and last-read byte live
in `Box`es, and the class stays immutable around them. The step
flushed out three latent c-backend bugs in the cross-module
method-call path: the name hijack that sent `read_line` on a user
class to the socket implementation, the receiver expression evaluated up to
three times by the dispatch, and Void method statements compiled to
nothing. All three are fixed in the runtime dispatch
(`emo_dynamic_builtin`), which evaluates the receiver once and hands
instances to their vtable before any runtime method. The package rides `os`,
so its manifest declares the ocaml and c targets and widens when
those surfaces reach the other runtimes.

### Step 38 — The standard library: `sqlite3` · `plan/step-38-stdlib-sqlite3.md`

**Prereq:** Step 23 (the c target's direct C ABI) + step 24 (the embedded stdlib).
**Done when:** `require "sqlite3"` on the c target opens a database, executes DDL, prepares statements, binds int / float / text / null parameters, and reads typed columns — with no `--cclib` and no hand-compiled shim on the consumer's side; the manifest's `link` field and package-carried `.c`/`.h` sources land with it; every other target refuses (resolution's `targets` gate, or the non-c build's E5007), the interpreter at run time (E3009); `dune test` green.

- [x] **T38.1** — The manifest's `link` field: parse (strict, optional, bare names only), tests.
- [x] **T38.2** — Packages carry `.c`/`.h`: `Registry.collect_files` and `gen-stdlib-data.sh` collect and embed them; publish and checksums flow through unchanged.
- [x] **T38.3** — The build wiring: `load_deps`/`compile_inputs` collect each dependency's C sources and link libraries; the c target's cc invocation and cache key take them; the non-c gate (E5007).
- [x] **T38.4** — The `sqlite3` package: manifest, `internal/ffi.emo`, `emo_sqlite3_shim.c`, the `Database`/`Statement` public surface.
- [x] **T38.5** — `examples/sqlite3_demo` golden on the c target (gated on a sqlite3 probe, beside `cc_available`), plus the native-dependency tests in `test/emo_project`.
- [x] **T38.6** — The docs: the CHECK.md entry, README (+ zh-CN), `docs/c-backend.md` (+ zh-CN), `docs/stdlib/sqlite3.md` (+ zh-CN), the stdlib tours.

Step 38 close-out (2026-10-12, on `feat/sqlite3`): the package system learns to carry native code — a manifest gains the optional `link` field (bare library names; a flag- or path-shaped entry is E5103), and `.c`/`.h` sources ride the package tree into collection, checksums, embedding, and publishing — so the c target compiles and links a dependency's native inputs with no consumer-side flags. The `sqlite3` package is the first consumer: a `foreign def` binding over a package-carried exact-ABI shim (`emo_sqlite3_shim.c`, every signature `int64_t`/`double`/`bool`/`const char *`), c-target only, raising per the `os` convention until the error-handling migration lands.

---

## M12 — Visualization (`plot`)

T0 has landed: `plot` emits a bar chart to SVG, byte-identical on all
five hosted targets, built on the internal `Buffer`, scales/ticks, the
`Renderer` interface with `SvgRenderer`, and the declarative
`figure`/`axes`/`mark` values. The numeric substrate and the `math`
package (sequencing A) are done. This milestone finishes the design's
sequencing B–E: the rest of the T0 surface, the `Table` and channels,
the T1 dataset charts, then the terminal and PNG renderers. Design and
recorded decisions live in `docs/visualization.md`; the package's
current surface in `docs/stdlib/plot.md`; the language enablers this
work touches in `docs/temp-visual-check.md`. Out of scope (decision 9):
interactive/GUI charts, an EmoUI canvas, 3D, animation. Each step's plan
file is written when the step starts.

### Step 39 — Compiler and language enablers for plotting · `plan/step-39-plot-enablers.md`

Independent of the plot steps; each unblocks or de-risks work below.
**Done when:** the enabler's own tests pass and the affected plot code
uses it.

- [x] **T39.1** — Type `self.field` precisely (R2 in
      `docs/temp-visual-check.md`) with the emitters aligned, so a mark's
      style fields need not be stored flat. Today a native-typed field
      read on a dynamic receiver is still boxed, and the emitters key
      their native/dynamic choice on the expression's static type alone.
- [x] **T39.2** — A class method named like a runtime method is not
      shadowed (R3). `length` answers its own method on every target;
      `examples/length_method` is the regression.
- [x] **T39.3** — `math`'s opt-in native fast path: separate `*_native`
      `foreign def` functions on `c`/`ocaml` (`math.exp` pure and
      byte-identical, `math.exp_native` the pinned fast path; decision
      15), documented as target-pinned. Off the native targets the
      definitions are inert: the interpreter raises E3009 at the call
      and the emitters refuse the call.
      `examples/math_native` is the regression.
- [x] **T39.4** — File and fix the `ocaml` specialization defect the
      plot spike hit (`non-native expression in specialized body`,
      `Type_ref`), so specialized native bodies lower the same as the
      interpreter. The native emitter lowers type values, enum members,
      field reads, and def values (the last when its def specializes,
      with the wrappers in the native rec group); container literals
      leave the predicate, so those bodies stay dynamic.
      `examples/specialize_shapes` is the regression.

### Step 40 — T0 completion: continuous axes and the remaining marks

**Prereq:** Step 39 optional (T39.1 eases the style classes).
**Done when:** `examples/plot_demo` grows line/scatter/area/histogram
panels and stays byte-identical on all five targets; `dune test` green.

- [x] **T40.1** — Extend the `Mark` interface beyond the categorical
      `y_max`/`bands`/`x_labels` (continuous x and y ranges, `y_min`, the
      point/line primitives a `DrawContext` needs), keeping `Bar` as its
      first implementation.
- [x] **T40.2** — `plot.mark.line` and `LineStyle`.
- [x] **T40.3** — `plot.mark.scatter` and `ScatterStyle`.
- [x] **T40.4** — `plot.mark.area` and `AreaStyle`.
- [x] **T40.5** — `plot.mark.hist` (bin counting) and `HistStyle`.
- [x] **T40.6** — `Axes` draw: a continuous x scale, the y domain
      inferred from every mark's range, and per-mark dispatch (replacing
      today's bar-only `first_labels`/`bands` path).
- [x] **T40.7** — Demos and goldens: one figure per new mark, all five
      targets byte-for-byte.

### Step 41 — Figure fidelity: scales, domains, legend, grid, themes, color

**Prereq:** Steps 39–40.
**Done when:** every field the T0 values already declare is rendered —
log scales, domains, grid, legend, theme — and `DrawContext` is typed
against the `Renderer` interface, not `SvgRenderer`.

- [x] **T41.1** — `Scale.log`: log axes with correct tick placement and
      formatting.
- [x] **T41.2** — `Domain.auto` / `Domain.fixed`: domain fields on
      `Axes` and inference from the marks (decision 19).
- [x] **T41.3** — Legend rendering for `with_legend` (decision 20's
      draw-order rule; one shared legend under faceting, T41.7).
- [x] **T41.4** — Grid rendering from `Figure.grid`, driven by the
      theme's grid style.
- [x] **T41.5** — `Theme` as a value on `Figure` (background and
      foreground, the grid/axis/title/label styles, a palette, a
      colormap, spacing, the default size; decision 24) with
      `with_theme`.
- [x] **T41.6** — `plot.rgb` validating the 0–255 range and draw-time
      validation of raw triples (decision 21), on the T41.5 colormaps'
      `Float64` interpolation; the `color` channel's column-kind
      dispatch rides T42.3's channels (decision 24).
- [x] **T41.7** — The figure half of faceting (decision 23): the
      `rows × cols` panel grid separated by the theme spacing, blank
      cells for the missing tail, `Share.all` drawing every panel on
      the union domain, and the title above the grid; sorted levels,
      per-panel level labels, and the one shared legend ride the chart
      layer (T43.6, through T42.3's `facet_*` channels).
- [x] **T41.8** — Decouple `DrawContext` from the concrete
      `SvgRenderer`: type it against the `internal` `Renderer` interface
      so a terminal or raster renderer can join (the prerequisite for
      Steps 44–45).

### Step 42 — Table and channels

**Prereq:** Step 40.
**Done when:** `plot.table` / `plot.table_missing` build a validated
`Table`, and the chart layer resolves channels through the vocabulary.

- [x] **T42.1** — `enum Presence { present, absent }` and the parallel
      `Map[String, Array[Presence]]` for missing numbers, with the
      statistics skipping `absent` entries (decision 25). The type is
      public at the `plot` root; a numeric column is read through
      `plot.observed`, which drops the `absent`
      entries and raises when a presence array disagrees with its
      values. Verified on all six paths — interp, c, ocaml, ts, wasm,
      beam — with the skip and the mismatch raise byte-identical.
      (`observed` landed as `internal.stats.observed`; the 2026-10-20
      refactor moved it to the root so the statistics module references
      nothing from the package root — the root calls in, and one
      direction is all a module graph may bend.)
- [x] **T42.2** — `plot.table(numbers, labels)` and
      `plot.table_missing(numbers, presence, labels)`: column-oriented
      `Table`, shape violations raising (decision 4/10). The builders
      share one shape check — no name claimed by both kinds, one length
      across every column, a presence column beside each numeric column
      with no strays — and the accessors check the column's kind
      (`number` / `presence` / `label`, beside the `rows` count).
      Verified on all six paths — interp, c, ocaml, ts, wasm, beam —
      with the demo golden byte-identical (`plot_demo` grew a table
      section) and eight shape violations raising the same message on
      every path. Printing the presence columns exposed enum `to_str`
      rendering the qualified name on `ts` and having no rendering at
      all on `wasm`/`beam`; all three now render the bare member — the
      interpreter's rule — so the golden holds byte-for-byte.
- [x] **T42.3** — Channels `Map[String, String]` (decision 16): the
      vocabulary `x`/`y`/`color`/`size`/`marker`/`dash`/`facet_row`/`facet_col`,
      unknown channels an error, each family reading only the channels it
      supports — carrying T41.6's column-kind `color` dispatch through
      the theme's palette and colormap (decision 24). The checks live in
      `internal/channels.emo` — the vocabulary and the per-family reads
      (relational full set; distributions and categorical without the
      point aesthetics; matrix facets only), plus the byte-order
      comparison and `sorted_levels` the categorical color reads the
      palette through, since a `String` answers `==` but not `<`. The
      dispatch is public at the root as `plot.channel_colors(table,
      name, theme)`: a label column through the palette by the level's
      sorted position, a number column normalized over its observed span
      through the colormap (a constant column at the low end), absent
      slots keeping their place at the low end. Verified on all six
      paths — interp, c, ocaml, ts, wasm, beam — with the happy outputs
      and five raise messages byte-identical: unknown channel, two family
      violations, unknown column, all-absent color column. The demo grew
      a channels section; the chart functions that take the mapping
      arrive with Step 43. (The 2026-10-20 chart layer replaced the
      per-family reads with a per-chart check — each chart carries its
      own supported list, since the charts of one family read different
      aesthetics — so the four family wrappers are gone and the
      unsupported-channel message names the chart.)

### Step 43 — T1 dataset charts

**Prereq:** Steps 41–42.
**Done when:** every `plot.*` chart in decision 17 is implemented on the
T0 marks, with fixtures byte-identical on all five targets.

- [x] **T43.1** — Statistics: descriptives, binning, KDE, ECDF, box
      statistics, and OLS with a confidence band; `normal_quantile` and
      `normal_cdf` internal to `plot` (decision 13). Landed in
      `internal/stats.emo`: `sort` (a bottom-up merge sort through the
      ArrayBuilder), `quantile`, `describe`, `histogram_bins` (the
      `hist` mark's own `bin_index`, so a column and a mark built from
      it always agree), `ecdf`, `box_stats` (Tukey whiskers and fliers),
      `ols` with `ols_band` (the large-sample band, its critical value
      the Acklam `normal_quantile`), `normal_cdf` (Zelen–Severo), and
      the `exp` behind the KDE, carried internal by the
      `scale.log10` precedent so `plot` stays dependency-free. Verified
      on all six paths — interp, c, ocaml, ts, wasm, beam — with
      hand-checked values and the raise paths byte-identical.
- [x] **T43.2** — Relational: `plot.scatter`, `plot.line`, `plot.reg`.
      Each chart reads a `Table` through the channel mapping and answers
      a whole `Figure` — one axes, labelled from the channel's column
      names, carrying the marks the mapping builds. `x` and `y` are
      required and numeric; rows where either is absent drop out, and a
      chart with no drawable row raises. The reads are per chart —
      scatter `color`/`size`/`marker`, line `color`/`marker`/`dash`, reg
      only the pair — and a channel the chart does not read raises. The
      `color` dispatch rides T42.3's: a label column splits the rows
      into one series per sorted level (palette color, the level in the
      legend, a level two grouping channels share named once), a number
      column colors a scatter's points through the colormap — which
      grew the `Scatter` mark per-point color and size overrides, the
      `size` channel's span normalization reading the same way (half to
      one and a half times the style's size). Grouping channels read
      label columns and pick each level's marker (the six shapes,
      wrapping) and dash (the four patterns); groups form over the
      channels' combined levels, ordered by their sorted positions. The
      line draws each series in the rows' own order — row order is
      intent. `reg` draws the points, the OLS line (`fit`), and the 95%
      confidence band under them first, sampled over the kept span at
      fifty grid points through `ols_band` — which gave `plot.mark` its
      sixth mark, `band` (one polygon, upper curve forward and lower
      back, the factory checking matched lengths and ascending xs). The
      facet channels pass the check and raise until the chart layer's
      panel splitting lands. Verified on all six paths — interp, c,
      ocaml, ts, wasm, beam — with the demo golden byte-identical
      (`plot_demo` grew a relational section: a grouped scatter with the
      size channel, a two-level line with the dash channel, a reg with
      its band) and thirteen raise messages byte-identical.
- [x] **T43.3** — Distributions: `plot.hist`, `plot.kde`, `plot.ecdf`,
      `plot.box`, `plot.violin`. The first three read one numeric
      column — required through the new single-`x` read — and draw one
      mark per `color` level through the T43.2 grouping, the levels in
      their sorted order: `hist` counts into equal-width bins spanning
      the kept values' shared range, the square root of the count of
      them, so the levels compare on one grid; `kde` draws one density
      curve per level, the bandwidth Silverman's rule answers (new
      `internal.stats.silverman`: 0.9 × min(σ, IQR/1.34) × n^(−1/5),
      the fifth root through the carried `exp` and `scale.log10`, a
      column whose values do not spread raising); `ecdf` draws the
      staircase, each value's cumulative proportion stepping at the
      value. `box` and `violin` sit on the `x` column's levels — a
      number column there raises — and summarize each level's `y`
      through the Tukey statistics: `box` draws the whiskers, the
      quartile box, the median line, and the fliers, `violin` a
      mirrored density per level over the same Silverman bandwidth and
      grid shape, the densities normalized across the row — a level
      whose values do not spread raises naming the level. Both gave
      `plot.mark` two marks: `BoxPlot` (named for the language's `Box`)
      and `Violin`, flat parallel arrays over the categorical face, the
      factories checking matched lengths. The `color` channel is not
      read by `box` or `violin` yet. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with the demo golden
      byte-identical (`plot_demo` grew a distribution section: a
      two-class score table through all five charts) and ten raise
      messages byte-identical. Landing the demo exposed two beam
      runtime bugs, both fixed in the same commit: `emo_g6_sci` trimmed
      with `string:trim(binary, trailing, binary)` — the third argument
      is a character list, so any float whose %g form needs scientific
      notation died in a function_clause (the KDE's small densities are
      the first figures to draw one) — and the %g decimal tail kept
      Erlang `compact`'s final `.0` where the interpreter's %g says
      `204`, now stripped.
- [x] **T43.4** — Categorical: `plot.bar`, `plot.count`, `plot.strip`,
      `plot.point`. All four sit on the `x` column's levels — a number
      column there raises. `bar` and `point` need the `y` channel and
      aggregate each level's observed values by their mean — one bar
      per level, and one stamped, connected mean walking the bands in
      their sorted order. `count` needs no `y` at all: one bar per
      level, its height the number of rows the level carries. `strip`
      draws the raw points at their bands' centers, one mark per
      `color` level through the T43.2 grouping — the points unjittered
      and in the rows' own order, so overlapping points are the data.
      Two marks joined `plot.mark`: `Strip` (a scatter that declares
      the bands, styled with the existing `ScatterStyle`) and `Point`
      (a connected mean row, styled with the existing `LineStyle` plus
      a `point_style` default) — the categorical faces of the two T0
      marks, so the axis labels the levels they draw on. `bar`, `count`,
      and `point` do not read the `color` channel yet. Verified on all
      six paths — interp, c, ocaml, ts, wasm, beam — with the demo
      golden byte-identical (`plot_demo` grew a categorical section: a
      two-region sales table through all four charts) and eight raise
      messages byte-identical.
- [x] **T43.5** — Matrix: `plot.heatmap`, `plot.clustermap`. Both read
      the whole table as a matrix — the numeric columns the cells'
      columns, the rows the cells' rows, exactly one label column
      naming the rows (none or several number them from 1) — and the
      mapping carries only the facet channels, so it is normally empty.
      Each cell takes its color where its value sits on the cells' own
      span through the theme colormap, a constant matrix at the low end.
      `clustermap` reorders the rows and the columns by average-linkage
      clustering over their euclidean distances (new
      `internal.stats.cluster_order`: the base distance matrix, then
      merges of the closest alive pair by mean pairwise distance, each
      merge ordering its halves by their smallest leaf, the dead flags
      a `Map` since arrays do not index-assign); the trees are not
      drawn, the order is the clustering. The `Heatmap` mark joined
      `plot.mark` — pre-colored cells row major, no style, out of the
      legend — and the `Mark` interface grew `y_labels`, the categorical
      y face: `draw_axes` lets a mark carrying row names own the y
      annotation at its band centers, the way `x_labels` owns the x
      one, so a heatmap ticks names on both axes while every other mark
      answers an empty list. The charts pin the axes domains to the
      exact cell counts through `with_x_domain`/`with_y_domain`, so no
      nice ceiling leaves a dead band. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with the demo golden
      byte-identical (`plot_demo` grew a matrix section: a 4 × 4
      correlation table as heatmap and clustermap) and five raise
      messages byte-identical.
- [x] **T43.6** — Apply faceting, palettes, and themes at the chart
      layer; demos and byte-identical goldens — carrying T41.7's level
      splitting, per-panel level labels, and the one shared legend.
      Every chart now reads the `facet_row` and `facet_col` channels:
      each names a label column, and its sorted levels split the chart
      into panels — rows × cols, one channel alone a strip — every cell
      drawing the chart over the rows it holds, so a level combination
      with no rows stays blank, and the facet columns stay out of a
      heatmap's row-name rule. The panels compare: the figure keeps
      `Share.all` with blank cells out of the union (the matrix charts
      keep their own cell grids under `Share.none`); each panel is
      titled from its levels — `time = Lunch`, both facets joined —
      through the new `Axes.title` (`with_title`); the axis labels sit
      at the outer edge only; and the panels' legends give way to one
      legend for the whole figure at its right, once by label, through
      the new `Figure.shared_legend` (`with_shared_legend`), which also
      takes that column out of the grid's width. The chart layer's
      palette and colormap resolution is unchanged — group colors
      resolve through the theme palette by the level's sorted position
      and numeric colors through the colormap at build time, so the
      same level is the same color in every panel. Each chart also
      answers its single-panel form as `<chart>_axes` — fourteen public
      cores over a `panel_axes` kind dispatch the faceted assembler
      loops through — with `rows_of` the sub-table a cell draws. The
      landing exposed one more beam gap, fixed in the same commit:
      indexing a value whose static type is dynamic (an array that
      started as a bare `[]`) fell to `lists:nth` even when the value
      was a tuple — `emo_index` now dispatches on `is_tuple` at
      runtime. `refuse_facets` is gone. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with the demo golden
      byte-identical (`plot_demo` grew three faceted figures: a 1 × 2
      scatter with the shared legend, a 2 × 2 with a blank cell, and a
      2 × 1 histogram) and five probe answers byte-identical.

### Step 44 — Terminal renderer

**Prereq:** Step 41 (T41.8's `Renderer` decoupling).
**Done when:** a figure renders to a terminal through the same Layer 0
value graph, proving the contract is format-agnostic.

- [x] **T44.1** — A Unicode `Renderer` implementation (blocks or braille
      for marks, text labels) behind the `internal` `Renderer`
      interface. `internal/term.emo`'s `TermRenderer` answers the same
      six calls as `SvgRenderer` onto a grid of braille cells: four
      figure pixels make a column and eight a row, so a cell is two dots
      by four with a terminal glyph's aspect, and the default 640 × 480
      figure prints as 160 columns by 60 rows. Color is one ink — every
      color becomes a level from 0 to 8, how many of a cell's eight dots
      it lights, from its Rec. 601 luminance contrast against the paper,
      the figure background the renderer is built with, all in integer
      arithmetic. The fills (`rect`, `circle`, and `polygon`, the last a
      scanline even-odd fill sampled at the dot centers) halftone at
      their level through one dispersed dot order and clear the dots the
      level leaves dark, so a paper-colored fill paints paper — a legend
      panel covers what is under it, and the theme's own background rect
      is a no-op; a line is one dot wide through Bresenham, solid from
      level 2, every fourth dot at level 1, cleared at level 0, with a
      dash pattern three dots on and two off; text lands as characters
      on the row holding the middle of its glyphs, from its anchor,
      always over the dots in its cells, split by UTF-8 sequence; and
      anything off the grid is clipped. The figure walk left `svg()` for
      a renderer-agnostic `render(r, fig)` — `svg` and the new
      `plot.terminal(fig)` differ only in the renderer they construct —
      and the SVG goldens stayed byte-identical. Two target gaps
      surfaced and were cleared on the package side: the `c` target
      refuses the bitwise operators on a dynamic word (a byte read back
      from a `Bytes` field), so the cell update is arithmetic —
      `(cur / bit) % 2` tests the bit and `cur ± bit` flips it; and the
      `typescript` runtime's `String.length()` counts UTF-16 code units
      where every other path counts UTF-8 bytes, which overran the
      `Buffer` the moment it carried three-byte braille — `Buffer.to_string`
      now sums the encoded chunks' byte lengths, and the divergence
      itself is recorded in `CHECK.md`. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with four probes byte-identical
      (a bar figure, a two-line figure with a dashed legend entry, the
      heatmap, and the dark theme), and `dune test` green.
- [x] **T44.2** — Wire it through a CLI/demo path and test that the same
      figure renders through SVG and the terminal. `examples/plot_demo`
      now holds four of its figures as values — the bar figure, the
      two-line figure with its dashed legend entry, the regression chart
      with its band and points, and the heatmap — prints each as SVG
      where it always did, and prints the same four values again through
      `plot.terminal` at the end, so one `Figure` value reaches both
      renderers and both outputs sit in one golden: `expected.txt` grew
      by the four terminal renders (244 lines) with its SVG prefix
      byte-identical, and the standing golden suites pin it on all six
      paths — interp and the `c`, `ocaml`, `typescript`, `wasm`, and
      `beam` builds — byte-for-byte (`dune test` green, 0 failures). The
      four figures between them exercise every primitive the renderers
      answer: `rect` fills and the frame's lines, the dashed line and the
      legend panel, the band `polygon` with `circle` markers, and the
      heatmap's cells across the ink levels. `docs/stdlib/plot.md` (and
      its `zh-CN` mirror) gained `terminal` in the surface, a terminal
      paragraph under Output — the cell geometry, `with_size(320.0, 240.0)`
      for an 80-column terminal, the ink rule, what does not render — the
      worked example printing both, and the landed list naming the second
      renderer; `docs/visualization.md`'s Layer 0 records the landing;
      `plan/README.md` marks Step 44 done. Step 44's exit holds: a figure
      renders to a terminal through the same Layer 0 value graph, and the
      contract is format-agnostic.

### Step 45 — PNG renderer

**Prereq:** Step 44.
**Done when:** `plot.png(fig)` emits a valid PNG on all five targets,
from the same value graph, with no host image library.

- [x] **T45.1** — Pure-Emo DEFLATE with stored blocks. `internal/png.emo`
      opens the PNG backend's byte level with `deflate_stored`: the raw
      DEFLATE stream over an `Array[Int64]` of bytes, one block per 65535
      bytes behind its five-byte header — BFINAL/BTYPE, LEN, and the
      one's complement of LEN — and a single empty final block for empty
      input. The byte arrays are `Array[Int64]` rather than `Bytes`: an
      element read stays a static Int64, and the checksums and the
      Huffman packer ahead need bitwise work the dynamic world refuses
      (the term renderer's arithmetic-bit rule). Verified against an
      external decompressor and across the paths at once: seven probes —
      empty, one byte, a 255-byte run, the 256, 65535, and 65541
      boundaries, and a varied 70000 — decompress byte-identical to
      their inputs under Python's zlib on the interpreter, and the c,
      ocaml, typescript, wasm, and beam builds print the probe's 201,640
      lines byte-identical to it (`dune test` green).
- [x] **T45.2** — Fixed-Huffman DEFLATE, CRC32, and Adler-32.
      `internal/png.emo` grows the real compressor: one fixed-Huffman
      block behind greedy LZ77 over hash chains — a three-byte hash
      into 32768 buckets, earlier positions threaded through a `prev`
      table, both mutable `Bytes` three little-endian bytes a slot
      (zero-filled slots say none, because position 0 is real) — a
      match of four or more winning over literals, sixteen candidates a
      walk, every covered position chained. The bit layer is a
      `put_bits` helper answering `(acc, cnt)` with the builder passed
      through, Huffman codes MSB first and the extra bits LSB first,
      the fixed codes computed (`lit_code`, `len_code`, `dist_code`) —
      the length symbol goes out through its `lit_code` entry, not as
      the symbol number. `crc_table`/`crc_push`/`crc32` carry the
      reflected 0xEDB88320 polynomial (the constant is decimal in Emo —
      a hand conversion was wrong twice until Python generated it),
      `adler32` the two sums mod 65521, and `zlib_stream`, `chunk`, and
      `png_file` assemble the wrapper and the file: the 120, 156
      header, the four-byte big-endian frames, IHDR 8-bit truecolor,
      IDAT, IEND, every chunk CRC'd over kind and data. The stored
      blocks of T45.1 gave way — the LZ77 stream replaces them. The
      missing block header (BFINAL, BTYPE 01) was the first probe's
      finding, the symbol-for-code bug the second; then the ground
      truth held everywhere at once: six probes decompress byte-exact
      under Python's zlib (up to 65800 bytes at 45×), the checksums
      equal `zlib.crc32`/`adler32` (including `0xCBF43926` for
      `123456789`), and the assembled 4 × 3 PNG parses chunk by chunk —
      CRCs good, IDAT back to the exact scanlines, `file`/`sips`
      calling it a valid image — with all five compiled targets
      printing the probe's 4191 lines byte-identical (`dune test`
      green). Found along the way, recorded in `CHECK.md`: a `const`
      shadowing an outer `var` has no semantics the paths agree on
      (interp rebinds flat, `c` scopes, the other four refuse) — the
      packer declares once and assigns in branches.
- [x] **T45.3** — A scanline polygon/line rasterizer with supersampling.
      `internal/png.emo` grows `PngRenderer`, the third `Renderer`: the
      display list drawn onto an RGB sample grid at 2 × supersampling —
      every pixel 2 × 2 samples, the four averaged (+2, over 4, which
      rounds to nearest) into the antialiased pixel. Fills are
      scanlines: a rect's spans and a circle's chord per row between
      `sample_from` edges, a polygon's even-odd crossings sorted per
      sample row (`internal.term`'s `insert_sorted`, one internal
      module reading another); a line is a Bresenham walk in sample
      space with a square pen as wide as the stroke, the dash
      vocabulary ("7 4", "1.5 3.5", "7 3 1.5 3") paced along the walk
      by the distance travelled, a diagonal step worth 0.707 px. The
      paper fills the grid at construction and every draw checks its
      color with `write_color`'s message. And because the format is
      binary, `finish()` now answers `Bytes` for every renderer — the
      text formats are their UTF-8 bytes, `Buffer` grew `to_bytes`, and
      `plot.svg`/`plot.terminal` take the string from it — the shape
      `plot.png` needs, since a String cannot carry a PNG on
      `typescript` at all (the codec's U+FFFD rule). Text checks its
      color and waits for T45.4. Verified with a drawn probe — rect,
      circle, triangle, a solid diagonal, a dashed stroke on white —
      decoded pixel by pixel against Python (fills exact, the dash
      running 7–8 on and 3–4 off), read back as an image, and
      byte-identical across the six paths (`dune test` green). Two
      target facts surfaced on the way, both recorded in `CHECK.md`: a
      builtin method chained on a user-class method call mis-reads its
      receiver on the interpreter (`b.to_bytes().length()` answers 0
      where the const-bound form answers 8) — it emptied every SVG the
      moment `finish()` went to bytes, so the package binds first and
      calls after — and a class method named `to_bytes` is dispatched
      to the String builtin on `wasm` whatever the receiver, so the
      buffer's byte side is `join()`.
- [x] **T45.4** — Text through the Hershey stroke font.
      `internal/font.emo` carries the 95 printable ASCII glyphs of the
      Hershey Simplex set — public domain, Dr. A. V. Hershey's
      lettering for the National Bureau of Standards — as three flat
      tables: each glyph's advance, where its encoding starts, and the
      encoding itself, stroke count then point count then points, x
      right and y up from a baseline of 0 under a cap height of 21
      (bindings lower-case: a capital names a type). `PngRenderer.text`
      draws each glyph's strokes through the line path, scaled so the
      cap is 0.7 of the size, laid from the anchor over the summed
      advances, the call's y the baseline, bold double the stroke
      width, and a code outside the printable band falling to the
      space. Verified with a drawn probe — a bold centered title, a
      start-anchored and an end-anchored label, a digits-and-punctuation
      line — read back as an image, the strokes legible and the anchors
      placed, and byte-identical across the six paths (`dune test`
      green).
- [x] **T45.5** — `plot.png(fig)`, its demo, and goldens. `plot.png`
      joins `svg` and `terminal` at the root: one `render` walk, the
      `PngRenderer` behind it, the answer `Bytes` — a PNG is binary and
      a `String` cannot carry it on `typescript`. `examples/png_demo`
      prints two small figures both ways, the terminal rendering that
      pins the value graph and the PNG's byte length and 33-byte head —
      signature, dimensions, bit depth — that pins the file, and the
      golden rides all five target lists (`c`, `wasm`, and `beam` in
      `emo_cli_test`, the ocaml bootstrap, and the `typescript` list in
      `emo_project_test`), byte-for-byte with the interpreter, beside
      `plot_demo`'s standing six-path golden. `docs/stdlib/plot.md`
      (and its `zh-CN` mirror) gained `png` in the surface, the PNG
      paragraph under Output, and the landed list's third renderer;
      `docs/visualization.md`'s Layer 0 records the landing with
      `finish()` at `Bytes`; `plan/README.md` marks Step 45 done.
      Step 45's exit holds: `plot.png(fig)` emits a valid PNG on all
      five targets, from the same value graph, with no host image
      library. The goldens surfaced two more target walls, both
      recorded in `CHECK.md` and both dodged by representation: beam
      indexes an `Array` by walking its underlying list (the
      230,640-byte deflate stream ran 19 minutes until the bytes moved
      into chunked stores — `Pack` for the stream, one `Bytes` row a
      sample row in a `Map` for the grid — 4 seconds after, byte for
      byte the same file), and a class method named like a builtin
      dispatches to the shape tests on `beam` when the IR loses a
      constructor's type, so `Chain` answers `slot`/`set_slot` and
      `Pack` answers `add`/`byte`/`count`.

---

## M13 — Unit testing

The testing surface settled on `feat/unit-test` (2026-10-12): a `test/`
directory at the project root — every `.emo` file under it is a test
file, every top-level `def test_*` a test — and assertions as builtins
(`expect_equal` / `expect_true` / `expect_false` / `expect_fail`) whose
failure raises the one `Exception` class, caught per test by the OCaml
runner (Emo has no catch; the runner is the only place a raise can be
trapped). No new syntax constructs. Work began on this branch: partial
implementations of T46.1–T46.5 and T46.7 sit in the tree unreviewed —
each is finished against its task definition below, not merged as
found.

### Step 46 — Unit test framework: `emo test` and the `expect_*` builtins

**Prereq:** none beyond develop.
**Done when:** `emo test` in a project with a `test/` directory runs
every `def test_*`, reporting pass/fail/error per test with captured
output and exiting 0/1/65 by the family; the `expect_*` builtins raise
real `Exception`s in the interpreter and refuse honestly on compiled
targets; `emo new` scaffolds a passing test; `dune test` green.

- [x] **T46.1** — `expect_*` builtins in the interpreter: registered
      in `global_env`, dispatched in `apply_builtin`, raising via an
      `expect_raise` helper on the `net_raise` precedent (a real
      `Exception` instance; the message names the assertion, and
      `expect_equal` renders both values); arity E3007 / type E3001
      follow the existing builtin style. Eval tests: pass and fail
      paths, message rendering, the error codes.
- [x] **T46.2** — Checker + IR surface: `expect_*` signatures in the
      checker's `empty_env` (Unknown value params, Void results — the
      `println` pattern) and the four `expect_*` names in `is_builtin`'s
      bare-name list, so a compiled program naming one meets the
      backend's standard honest refusal (riscv refuses every builtin
      generically; c / ocaml / ts / wasm / beam gain refusal arms
      wherever their builtin dispatch is exhaustive). Checker tests
      for the signatures.
- [x] **T46.3** — `reset_output` in the evaluator: the default sink
      named and restorable after `set_output` redirection (the
      runner's per-test capture).
- [x] **T46.4** — Runner core in `emo_project`: `prepare_root`
      (discovery at the working directory, the manifest search from
      there), the `test_outcome` / `test_result` types, and
      `run_tests` — the whole tree checked first (`Static_errors`
      out), test modules by the `test/` first segment, `def test_*`
      collected from the module env (`ArrowBlock` only; a
      parameterized `test_*` is a collection error, never a call),
      each test in its own `Emo_sched_det.run` with output captured
      and restored; `Emo_raise` fails the test, `Emo_eval.Error`
      errors it. Project tests: mixed outcomes, the collection error,
      no `test/` directory, a static error in a test module.
- [x] **T46.5** — `emo test` subcommand: reporting (one line per
      test, the rendered diagnostic and captured output on failure,
      the summary line), exit codes 0/1/65, registration in the root
      command group, help text naming the convention. CLI tests: a
      passing project and a failing one, end-to-end.
- [x] **T46.6** — `emo new` scaffolds `test/greet.emo` with a passing
      `test_greet` (builtins need no manifest dep) and the hint
      mentions `emo test`; scaffold goldens updated.
- [x] **T46.7** — `examples/test_demo/`: a small module, passing
      tests under `test/`, `expected.txt` for the golden harness;
      reconcile the per-target golden builds (a compiled build leaves
      every `test/` module out, so the example's tests cannot reach a
      backend that refuses `expect_*`; product code still does).
- [x] **T46.8** — Docs: README gains the Testing section (the
      convention, the command, the builtins, a raise failing only the
      one test), mirrored in `docs/zh-CN/README.zh-CN.md`.

## M14 — CSV read/write

The `csv` package reads and writes RFC 4180 records — UTF-8 only —
from the bundled registry like the other format packages. It needs no
per-target runtime work: bytes and arrays carry the whole surface, so
the golden rides all five target lists.

### Step 47 — The standard library: `csv` · `plan/step-47-stdlib-csv.md`

**Prereq:** Step 35 (base64 — the byte-scanner discipline and the
all-five-golden shape) and step 31 (json — the format-package
conventions).
**Done when:** `require "csv"` decodes RFC 4180 text into
`Array[Array[String]]` and encodes it back, byte-identical on all five
targets — strict quoting, CRLF/LF/CR records, a leading BOM ignored,
every byte validated as UTF-8, offset-bearing errors, and a one-byte
delimiter pair for TSV; goldens on all five paths; `dune test` green.

- [x] **T47.1** — The package: `stdlib/registry/csv/0.1.0` (manifest
      over all five targets, `csv.emo` with the record model, the
      strict decoder, the canonical encoder, the UTF-8 validator, the
      delimiter pair).
- [x] **T47.2** — The goldens: `examples/csv_demo` on the bootstrap,
      c, typescript, wasm, and beam lists; `examples/csv_edge` on the
      bootstrap list — every record shape, the malformed matrix, the
      UTF-8 boundaries, the BOM, and the encoder's quoting rule.
- [x] **T47.3** — The TypeScript UTF-8 fix: the runtime's decoder
      rejected 3-byte lead bytes E8–EF (`b < 0xe8`), so U+8000–U+FFFF
      decoded as U+FFFD; `csv_demo` flushed it.
- [x] **T47.4** — The wasm `!` fix: unary `!` read the `$vbool` field
      without the `ref.cast` `&&`/`||` already emitted, so any module
      using `!` failed WebAssembly validation; `bad_utf8`'s
      `!continuation(…)` flushed it.
- [x] **T47.5** — The docs: `docs/stdlib/csv.md` and its zh-CN
      mirror; the stdlib tour and README package lists.

## M15 — EmoUI

EmoUI is the declarative UI framework the language's syntax was shaped
to serve: UIs composed as trees of components that render from explicit
state, with no template language — the UI is plain Emo. One shared
application module (components, `update`, `view`, written against the
portable `ui` core) renders on a terminal, a server-rendered page, a
macOS/AppKit window, and a GTK 4 window, with the browser DOM following
its own runtime path; each platform may ship its own component library,
but the way components are called and composed is identical. The design
and its evidence are `docs/emo-ui.md`, `docs/emo-ui-check.md`,
`spike/components`, and `spike/emo-ui-probe`; the EmoUI packages live in
this repository under `projects/emo-ui/` (`CHECK.md`, the in-tree
project layout), while the compiler-side gates the design found (the
native packaging mechanism and the browser runtime path) and the
terminal-input package also land in the tree. The `c` target's long-running memory is the fourth
thing a UI forces and the one it does not get for free: the 2026-10-14
arena-scope spike settled that the cheap fix does not exist, so it is
scheduled separately (**M16**, step 49) and the native backends are
demo scale until it lands — the limit documented, not papered over.
(It landed 2026-10-17; the demo-scale note is retired — see M16.)

### Step 48 — EmoUI · `plan/step-48-emo-ui.md`

**Prereq:** Step 23 (the `c` target and `foreign def`) and step 25
(target independence); the cross-module type names (2026-10-14) and the
C→Emo callback contract (2026-10-11) are already in `develop`.
**Done when:** the shared portable app module answers byte-for-byte on
the debug and SSR backends across all five hosted targets and drives the
TUI, macOS, GTK 4, and browser backends through thin per-platform
entries; the composition syntax is identical on every backend; the
native packaging mechanism is settled so a native UI backend is a
`require` rather than a hand-copied shim build; no language change was
required.

**Decisions settled here (2026-10-14; full text in `docs/emo-ui.md`):**

1. EmoUI is a **project of its own**, not a standard-library package; a
   later split moving the portable core and the pure-Emo backends into
   the stdlib is possible once stable, not v1. *(Revised 2026-10-15 by
   decision 11: hosted in this repository under `projects/emo-ui/`, not
   in a separate repository created up front. It remains not a stdlib
   package.)*
2. The tree type is a **multi-module `ui.Node`** (interface spine plus
   concrete classes with typed props), not a stringly-tagged class and
   not one class per platform with no core.
3. **Children are an explicit `Array[Node]`**; trailing blocks are for
   callbacks and iteration and must `return` their value — no implicit
   child collection, so the README's illustrative tree is revised.
4. **Layout is a portable vocabulary mapped to native layout** (CSS
   flexbox / GTK boxes / AppKit stack views / a TUI cell grid), not a
   shared Emo layout engine; the TUI keeps a small Emo box model.
5. **Style is a typed value** with a factory and `with_*` copies — no
   stringly map and no default parameters (E4009).
6. **State is Elm** over explicit primitives; events are typed messages
   registered Emo-side and exposed to the backend as `Int64` tags.
7. **The backend is an Emo interface** (`mount`/`patch`/`run`); the
   nine-verb `ui_*` contract is the native implementation detail.
8. **Platform libraries share convergent names**; platform-specific
   components carry the platform package's name at the call site.
9. **Sequencing: TUI and SSR first, native toolkits next, the browser
   DOM last.**
10. **No new syntax**; a checked block/function type is the one language
    ask worth weighing later, and it is not a gate.
11. **The EmoUI packages live in this repository under
    `projects/emo-ui/`** (settled 2026-10-15, `CHECK.md`). The directory
    is named for the eventual repository so `git subtree split` can
    extract it later with its history; `projects/emo-os/` and
    `projects/emo-shell/` are reserved by the same decision and stay
    empty until scheduled. Terminal input (T48.5) settles with it as a
    standard-library package in the `sqlite3` shape.

- [x] **T48.1** — The portable `ui` core package: the `Node` spine and
      primitives, the typed `Style` with `with_*` copies, the layout
      vocabulary, and the `Backend` interface. Pure Emo, all five hosted
      targets — which makes the two codegen defects the A/B spelling
      spike found part of this task. **Both landed 2026-10-15:** the `c`
      class metadata tables moved out of the `<cname>__<member>`
      namespace a method's symbol occupies (`vt_<cname>_fields` /
      `vt_<cname>_methods`, joining `vt_<cname>` and `iface_<name>`), and
      the `ocaml` native `String` `+` gained its `= Emo_check.String`
      branch emitting `(^)` in `emit_native_expr`; the two fixtures under
      `spike/emo-ui-spelling/codegen/` are the regression, and its
      `check.sh` asserts their build and their run. **The package landed
      2026-10-15** as `projects/emo-ui/` — `ui.emo` beside its own
      `package.emo` (`emo/ui`, declaring all five hosted targets) —
      and it settles the children question the spike left to it:
      children stay an explicit `Array[Node]`, and a list that is not
      known until it is walked is built with `ArrayBuilder`, not with an
      Emo `Array.append` loop. `projects/emo-ui/check.sh` is the
      package's gate. Writing it turned up one more toolchain defect,
      fixed here: `emo emoji build` named each target's output
      `emoji-<target>`, a stem the `beam` target refuses as a module
      name, so the pre-publish gate could not pass for any package
      declaring all five.
- [x] **T48.2** — The Elm loop: `App` (model/`update`/`view`), the
      `ui.on(msg)` tag registry and `ui.dispatch(tag)`, and
      `ui.run(view, update, model, backend)`; tag round-trip tests and a
      retained `patch` versus a full rebuild. **Landed 2026-10-15** as
      `projects/emo-ui/ui.emo` plus its `test.emo` (fourteen assertions,
      run by `./check.sh`). The tag table is a `Registry` object the loop
      owns and hands to `view` rather than the module-level table Layer 5
      sketched, because a module-level `const` re-runs its initializer on
      every read on the compiled targets and a module-level `var` is
      `ocaml`-only (`CHECK.md`). The loop compiles on `ocaml`,
      `typescript` and `beam`; `c` refuses the bare defs `ui.run` takes
      and `wasm` the two-argument dynamic call `update` needs — the same
      loop with its two functions behind a `Handler` interface builds on
      all five (`CHECK.md`, `projects/emo-ui/probe/`).
- [x] **T48.3** — The headless `debug` backend: the tree rendered to a
      stable text form, the byte-identical golden harness. **Landed
      2026-10-15** as `projects/emo-ui/debug.emo` (a module of the core's
      own package, so the core's test can use it) plus
      `projects/emo-ui/golden/` (a package in the consumer's position,
      `deps { "emo/ui" = "0.1.0" }`, reached through a registry
      `./check.sh` stages). The text form is one node per line, two
      spaces per level, props then a style summary in a fixed field
      order; `Debug` implements `Backend` over it by logging every tree
      the loop hands it, and its `run()` drives nothing — headless means
      no input source, so events are stepped by hand. `golden/main.emo`
      is one screen carrying every primitive, both `w=`/`h=` branches,
      all four `Align` values, an empty prop and nested containers;
      `expected.txt` is the interpreter's output, identical on `ocaml`,
      `c`, `typescript` and `beam`, while `wasm` cannot lower the core
      (the loop's shape, T48.2). Two silent cross-target divergences fell
      out and are recorded with minimal pairs (`CHECK.md`): operands were
      evaluated in the target's order, `ocaml`'s being the reverse of the
      others' — fixed 2026-10-17, left to right on every target — and an
      enum does not interpolate to the same bytes on `typescript` or at
      all on `beam` (`probe/eval_order`, `probe/enum_print`).
- [x] **T48.4** — `ui-tui`: the cell-grid layout (the small Emo box
      model) and ANSI painting; a scripted-input golden. **Landed
      2026-10-16** as `projects/emo-ui/tui/` (package `emo/ui_tui`:
      `ui_tui.emo` and `test.emo`), declaring the four hosted targets
      that can write stdout — `wasm`'s runtime has no `printf`, so the
      terminal backend is not a `wasm` package. The box model is the
      core's `Style` measured in cells: a column stacks, a row lines up,
      and `padding`, `gap`, `align`, `grow`, `width` and `height` place
      every child; `screen(root, w, h)` returns the grid as
      `Array[String]` so the arithmetic is testable without bytes, and
      `paint(root, w, h)` writes the frame as ANSI (clear, home, one row
      per line), the escape byte coming through `printf("%c", [27])`
      because a string literal's escapes are the minimal set and 0x1b is
      not one of them. `Tui` implements `ui.Backend` over that, and
      `Input`/`Script` are the scripted event source: `run()` pulls tags
      from the input and hands them to the loop's sink until the input
      says there are no more, which is what makes the golden terminal-
      free (T48.5 replaces the source, not the seam). `tui/golden/` is a
      consumer of both packages (`deps` on `emo/ui` and `emo/ui_tui`):
      one screen carrying a row with a centered shorter child, a scroll
      with a growing spacer, a fixed-width text input and two buttons,
      driven by a script that clicks Add, Add, Sub. `expected.txt` is
      the interpreter's output, identical on `ocaml`, `typescript` and
      `beam`; `c` compiles the backend and refuses the golden's loop
      shape (`Global`), which is T48.2's open decision now three targets
      deep rather than two. `tui/check.sh` is the gate (the package
      type-checks, thirteen assertions run, the four declared targets
      build, `wasm`'s `printf` refusal is pinned, and the golden's bytes
      are compared). Two `beam` defects the golden forced are fixed here,
      both recorded in `CHECK.md`: a bare def as a `Block` was emitted as
      a remote fun to a non-exported function, which `erlc` accepted but
      the loader left uncallable (`main/0` raised `undef`), and a `case`
      inside a loop body that rebound an outer `var` never threaded the
      rebinding out, so a `while` whose exit a branch set never ended.
      `test/emo_cli`'s `beam_block` and `beam_var` groups are the
      regressions. `examples/tui_menu/` is the usage demo — the same
      pattern with a four-row menu and a longer script — and the same
      gate checks it on every target it declares.
- [x] **T48.5** — Terminal input: raw mode and key events, as a
      **standard-library package in the `sqlite3` shape** —
      package-carried `.c`/`.h` reached through `foreign def`, gated by
      the manifest's `targets` — rather than a UI-framework or
      compiler-side artifact (settled 2026-10-15, `CHECK.md`); line mode
      first. **Landed 2026-10-18** as `stdlib/registry/term/0.1.0/`
      (package `term`, `targets = ["c"]`): `term.emo` is the surface,
      `internal/ffi.emo` the `foreign def`s, and `emo_term_shim.c` the
      C side of the exact ABI, checked against the generated
      `emo_defs.h` at compile time. `read_line` keeps its terminator,
      so a blank line and the end of input are different answers;
      `enable_raw` and `restore` save and put back the termios setting,
      and the exit path restores it too; `read_key` answers a `Key`
      member plus a code (a Unicode scalar for `char`, `0`–`26` for
      `ctrl`) and decodes the arrow, Home/End, Insert/Delete, Page
      Up/Page Down, F1–F12, Shift-Tab and Alt sequences, with a lone
      Esc settled after 50 ms. `size` and `is_tty` answer from the
      terminal driver. Scalar and String returns keep the generated
      struct names out of the ABI; the tuples are shaped in Emo. A
      plain `require` reaches the package — the embedded registry
      carries it — and the interpreter refuses it with E3009.
      `test/emo_cli`'s `term` group carries a pipe through line mode,
      key decoding, and the failure values; `examples/term_demo` is the
      runnable demo and rides in `c_goldens`. Raw mode is the one path
      a pipe cannot carry: the group pins its refusal off a tty, and
      the mode itself was checked over a pty while the package was
      built. Reference: `docs/stdlib/term.md`.
- [x] **T48.6** — `ui-ssr`: the node tree to HTML plus a stylesheet,
      byte-identical on all five hosted targets; forms and links as the
      interaction model. **Landed 2026-10-18** as
      `projects/emo-ui/ssr/` (package `emo/ui_ssr`: `ui_ssr.emo` and
      `test.emo`), declaring all five hosted targets. The renderer is
      pure Emo and names no host: three entry points — `page(title,
      root)` for a whole document, `fragment(root)` for a region a
      browser swaps in, `stylesheet(root)` for the CSS alone — walk the
      same pre-order tree, so the classes a page's markup carries are
      the ones its stylesheet defines. A node's class comes from
      interning on its base declarations and its `Style`
      (`e0`, `e1`, … in document order), which writes an equal style
      once and still keeps a `row` and a `column` apart; every prop
      reaching markup is escaped byte by byte through `substring(i, 1)`,
      so a multi-byte character rides through unchanged. The renderer
      adds the three nodes only a server round trip has anywhere to put
      — `form(action, children, style)`, `link(href, label, style)`,
      `field(name, value, style)` — while a `ui.button` inside a form
      submits its event tag as `event` and the core's `text_input`
      stays a read-only view of the model. `Ssr` implements `ui.Backend`
      by printing the document on `mount` and the fragment on `patch`;
      `run()` returns because a server has no input source, and
      `deliver(tag)` is the request that steps one event. `test.emo`
      pins escaping, the rule shape, interning and one assertion per
      node kind in twelve assertions; `golden/` renders a tree with
      every primitive, every `Align`, fractional extents and escapable
      text, and its bytes are the interpreter's on all five targets;
      `examples/ssr_page/` is the usage demo. `ssr/check.sh` is the gate
      and `../check.sh` runs it.
      The task also closed the `wasm` half of T48.2's open finding: its
      `Call_value`, `Closure` and `Global` lowering now allocate a
      function/struct type pair per arity (`closure_type`,
      `emo_wasm.ml`), so a `Block` value is first-class at any arity —
      the core loop's two-argument calls now lower. The core golden and
      `probe/def_shape` therefore build for `wasm`, and the core golden's
      bytes are the interpreter's on all five targets; `c` still refuses
      a bare def name (`Global`), which is the one refusal the gates pin
      (the SSR package's own `test.emo` reaches it through `ui.run`).
- [x] **T48.7** — The native packaging mechanism: per-package manifest
      fields (`pkg_config` and/or compile/link flags, plus whatever
      collects `.m`); the app-level build-script path is not the
      supported one. The gate for T48.8 and T48.9. **Landed 2026-10-18**:
      the manifest gains `pkg_config` — bare pkg-config modules whose
      `--cflags` compile the package's sources and whose `--libs` join
      the link — and `frameworks` — bare macOS frameworks, linked as
      `-framework NAME`; both refuse empty, flag-shaped, and
      path-shaped entries, so the manifest stays data. `.m` joins
      `.c`/`.h` in the collected set (dependency resolution, the
      embedded stdlib, and publish) and is compiled under `-fobjc-arc`,
      the c target's fixed Objective-C policy. Resolved flags enter the
      c build's cache key, an unresolvable module exits 69 with the
      install prompt, and `emo emoji build` passes a package's own
      native inputs the way a dependency's are passed, so the
      pre-publish gate links what consumers get.
- [x] **T48.8** — `ui-macos`: the nine-verb AppKit shim over the callback
      contract; the convergence corpus runs. Demo scale — the `c`
      target's long-running memory is step 49 (`CHECK.md`).
      **Landed 2026-10-18**: `projects/emo-ui/macos/` carries the
      point box model (`box.emo`, pure, so the interpreter tests it),
      the nine foreign verbs (`ui_macos.emo`, with `ui.Events` crossing
      as the callback pair) and `shim.m`, the only Objective-C outside
      `spike/`;
      `corpus/` runs one portable application on it under
      `EMO_GUI_AUTOTEST` and prints the pinned bytes. Getting there
      gave the `c` target def-as-value (`Global`): a capture-less
      closure over a per-def dynamic thunk, which closed the loop's
      last refusal and put `c` in every corpus run.
- [x] **T48.9** — `ui-gtk`: the GTK 4 shim, built with `pkg-config`;
      the convergence corpus runs. Demo scale, as T48.8.
      **Landed 2026-10-18**: `projects/emo-ui/gtk/` is the package
      `emo/ui_gtk`, declaring the `c` target and
      `pkg_config = ["gtk4"]`; the point box model (`box.emo`), the nine
      foreign verbs and the `Gtk` class (`ui_gtk.emo`), and `shim.c`
      mirror the macOS backend, with GtkFixed's top-left origin needing
      no y flip and the same `ui.Events` callback pair crossing the ABI.
      `corpus/` runs the same application, script, and pinned bytes.
      `gtk/check.sh` builds and runs natively where `pkg-config gtk4`
      answers, and otherwise compiles the same generated C in the
      `emo-ui-gtk-build` container (GTK 4 plus Xvfb), so the gate runs
      from a macOS host too.
- [x] **T48.10** — The browser runtime path: a browser-safe split of the
      TypeScript runtime (or a `dom_*` family in the runtime) plus the
      bundling step; the gate for T48.11.
      **Landed 2026-10-18**: the TypeScript runtime is now `ts_core.ts`
      — host-free, with a host object for output, process context,
      shutdown, method dispatch, and runtime implementations — plus
      `ts_node.ts` (the networking section, AsyncLocalStorage, the net
      method table) and `ts_browser.ts` (line-buffered console output,
      one page pid, the `dom_*` family). The compiler concatenates
      core+node into `ts_prelude` and core+browser into
      `ts_browser_prelude`, both as generated data.
      The `dom_*` family is thirteen calls — root, element, text,
      set_text, set_style, set_prop, append, clear, connect, value,
      sink, title, viewport — over Int64 handles into a host-side node
      table; the checker types them in every frame and the IR treats the
      prefix as a runtime implementation like `net_`. `emo build
      --target browser` emits one `.js` bundle: the emitter refuses
      processes (`do`, `<-`, `receive`) and every non-`dom_` runtime
      implementation by name, and the `typescript` target refuses
      `dom_*` by name. The bundling step is the CLI's — it strips the
      types with Node's own `module.stripTypeScriptTypes` (Node >=
      22.13), caches the JavaScript, and reports 69 when Node is
      missing or too old. The `browser` target joins `known_targets` and
      `emo/ui`'s manifest, and `emo doctor` reports it. Tests pin a
      bundle with no host imports running against a stub page, an event
      reaching the sink with its tag, the three refusals by name, and
      the doctor line.
- [x] **T48.11** — `ui-browser`: the DOM backend over the browser path;
      the convergence corpus runs. **Landed 2026-10-18**:
      `projects/emo-ui/browser/` is the package `emo/ui_browser`,
      declaring the `browser` target and pinned against `emo/ui`.
      `css.emo` maps a `Style` to the declarations the browser's own
      layout engine consumes — no point box model lives here, unlike
      macOS and GTK — and `test.emo` checks that mapping as values on
      the interpreter in 27 assertions. `ui_browser.emo` is the `Dom`
      class over the `dom_*` calls: `mount` sets the title, the
      page-root declarations and the sink; `render` builds one element
      per node, with a `button` carrying its tag as the `name`/`value`
      pair the SSR markup uses; `patch` rebuilds the tree, as every
      backend does; `run()` returns, because the page owns the loop.
      `corpus/` is the convergence consumer — the same application, the
      same `0,0,1,2` script and `expected.txt` — and `page.mjs` is the
      stub page the gate runs it in. `browser/check.sh` is the package's
      gate and skips where Node < 22.13 leaves no bundle to build.
- [x] **T48.12** — The convergence corpus: one sample application on
      every backend, with the same portable app module throughout.
      **Landed 2026-10-18**: `projects/emo-ui/corpus/` is the package
      `emo/ui_corpus`, the shared application — a counter as its state,
      an input and a submit button as its form, a scrolled list, and
      the three tags `view` registers — written once and consumed by
      every backend. `corpus/debug`, `corpus/ssr` and `corpus/tui` are
      thin entries under its own gate; `macos/corpus`, `gtk/corpus` and
      `browser/corpus` are thin entries under their packages' gates. Only
      the backend package and the entry module name the platform.
      `corpus/check.sh` pins the debug and SSR entries byte-for-byte on
      all five hosted targets (`ocaml`, `c`, `typescript`, `wasm`,
      `beam`) and the terminal entry on `ocaml`, `c`, `typescript` and
      `beam`, with its `wasm` refusal stated by name. The
      corpus also exposed a `wasm` codegen defect — a `ref.func` to a
      program def was absent from the declarative element segment — now
      fixed and pinned by a CLI test (`CHECK.md`). No language change
      was required.
- [x] **T48.13** — Docs: the README's EmoUI section revised to the
      array-children spelling and the settled decisions; `docs/emo-ui.md`
      settled into decided design where README-eligible; the EmoUI
      package references in its own repository.
      **Landed 2026-10-18**: the README's EmoUI section states the
      settled design — `Array[ui.Node]` children (with `ArrayBuilder`
      for a list that is walked), one `ui.Node` tree type and its
      lowercase constructors, the typed `Style` with `with_*` copies,
      the Elm loop over the loop's `Registry` and `Int64` tags, the
      `ui.Backend` seam, the backend packages, and the convergence
      corpus — and drops the stale claims that reactivity primitives
      live in the standard library and that UI events are process
      messages. `docs/emo-ui.md` now opens with a status note: the
      settled design lives in the README and the package references,
      and the note is kept as the assessment, the evidence, the
      rejected alternatives and the open questions, with the README
      authoritative on settled points; finding 1, the recommendation
      and decision 3 record that the README tree has been revised. The
      EmoUI repository carries the package references under
      `projects/emo-ui/docs/` — `ui`, `debug`, `ui_tui`, `ui_ssr`,
      `ui_macos`, `ui_gtk`, `ui_browser` and `ui_corpus` — in the
      `docs/stdlib/term.md` format: manifest, `def` signatures, and the
      behavior a caller can rely on, with an index. The Chinese
      translations of both READMEs and the two design docs were updated
      in step.
- [x] **T48.14** — The backends' sinks typed from birth, and every
      EmoUI gate re-run green. **Landed 2026-11-02.** The class-field
      typing of 2026-10-18 (`8171d0d`, a field carries its initializer's
      type) turned every backend's `self.sink = Box.new(0)` into a
      `Box[Int64]` that `mount` could no longer `replace` with the loop's
      `ui.Events` (E4004, then E4001 on the `deliver`): `debug.emo`,
      `ui_tui`, `ui_ssr`, `ui_browser`, `ui_macos`, `ui_gtk`, the
      translator demo's copy of the debug backend, and the core test's
      two recorders. That commit migrated the stdlib's `plot` and `json`
      and did not reach `projects/emo-ui`, whose gates are not under
      `dune runtest`, so `emo check` of the core package itself failed
      for two weeks unnoticed until the fb backend (emo-desktop A7.1)
      became the first consumer since. **The fix is the fb backend's own
      shape**: each backend carries an `Unmounted` whose `deliver` does
      nothing and an `unmounted()` declared to return `ui.Events`, so
      `Box.new(unmounted())` is a `Box[ui.Events]` from `init`; the core's
      test reuses `debug.unmounted()`. **Re-running the gates after two
      weeks found two more things.** The core gate's `enum_print` probe
      still pinned the pre-2026-10-19 divergence — `typescript`
      qualifying the tag, `beam` raising `emo_no_to_str` — while the
      probe program's own comment already described the fix (`CHECK.md`,
      the enum display form); the pins now expect the bare `red (ok,
      12.5)` on both. And the SSR golden's `— 世界` came back as
      replacement characters on `typescript` alone: `escape` rebuilt text
      byte by byte through `substring(i, 1)`, trusting a comment that
      called the slice byte-preserving, but the TS runtime's documented
      contract is that a cut inside a multi-byte sequence decodes to
      U+FFFD (a JS string cannot carry a partial byte) where the byte
      targets keep the raw bytes. `escape` now copies whole runs between
      the five ASCII specials — a cut beside one always falls on a
      character boundary — probing each position only for equality
      against them; the byte targets' bytes are unchanged and the TS
      golden is the interpreter's. Eighteen consumer `package.lock`s were
      regenerated with the new content digests. The umbrella gate
      (`projects/emo-ui/check.sh`: the core and its probes, the golden,
      the debug backend, `tui`, `ssr`, `macos` under AppKit with the
      self-driving script, `gtk` compiled and run in the container,
      `browser`, `corpus`) answers 218 ok and 0 FAIL; the translator demo,
      `examples/ssr_page` and `examples/tui_menu` are green with it; the
      fb gate is unaffected. The gates stay outside `dune runtest`, as
      they need `node`, `erl`, `opam`, Docker and a logged-in session —
      the two weeks are what that costs.

---

## M16 — Value-family reclamation

The `c` target's reclamation model (T23.5, 2026-10-11) counts references
over the identity-bearing cells — instances, closures, `Box` — and lets
every value-semantic kind (strings, tuples, arrays, maps, lists, bytes,
enums, boxed scalars) sit in a bump arena until process exit. A UI
re-runs `view()` per event on exactly those kinds, which is what turned
a tidiness item into a product problem. The 2026-10-14 arena-scope spike
measured the cost, ruled out the cheap fixes, and settled the direction:
a region reclaims 100% of the arena's bytes and 0% of the leak, because
identities are `malloc`'d outside it and the arena's aggregates retain
them across its boundary — and the reset strands those refcounts
permanently. The real fix is refcounting the value families, and it is
this milestone (`CHECK.md`, `spike/arena-scope/`). Nothing here is a
prerequisite for step 48: the native backends are built at demo scale
with the limit documented. (The note retired 2026-10-17 — the
milestone landed and the working set is flat; the T49.4 gate pins it.)

### Step 49 — Value-family reclamation · `plan/step-49-value-reclamation.md`

**Prereq:** none — explicitly not a prerequisite for step 48.
**Done when:** a long-running `c`-target program holds a flat working
set — arena bytes and identity liveness stop rising per render and track
the live tree — array growth is linear rather than quadratic, every
existing golden on every target is byte-identical, and the interpreter
and the non-`c` targets are untouched.

- [x] **T49.1** — The runtime: extend the identity discipline
      (`emo_identity_kind`, `emo_retain`/`emo_release`, and the
      constructors that store into aggregates) from the three identity
      kinds to the value families, so a value cell can reach refcount
      zero and an aggregate releases what it holds; includes the audit
      that no value-family construction can form a cycle. The emitter
      already retains and releases every dynamic binding
      (`emo_c.ml:1851`, `:423`), so this starts runtime-side.
      **Landed 2026-10-17.** Every cell is counted and individually
      freed; the emitter's `may_own` widened to every dynamic type, so
      each construction pools its birth and each claim handout lands in
      the statement's pool; the tail-rebind and hoisted-binding
      barriers take the new claim before dropping the old; `Map.remove`
      hands back a claim; the dynamic→native String crossing copies.
      The cycle audit: the immutable families are structurally acyclic,
      the mutable identities join the documented cycle-leak class. The
      live-count probe returns to baseline across a value-family churn;
      the native transient buffers stay the T49.2 remainder.
- [x] **T49.2** — The granularity: decide what the autorelease pool owns
      now that every dynamic type may own memory, and implement it —
      expression-internal temporaries are the hard half, `may_own` plus
      the constructor audit that follows (`emo_c_runtime.c:1753`).
      **Landed 2026-10-17: String joined the dynamic world** (`CHECK.md`
      carries the written weighing — the wider pool and the smarter
      emitter were rejected as unsound or as the ownership analysis the
      pool exists to erase). Typed `String` positions are cells; the
      leaf string builders answer self-pooled births (no arena
      intermediate, no frame of their own); the general constructors
      still pool at the emitter; the runtime's own transients (printf
      buffer, file/net reads, argv, list_dir names) are malloc'd and
      freed within their calls. The churn probe holds RSS flat across
      3 000 / 30 000 / 120 000 iterations with the live count at zero,
      and every golden stays byte-identical.
- [x] **T49.3** — The array shape: an O(1) append or a builder, so
      growing a k-element array is not quadratic in bytes and retains;
      T48.1's children representation depends on the answer. **Settled
      2026-10-15 — a builder, and a new language-level type
      (`ArrayBuilder`) rather than an `Array` representation change.**
      `new()` / `push` / `length` / `get` / `to_array`, on the
      interpreter and all five hosted targets (`riscv64` refuses it by
      name, exit 65, the `Map` precedent); the first statically-typed
      `push` pins the element type of the `const` binding at the base of
      the pushed chain (`docs/intro/syntax.md`, Mutability). The second
      shape this task names — a conversion back from `List` to an
      indexable `Array` — is deliberately not taken. This answers the
      array half without touching the runtime, so step 49's "array growth
      is linear rather than quadratic" criterion is now reachable through
      the language rather than through T49.1; T48.1's representation
      question was unblocked here and is **answered** by the core
      (2026-10-15): children are an explicit `Array[Node]`, and the
      container is what builds a dynamic child list.
- [x] **T49.4** — The gate: the spike's render ladder and region probes
      as a checked-in test that fails today and passes after, on the `c`
      target, with `dune test` green. **Landed 2026-10-17** —
      `emo_arena_bytes` joined the runtime's probes, and the
      `c_flat_working_set` group runs the spike's render shape (view
      rebuild, style maps, append-built children, a layout walk) at two
      rungs: both deltas — arena bytes and live cells — pin at exactly
      zero. The region probes' work is done by the refcount model
      itself (`arena_mark`/`arena_reset` stayed out of the shipped
      runtime).
- [x] **T49.5** — Docs: `CHECK.md`, `docs/emo-ui.md` and its zh-CN
      mirror, and step 48's demo-scale notes updated to point here.
      Landed 2026-10-17 — `CHECK.md`'s entry reads as the landed
      decision, `docs/emo-ui.md`'s ask 4 and the layer caveats point at
      the flat working set, and every demo-scale note carries its
      retirement.

---

## M17 — Cross-target conformance

A 2026-10-14 target-feasibility survey checked the concurrency promises
against every implementation and found three places where the rules and
the code disagreed (`CHECK.md`, cross-target invariants). Two of them
were never open design questions: `docs/intro/concurrency.md` already
promises that an unhandled error "kills only the offending process", and
`docs/intro/syntax.md` already promises a snapshot copy at the process
boundary for Map, Box, List and ArrayBuilder — with the interpreter, the
standalone OCaml runtime and BEAM all honouring both, and
`stdlib/registry/sync/0.1.0/sync.emo` stating the send rule outright for
a handle. The `c` target was the one implementation that diverged, so
the work here is conformance, not language design: no promise moves and
no README changes. The third item is the same shape on the emitter side —
the capability table is the intended sole gate on `foreign def`, but it
admits `Float64`/`String`/`Bool` on every target, so a `foreign def`
reached the `wasm` and `beam` emitters past it. The milestone's own
finding is that the survey's cost estimate for the `raise` gap was
wrong, and by a wide margin: the mechanism it assumed — `setjmp` /
`longjmp` plus a reference-count drain at every unwound C frame — was
never needed, because the runtime's autorelease pool is already a
heap-allocated frame chain hung off the fiber, and the fiber teardown
path already existed. Everything here is runtime- and emitter-local.

### Step 50 — Cross-target conformance · `plan/step-50-cross-target-conformance.md`

**Prereq:** none.
**Done when:** a spawned `c`-target process that raises dies alone while
its parent runs on; a mutable value sent between `c`-target processes
arrives as a snapshot; `foreign def` refuses by name on `wasm` and
`beam` with exit 65; every existing golden on every target is
byte-identical; and `CHECK.md` records all three as settled with the
`typescript` send gap named as the remainder.

- [x] **T50.1** — The `foreign def` refusal: `emo_wasm.ml` and
      `emo_beam.ml` refuse a `foreign def` per function, beside the code
      that would have lowered it, with `Emo_ir.Lower_error` — the
      riscv precedent — so the CLI renders it as exit 65. The survey's
      open guess ("a clean refusal downstream or a silently absent
      symbol") resolved to the second: the IR carries the symbol on an
      otherwise ordinary `func` record with an empty body, so both
      emitters were emitting a real function for a declaration that has
      no Emo body. Refined by T39.3: the declaration now imports cleanly
      on every target, and the refusal moved to the call.
- [x] **T50.2** — The `c` target's `raise` ends the logical process:
      `emo_raise` drains the current fiber's frame chain and halts it
      when it is not the root, keeping the render-and-`exit(1)` path for
      a raise outside the scheduler or in the root (`docs/intro/
      concurrency.md`). `halt()` routes through the same drain — it
      leaked its whole frame chain, the one other site with the same
      shape. No emitter change and no unwinder: the frame chain is on the
      heap and the fiber-teardown path already existed.
- [x] **T50.3** — The `c` target's `send` snapshots: `emo_deep_copy`
      rebuilds the mutable kinds at the send and the mailbox owns the
      copy, following the interpreter's own rule over the kinds this
      runtime has. One emitter line followed from it — the mailbox take
      releases its only claim, so the receive scan now holds its own.
- [x] **T50.4** — Docs: `CHECK.md`'s cross-target entry rewritten as
      settled with the corrected cost estimate, `docs/intro/
      concurrency.md`'s by-reference sentence fixed, T23.6's note
      updated, the gates table updated, and this milestone added. The
      `typescript` target's share-on-send is recorded as the entry's open
      remainder rather than fixed here, because the fix belongs with the
      browser-runtime split (T48.10).

---

## M18 — TLS on the `c` target

TLS was never missing from the standard library — `net_tls_connect`,
`net_tls_connect_insecure` and `net_listen_tls` exist as builtins, the
interpreter's scheduler and the standalone OCaml runtime implement them
through the opam `ssl` library, `typescript` maps them onto
`node:tls`, and `http`'s `https://` routes through `net.tls_connect`
in plain Emo source. The gap was the `c` target, the default: the
three names fell to `emo_unsupported`, so `https` was dead precisely
where `emo build` runs by default. The work is conformance, not
surface: the C runtime lands the three builtins against the system
OpenSSL/LibreSSL with the ocaml scheduler as the semantic reference,
the linkage keys on IR use so a program that never touches TLS never
links OpenSSL, the prototypes are hand-declared because no target
platform owes the build OpenSSL headers, and the user-level-FFI route
was evaluated and refused (`CHECK.md`).

### Step 51 — TLS on the `c` target · `plan/step-51-tls-c-target.md`

**Prereq:** none.
**Done when:** an `https://` request runs end-to-end on `c` (the
captive TLS server, byte-identical to the interpreter's
`expected.txt`); the verified handshake, the verify-fail pin, the
insecure roundtrip and the server-side TLS echo are green on the
interpreter and on `c`; a non-TLS `c` build neither links nor requires
OpenSSL (the `nm` pin) and every existing golden on every target stays
byte-identical; the runtime-manufactured reason strings are
byte-identical across interp / `c` / the standalone ocaml runtime; and
the docs carry the story (`docs/stdlib/net.md`, `docs/stdlib/http.md`,
the zh-CN mirrors).

- [x] **T51.1** — The linkage gate: the fenced TLS section in
      `emo_c_runtime.c`/`.h` — hand-written prototypes plus the frozen
      constants, real bodies under `EMO_HAS_TLS` and `emo_unsupported`
      bodies without — the emitter's explicit arms for the three names
      with its IR-walk `uses_tls` flag, and the CLI's conditional
      `-DEMO_HAS_TLS` + `-lssl -lcrypto` through the cclib slot behind
      a pre-flight probe whose failure names the fix; the c_goldens
      `nm` pin proving a non-TLS build references no `SSL_` symbol.
- [x] **T51.2** — The client handshake: TCP via the existing
      `emo_net_connect`, then nonblocking `SSL_connect` parking on
      `WANT_READ`/`WANT_WRITE` (a wait-writable hook joins the
      scheduler's poll loop); `TLS_client_method`, the TLS 1.2–1.3
      window, the system trust store, SNI, `SSL_set1_host` +
      `SSL_get_verify_result`, the version-floor refusal carrying the
      library's own version string, the
      `the TLS handshake with <host>: ` reason prefix, and the CA +
      server-certificate fixture (`SAN=localhost,127.0.0.1`) with a
      verified loopback handshake driven through `SSL_CERT_FILE`.
- [x] **T51.3** — The data plane and the insecure variant: read/write
      route through the `fd → SSL*` side table with the same parking
      discipline, `close()` runs `SSL_shutdown` and frees, timeouts
      match the ocaml conn's semantics, and
      `net_tls_connect_insecure` is the same path with verification
      off.
- [x] **T51.4** — The server side: `net_listen_tls` loads the PEM pair
      (refusing with the ocaml-matching
      `cannot load the TLS certificate for <host>:<port>` shape),
      listeners register fd → context, `accept` performs `SSL_accept`
      and registers the conn; an in-program TLS echo server + client
      on `127.0.0.1:0`, on the interpreter and on `c`.
- [x] **T51.5** — The goldens: `examples/https_roundtrip` against the
      harness's captive ocaml-ssl TLS server, `expected.txt` taken
      from the interpreter and byte-identical on `c`, registered in
      c_goldens; a TLS roundtrip test for the standalone OCaml
      runtime, which implemented TLS but never tested it.
- [x] **T51.6** — Docs: `docs/stdlib/net.md`'s TLS limitation becomes
      the implemented story (ocaml-ssl / node:tls / system
      OpenSSL-LibreSSL, with the floor stated),
      `docs/stdlib/http.md`'s "`https` needs TLS, which `c` refuses"
      retired, the zh-CN mirrors, the gates table and
      `plan/README.md`'s status table updated.

## M19 — Map on `wasm` and `beam`

`Map` is the one capability builtin the two remaining hosted targets
refuse: the interpreter, `c`, `ocaml`, and `typescript` implement it,
while `wasm` and `beam` reject a map literal at lowering (`the
wasm/beam target does not support Map yet`, a refusal dating from when
the two runtimes shipped in T16–T18). The refusal has grown
load-bearing: the `plot` package's `Table` and channel vocabulary are
Map-shaped (decision 4/10/16, Step 42 blocked on it), `slog`'s manifest
narrows itself while the gap stands, and `Exception.new(data:)` — a
Map — cannot carry crash context on either target (`CHECK.md` records
the standing note). The mechanism exists on both sides already: `wasm`
lowers the mutable `List` through WasmGC structs (`$vlist` over `$lnode`
nodes, runtime functions 61–67) and `beam` through the process
dictionary keyed by a fresh ref (`emo_list_new`, the `{'emo_list', K}`
tag), each with the same shape of method surface Map needs. M19 lands
Map through those precedents — the insertion order, the six key kinds,
structural `==` (content equality, insertion order irrelevant, the
interpreter's rule), and the `{key: value}` rendering byte-identical
with the four targets that have it — and closes the recorded `wasm`
send-snapshot remainder that the new mutability makes reachable
(`CHECK.md`, step 50). Mutable kinds stay process-local on `beam` (the
`List` precedent — a tag sent across processes fails loudly at first
use, `emo_no_list` today, `emo_no_map` beside it); `riscv64` stays the
one refusal, the capability tier frozen.

### Step 52 — Map on `wasm` and `beam`

**Prereq:** none (the interpreter and the `c`/`typescript`
implementations are the semantic reference).
**Done when:** a map program — literals, `Map.new`, the seven methods,
structural `==`, the `{key: value}` print, aliasing through two
bindings — runs byte-identical on all six paths (interp, c, ocaml, ts,
wasm, beam); `Exception.new(data:)` carries data on `wasm` and `beam`;
`send` delivers a snapshot on `wasm`; `slog` declares the two targets
and its golden joins their lists; every existing golden on every target
stays byte-identical; the docs carry the story.

- [x] **T52.1** — The wasm runtime's map structures: a `$vmap` — key
      array, value array, count, in the `$vbuilder` doubling-buffer
      shape, linear-scan lookup (plot-scale maps are small, and the
      array order *is* the insertion order) — with the runtime
      functions `map_new`, `map_get` (E3004
      `no key ... in this Map` on a miss, the interpreter's error),
      `map_set` (an existing key keeps its first-insert position),
      `map_has`, `map_remove` (compaction preserving relative order),
      `map_len`, `map_keys`, `map_values`, `map_str` (the
      `{key: value}` rendering in insertion order, elements and keys
      through the shared `to_str`), and the boxed-primitive key
      equality helper; appended after the array/builder renderings with
      the index table and `runtime_count` updated (main stays at 60,
      List at 61–67, the map ops following).
- [x] **T52.2** — The wasm lowering: `Map_lit` builds through
      `map_new` (the emitter packs `Map.new`'s variadic pairs), the
      seven methods dispatched on the receiver's `MapType`, structural
      `==`, and `to_string` wired; the two `Lower_error` refusals in
      `emo_wasm.ml` (the `Map_lit` arm and the `MapType` method arm)
      deleted, and the stale `Make_exception` comment updated so
      `Exception.new(data:)` lowers.
- [x] **T52.3** — The wasm send snapshot: `rt_send` deep-copies the
      message before it joins the mailbox — Map, Box, List, and
      ArrayBuilder rebuilt (a map copy preserving insertion order), the
      immutable kinds and `Pid` passing through — the `c` runtime's
      `emo_deep_copy` rule, closing the recorded conformance remainder
      (`CHECK.md`, step 50); the `cross_target` corpus pins it on
      `wasm`.
- [x] **T52.4** — The beam runtime's map helpers under the
      `emo_list_new` discipline: `emo_map_new/1` mints a fresh ref and
      stores `{Order, Pairs}` — the insertion-order key list and an
      Erlang map key→value — in the process dictionary behind
      `{'emo_map', K}`; `emo_map_get/2` (the interpreter's E3004
      message on a miss), `emo_map_set/3` (first-insert position kept),
      `emo_map_has/2`, `emo_map_remove/2` (the order list filtered),
      `emo_map_length/1`, `emo_map_keys/1`, `emo_map_values/1`,
      `emo_map_str/1`, and `emo_map_equal/2` (same size, per-key value
      equality, order irrelevant); keys are the six hashable primitives
      compared with `=:=`, so `1` and `1.0` stay distinct.
- [x] **T52.5** — The beam lowering: `Map_lit` → `emo_map_new`, the
      method arms splitting on the `{'emo_map', K}` tag where a name
      serves several types (`get`, `length`, `to_string` — the bytes
      precedent), structural `==` through `emo_map_equal`, and the
      stale `Make_exception` comment updated so `Exception.new(data:)`
      carries data on `beam`.
- [x] **T52.6** — The golden: `examples/map_demo` — a literal,
      `Map.new(pairs)`, the seven methods, insertion order through
      `keys()`/`values()`, first-insert positions, removal, aliasing,
      `==` (equal content in different insertion order, and unequal
      maps), the `{key: value}` print, and an `Exception.new` carrying
      `data` — `expected.txt` taken from the interpreter and
      byte-identical in all five golden lists; the check-time key-kind
      pin (E4020) rides the existing diagnostics tests.
- [x] **T52.7** — The stdlib widening: `slog`'s manifest gains `wasm`
      and `beam` (its close-out's recorded condition — declares the
      targets that work today, widens when the gap closes), and
      `slog_demo` joins the wasm and beam golden lists byte-for-byte.
- [x] **T52.8** — The docs: `docs/demo-targets.md`'s capability story
      (the `wasm`/`beam` Map refusals retire; `riscv64` stays the one),
      `docs/stdlib.md`'s slog row, `docs/visualization.md`'s
      five-target Table claim now literally true, `CHECK.md`'s T16.5
      note (`slog` waits on `Map`) recording its resolution, the zh-CN
      mirrors, and `plan/README.md`'s status table.

## M20 — The numerical library

The netlib assessment (`docs/math-netlib.md`, 2026-10-22) split "a
high-performance numerical library on netlib" into two goals that pull
apart: netlib supplies algorithms and reference semantics, not speed,
and the array-class performance tier sits behind the array FFI gate —
no `Array[T]` crosses `foreign` in any position (E4200), arrays are
boxed and value-semantic, and the `c` runtime is one OS thread. What
the assessment found ready is everything before that gate. `math` 0.1.0
already answers `exp`/`log`/`log10`/`pow` byte-for-byte on all five
hosted targets through fixed-order series over
`Float64.to_bits`/`from_bits` (the plot SVG goldens rest on it), and
T39.3 settled the opt-in `*_native` fast path pinned to `c`/`ocaml`,
inert elsewhere. M20 extends that machinery along the assessment's
first two stages. Step 53 completes the pure-Emo surface — the
trigonometric, inverse, and hyperbolic functions, `log2`/`exp2`/
`hypot`, complex arithmetic and a radix-2 FFT after FFTPACK, BLAS1
over value-semantic arrays, an LU solver with partial pivoting after
LAPACK's `gesv`, and the error and gamma functions — each
byte-identical on the five targets, with an ELEFUNT-derived battery
printing its loss-of-bits as a golden so accuracy is a diff. Step 54
adds the native fast lane: the `fastmath` package — `math`'s scalar
surface as host-libm bindings on `c`/`ocaml`; the four `*_native`
twins T39.3 landed inside `math` 0.1.0 move there unreleased, so
`math` stays pure and byte-identical on all five targets — and the
`quad` package vendoring f2c-translated QUADPACK behind a
scalar-and-callback shim — the one shape today's FFI admits — on `c`,
its convergence failures reported through the `(R.ok, …)`/`(R.error,
…)` split. Stage 3 — BLAS2/3 and LAPACK subsets bound natively — is
not in this milestone; it waits on the array FFI gate as its own
compiler step. Every task is sized for spare time: each leaves `dune
test` green and every existing golden byte-identical. The provisional
decisions are marked on the tasks that make them: BLAS names as the
API vocabulary, complex values interleaved in a flat `Array[Float64]`,
matrices as a flat row-major `Array[Float64]` with an explicit
dimension, the range-reduction bound, and the package name `quad`.

### Step 53 — The pure-Emo numerical surface

**Prereq:** none (`math` 0.1.0's series discipline is the base; T39.3
settled the native mechanism, superseded before Step 54 by the
`fastmath` package).
**Done when:** every new function answers byte-identical on all five
hosted targets through the series discipline, each under a golden in
`examples/`; the ELEFUNT-derived battery is a golden; every existing
golden on every target stays byte-identical; `dune test` green; the
docs carry the surface and its accuracy record.

- [x] **T53.1** — `sin` and `cos`: Cody–Waite range reduction to
      |r| ≤ π/4 against a split π/2 (a three-part constant, so the
      reduction is exact up to a documented |x| bound — beyond it the
      call raises rather than silently losing bits; provisional, a
      Payne–Hanek reduction can lift the bound later), quadrant
      selection, and a fixed-order Taylor series for each — the same
      operations in the same order on every target.
      `examples/math_trig` is the golden.
- [x] **T53.2** — `tan`: T53.1's reduction, then the quotient of the
      two reduced series with the quadrant's sign and reciprocal
      switch; the poles are unreachable in binary floating point, so
      there is no domain raise, and the behaviour near π/2 is
      documented. `examples/math_trig` grows the panel.
- [x] **T53.3** — `atan` and `atan2`: argument folding (|x| > 1
      through the reciprocal identity, the tan(π/12) fold into a short
      series range), a fixed-order odd series, and `atan2`'s quadrant
      assembly with the axis and signed-zero cases spelled out —
      `atan2(0.0, 0.0)` raises (provisional: the C convention returns
      0, Emo's domain rule says there is no value). Golden
      `examples/math_inverse_trig`.
- [x] **T53.4** — `asin` and `acos`: through the `atan` core
      (`asin(x) = atan(x / sqrt(1 − x²))`, the complementary form as
      |x| nears 1 so the root does not cancel), `acos` from `asin`;
      |x| > 1 raises, the package's domain rule.
      `examples/math_inverse_trig` grows.
- [x] **T53.5** — `sinh`, `cosh`, `tanh`: compositions over the
      existing `exp`, a short odd series for small |x| in `sinh` and
      `tanh` (the difference `(e^x − e^−x)/2` cancels there), `tanh`
      saturating to ±1 before `exp` could overflow; `sinh`/`cosh`
      overflow raise, the `exp` rule, since `beam`'s floats cannot hold
      infinity. Golden `examples/math_hyperbolic`.
- [x] **T53.6** — `log2`, `exp2`, `hypot`: `log2` from the `log`
      decomposition's exponent and mantissa, not `log(x) / ln 2`, so
      every power of two answers exactly; `exp2` through the `exp`
      scaling (`pow2` for the integer part, the series for the
      fraction); `hypot` overflow- and underflow-safe through a
      power-of-two rescale. `examples/math_demo` grows.
- [x] **T53.7** — Complex arithmetic (`internal/complex.emo`): add,
      sub, mul, div (Smith's algorithm, so the naive quotient cannot
      overflow), `abs` through `hypot`, `conj`, scaling, and
      `from_polar(r, θ)` through T53.1's `sin`/`cos`; a value is a
      `(re, im)` `Float64` pair on the scalar surface and interleaved
      in a flat `Array[Float64]` where a vector is needed (provisional
      — the FFT is the consumer). `examples/math_complex` is the
      golden.
- [x] **T53.8** — The radix-2 complex FFT after FFTPACK's
      `cfftf`/`cfftb`: iterative Cooley–Tukey over T53.7's interleaved
      array, bit-reversal permutation, twiddles from the package's own
      `sin`/`cos` so the table is byte-identical rather than libm's,
      forward and inverse (`ifft` scaling by 1/n); a length that is not
      a power of two raises — mixed radix is later work, not a silent
      fallback. The golden `examples/math_fft` pins the result against
      a naive O(n²) DFT computed in the same program.
- [x] **T53.9** — BLAS1 over `Array[Float64]`, value-semantic: `dot`,
      `nrm2` (the reference BLAS's scaled accumulation, overflow-safe),
      `asum`, `iamax`, and `scal`/`axpy` returning new arrays —
      nothing writes in place, there is no in-place in Emo; mismatched
      lengths raise. The accumulation order is fixed and documented,
      which is what makes the five targets agree. BLAS names as the
      vocabulary (provisional). Golden `examples/math_blas1`.
- [x] **T53.10** — The dense solver after LAPACK's `getrf`/`getrs`:
      `lu(a, n)` — LU with partial pivoting over a flat row-major
      `Array[Float64]` with an explicit dimension (provisional: no
      nested arrays, one allocation per matrix) returning the packed
      factors and the pivot vector as `Array[Int64]`; `solve(a, n, b)`
      the `gesv` shape; an exactly zero pivot raises — the matrix
      analogue of division by zero — and the threshold is documented.
      Golden `examples/math_solve` with textbook systems, one of them
      failing without pivoting.
- [x] **T53.11** — `erf` and `erfc`: the Maclaurin series below the
      crossover, the continued fraction for `erfc` above it, each
      fixed-order; `erfc` is its own function rather than `1 − erf` so
      the tail does not cancel. Golden `examples/math_special`.
- [x] **T53.12** — `tgamma` and `lgamma`: the Lanczos approximation
      with one fixed coefficient set written into the source
      (byte-identical by construction), the reflection formula on the
      negative half-line, `lgamma` covering the range `tgamma`
      overflows; non-positive integers raise, the poles.
      `examples/math_special` grows.
- [x] **T53.13** — The ELEFUNT-derived battery: Cody & Waite's identity
      tests across the surface (`sin` against
      `3 sin(x/3) − 4 sin³(x/3)`, `exp` against its shifted-argument
      identity, `log` against the product form, and so on) over fixed
      pseudo-random arguments — the package carries a small linear
      congruential generator so the sequence is byte-identical —
      printing the maximum and RMS loss in bits per function. A golden,
      `examples/math_elefunt`, whose `expected.txt` is the accuracy
      record: a regression is a diff.
- [x] **T53.14** — The docs: `docs/stdlib/math.md` (and the zh-CN
      mirror) with the full surface, the domains and the raise rules,
      the accuracy record from T53.13, and the representation decisions
      (interleaved complex, flat row-major matrices); `docs/stdlib.md`'s
      math row; the new goldens in the five golden lists;
      `plan/README.md`'s status table.

### Step 54 — The native fast lane

**Prereq:** Step 53 (the pure surface the native tier shadows; T53.13's
battery is the acceptance).
**Done when:** the `fastmath` package carries `math`'s scalar surface
bound to the host libm on `c` and `ocaml`, unavailable elsewhere (a
`require` fails E5007 at load); the `quad` package integrates
on `c` with QUADPACK's error flags mapped through the
`(R.ok, …)`/`(R.error, …)` split; every existing golden on every target
stays byte-identical; `dune test` green; the docs carry both.

- [x] **T54.1** — The host-libm bindings of Step 53's scalar functions
      in `fastmath`, unsuffixed (`sin` through `tanh`, `atan2`,
      `log2`, `exp2`, `hypot`, `erf`, `erfc`, `tgamma`, `lgamma` — the
      package qualifier says native), growing the package that already
      carries the four twins moved out of `math` 0.1.0 unreleased
      (`exp`, `log`, `log10`, `pow`, with `e`/`pi`) and
      `examples/fastmath_demo` (renamed from `math_native`, in the c
      golden list). The pinning is the package's
      `targets = ["ocaml", "c"]`: a `require` on any other target
      fails E5007 at load, and under the interpreter a call raises
      E3009. Documented as host-libm and not byte-identical.
- [x] **T54.2** — The battery on the natives: a `c`-only companion
      (`examples/fastmath_elefunt`, in the c golden list alone)
      running T53.13's identities over `fastmath`'s bindings and
      printing each function's verdict against a stated loss budget
      rather than the raw bits, so the golden holds across host libms —
      the number the assessment asked for before the fast lane is
      called accurate.
- [x] **T54.3** — The `quad` package (provisional name),
      `targets = ["c"]`, after the `sqlite3` precedent: f2c-translated
      QUADPACK `dqags` and the routines it pulls (`dqagse`, `dqk21`,
      `dqelg`, `dqpsrt`, the `d1mach` constants rewritten as literals)
      vendored in the package tree; a C shim owning the workspace (a
      fixed `limit`) and exposing the one shape today's FFI admits —
      the integrand as a single-method interface
      (`def at(x Float64) Float64`, the callback contract), bounds and
      tolerances as `Float64`, the `(result, abserr, neval, ier)` tuple
      back; the Emo surface `integrate(f, a, b, epsabs, epsrel)` maps
      `ier = 0` to `(R.ok, (value, abserr))` and QUADPACK's failure
      codes to `(R.error, reason)` in netlib's wording — a convergence
      failure is an expected outcome, not a violation. Golden
      `examples/quad_demo` in the c golden list.
- [x] **T54.4** — The infinite ranges: `dqagi` through the same shim
      (netlib's transformation onto (0, 1]), surfaced as an enum
      argument naming the three ranges — from a bound to +∞, from −∞
      to a bound, the whole line — rather than infinite `Float64`
      bounds (provisional naming). `examples/quad_demo` grows.
- [x] **T54.5** — The docs: `docs/stdlib/quad.md` (EN + zh-CN) with
      the API, the error-code mapping, and the host-dependence note;
      `docs/stdlib.md`'s rows (`math`'s row, the `fastmath` row, the
      `quad` row); `docs/stdlib/fastmath.md` grown with the full
      surface (the page exists with the four moved bindings and the
      zh-CN mirror);
      `docs/math-netlib.md`'s stage table marked with stages 1–2 landed
      and stage 3 still parked, with its zh-CN mirror;
      `plan/README.md`'s status table.

## M21 — The crypto package

The Go survey (`pkg.go.dev/crypto@go1.27.3`, 26 packages) set the
scope by subtraction. Go keeps the broken past — DES, RC4, DSA, MD4 —
only because legacy data still needs decrypting; a new standard
library has no such liability and declines them. Half of Go's
packages are protocol plumbing — `tls`, `x509`, `asn1` — and that
layer already has its answer in step 51: `net`'s TLS rides the system
OpenSSL/LibreSSL, not an Emo-side stack. What remains is the portable
primitives layer, and the pure-Emo rule is the point rather than a
compromise: `math` 0.1.0 established that fixed-order source is
byte-identical on all five hosted targets, and RFC and NIST test
vectors then pin every target to the same answer — cross-checked bit
for bit against Go's own packages, generated on this machine and
frozen into the goldens, so the interop claim is a diff. The step
lands one package, `crypto` — hashes (SHA-2, SHA-3, SHAKE; MD5 and
SHA-1 behind `crypto.legacy`, the name the warning), HMAC, HKDF and
PBKDF2, the constant-time compares, ChaCha20-Poly1305, AES with GCM
and the block modes, and Ed25519/X25519 — plus its own `rand`
package, because entropy is the one thing pure Emo cannot conjure and
binding it per target would split `crypto`'s target list. The error
split follows the house rule: a wrong key length raises, a failed tag
verifies as `(R.error, "crypto: authentication failed")`. Two honesty
sections ride the docs: AES lands as T-tables first with the
cache-timing caveat stated in the same breath (the AES-NI shim is
later optional hardening on `c`; GHASH is bitwise and carries no such
caveat), and constant-time is promised as a source-level discipline —
no secret-dependent branches or table indices — with each backend's
guarantee documented per target rather than overstated. RSA waits for
an internal bignum foundation; Ed25519 covers signing with fixed-limb
field arithmetic. TLS, x509, and the post-quantum set stay out; each
is its own future step. Every task keeps the idle-time sizing
discipline: after each one `dune test` is green and every existing
golden is byte-identical.

### Step 55 — The standard library: `crypto` · `plan/step-55-stdlib-crypto.md`

**Prereq:** none (`base64` is the byte-discipline working example;
`math` 0.1.0 proves the pure-Emo series discipline carries real
algorithms).
**Done when:** every pure function answers byte-identically on every
target its golden rides; the RFC/NIST vectors and the Go-generated
companions are pinned as diffs; Project Wycheproof cases sit at the
sampled boundaries; every existing golden on every target stays
byte-identical; `dune test` green; the docs carry the surface, the
error split, and the honesty sections.

- [x] **T55.1** — The word discipline and the package skeleton: the
      probe first — `>>` measured arithmetic (sign-extending) and
      `<<` wrapping modulo 2^64 on the interpreter, byte-identical on
      `c`; `internal/word.emo` with the mask-idiom logical right
      shift (`(x >> n) & ((1 << (64 - n)) - 1)` for constant
      `n > 0`), `rotl`/`rotr` in both widths, and the big-endian
      u32/u64 `Bytes` load/store; `stdlib/registry/crypto/0.1.0` —
      the manifest over all five targets, the root `crypto.emo`
      carrying `subtle` (the constant-time equality the MACs verify
      through); the 29 probe vectors verified against an independent
      computation and pinned from T55.2 on through the digest
      goldens — an example cannot reach `internal/`. The probe also
      flushed a c-target corner: a module bound to a name
      (`const word = word`) answers dynamic at its use sites, and
      the dynamic world refuses the bitwise operators — the
      package's modules call their internals through the direct
      qualified path (`word.lshr(…)`), never through a wiring const.
- [x] **T55.2** — SHA-256 and SHA-224 (FIPS 180-4): the compression
      function over 32-bit words held in `Int64` (masked, so every
      shift is exact), the message schedule through a 16-word rolling
      window, the padding; streaming (write/sum/reset/size) and
      one-shot in `crypto.sha2` over `internal/sha256.emo`'s engine —
      one class, its mutable state riding one `Bytes` (fields are
      assigned only inside init, so the box carries the working
      words, the pending block, and the two counts, mutated through
      the word layer's stores); the golden `examples/crypto_hash`
      takes the RFC 6234 suite — "abc", the 56-byte dual-block
      boundary, the 112-byte two-block vector, the padding edges at
      55/56/57/63/64/65/119/120/127/128, the 0x00–0xFF byte sweep —
      every digest generated by Go's `crypto/sha256` on this machine
      and frozen into `expected.txt` after agreement, plus the
      streaming-equivalence panel (chunk sizes 1 through 65), the
      sum-leaves-the-state-standing and reset panels, and the hex
      codec's edges; `examples/crypto_hash_million` rides RFC 6234's
      million-`a` vector through the streaming path — nineteen
      seconds on the interpreter, a quarter second compiled, so it is
      a c-only golden; `crypto.hex_encode`/`hex_decode` joined the
      root as the digests' rendering (strict, offset-bearing).
      Byte-identical interpreter to `c`; `dune test` green.
- [x] **T55.3** — The SHA-512 family and the legacy pair:
      SHA-512/384/512-224/512-256 in `internal/sha512.emo` — 128-byte
      blocks, 80 rounds, 64-bit lanes that wrap natively (no masking;
      only T55.1's logical shift and rotations), the constants derived
      from the spec's definitions and checked against the reference
      digests rather than hand-copied (the /224 and /256 initial
      words through §5.3.6's generation function — derivation, not
      memory, which had three of those eight words wrong); the public
      surface rides `crypto.sha2`'s `Wide` class, the digest length
      picking the variant (64/48/28/32), factories `new512`/`new384`/
      `new512_224`/`new512_256` and one-shots beside the 32-bit
      family's; SHA-1 and MD5 in `internal/sha1.emo`/`internal/
      md5.emo` behind `crypto.legacy` — one-shot only, documented as
      broken for every security purpose, MD5 little-endian through
      and through; the golden grows to 98 Go-agreed vectors (the
      64-bit family over the five messages, the 111/112/113/127/128/
      129 padding edges, the sweep; the legacy pair over the same
      five and the sweep) plus the 64-bit streaming/reset panels; and
      the step flushed a real backend bug: crypto carries the first
      Int64 constants past 2^63, and the OCaml emitter's
      unparenthesized negative literal (`Emo_eval.Int64 -…L`) parsed
      as subtraction — every `%LdL` emission site now goes through a
      parenthesizing helper (`emo_codegen.ml`), ocaml target
      byte-identical like interpreter and `c`; `dune test` green.
- [x] **T55.4** — The `Hash` interface and HMAC (RFC 2104): the
      structural interface (`write`/`sum`/`reset`/`size`/
      `block_size`) in `crypto.hash`, `Digest` and `Wide` satisfying
      it by shape — the golden holds both through one function taking
      the interface; HMAC over the SHA-2 family in `internal/
      hmac.emo` — the RFC's key preparation (hashed first when longer
      than the block, zero-padded when shorter, the 0x36/0x5c pads),
      the variant riding a code the wrapper names so the engine rides
      sha2's one-shots and the dependency stays one-way (module
      cycles are refused, and the interface-factory shape a streaming
      HMAC would want does not exist yet, so HMAC is one-shot —
      provisional); tags compared through
      `crypto.constant_time_compare` per the docs, never `==`; the
      golden grows to 134
      Go-agreed vectors — RFC 4231's tc1–tc4, tc6 and tc7 (the
      131-byte keys forcing the hash-the-key path) across all six
      algorithms; interpreter, `c`, and ocaml byte-identical;
      `dune test` green.
- [x] **T55.5** — HKDF (RFC 5869) and PBKDF2 (RFC 8018) in
      `crypto.kdf` over `internal/kdf.emo`: the combined HKDF and
      its expand step for all six SHA-2 variants, extract documented
      as the HMAC call it is (not re-exported) with the absent salt
      as hash-length zero bytes; the output-length cap (255 hash
      lengths), a negative length, and an iteration count below one
      raise — the construction's own rules — while the count itself
      is a plain `Int64` argument, no work-factor policy in the
      package; the engine rides internal.hmac's one-shots, the
      dependency one-way; the golden grows to 145 Go-agreed lines —
      RFC 5869's tc1–tc3 across the family (tc2's 80-byte inputs
      included), the expansion fed the RFC's own PRK through the hex
      decoder, RFC 7914's PBKDF2 vectors plus the wide family — and
      `examples/crypto_kdf` (c-only, like the million-`a`) pins the
      classic 4096 iterations, the shape every off-by-one turns
      wrong first: a minute interpreted, two seconds compiled;
      interpreter, `c`, and ocaml byte-identical; `dune test` green.
- [x] **T55.6** — SHA-3 and SHAKE (FIPS 202) in `crypto.sha3` over
      `internal/keccak.emo`: Keccak-f[1600] after the Keccak team's
      compact reference — rho-pi walked in place carrying the rotated
      lane (no offset table) and the round constants from the 0x71
      LFSR one bit at a time (no constant table) — derived, not
      hand-copied, and proven against the reference digests; the four
      fixed-output hashes and SHAKE128/256 with the length the caller
      names, one-shot for now (provisional — the streaming shape
      waits for a consumer); the golden grows to 175 Go-agreed lines
      (the four hashes over the five messages and the sweep, SHAKE at
      32 and at 137 — across the rate, so the squeeze refills); and
      the step flushed two language walls: `Bytes.new` answers the
      gradual type, so a static receiver's strict `set` refuses
      gradual arguments — the byte accesses go through six
      parameterized door helpers, base64's `fill_encode` shape — and
      E3005 refuses shift counts the checker cannot prove
      non-negative, so the word layer's rotators carry `n <= 0`
      narrowing guards (rho's rotation amount is dynamic);
      interpreter, `c`, and ocaml byte-identical; `dune test` green.
- [x] **T55.7** — The `rand` package: the entropy source bound per
      hosted target through one runtime implementation, `rand_bytes`
      — the `rand_` prefix joins the IR's runtime-impl table, the
      checker's signature table, the interpreter and the standalone
      OCaml runtime (`/dev/urandom`, read to the count), the C runtime
      (`getentropy`, 256 bytes a call), the Node host
      (`crypto.randomBytes`), and the beam emitter
      (`crypto:strong_rand_bytes`, parked under a ref the way
      `emo_bytes_new` parks its own); the wasm host supplies no entropy
      and the target list refuses it, a declared refusal. The surface
      is `rand.bytes(n)` answering `(R, Bytes)` — the `plot.png`
      precedent: bytes are what entropy is, and a String cannot carry
      them on typescript — a negative count raising, a refused source
      the `(R.error, "rand: …")` value. The deterministic stream is
      `rand.drbg_sha256(seed, length)` — SP 800-90A's HMAC-DRBG,
      SHA-256, the one-shot shape — answering `Bytes` byte-identically
      on every target, which needed crypto's first byte doors:
      `sha2.sha256_bytes`, `hash.hmac_sha256_bytes`, and
      `write_bytes`/`sum_bytes` on `Digest` and `Wide` (the engines'
      `finish` now answers `Bytes`, the String door its `to_string`).
      The golden `examples/rand_demo` pins the stream (verified against
      the formula in Python) and smoke-tests the source for length and
      a differing second draw — on the interpreter, `c`, ocaml,
      typescript, and beam, all five lists. **Found, not fixed, in
      `CHECK.md`:** the crypto String surface is unsound on
      typescript (U+FFFD where a digest byte passes 0x80; the
      131-byte-key HMAC crashes) — the Bytes doors are the fix's
      proven shape, the surface migration a pending decision.
- [x] **T55.8** — The surface in Bytes: every door of `crypto`
      takes and answers `Bytes` — the SHA-2 one-shots and the
      `Digest`/`Wide` classes (`write`/`sum`), the `Hash` interface,
      HMAC, HKDF and PBKDF2 (an absent salt now an empty `Bytes`),
      SHA-3 and SHAKE, the legacy pair, `constant_time_compare`, and
      `rand.drbg_sha256`'s seed — with text staying text: `hex_encode`
      answers String and `hex_decode` reads it, and a caller hashing
      text hands over `text.to_bytes()`. The decision (2026-11-01)
      revises T55.2's String-at-the-surface rule for the reason
      `plot.png` settled in step 45: a String cannot carry raw bytes
      on typescript. The internal engines were already Bytes; the
      String plumbing (the HMAC and KDF String engines, the
      `_bytes` twins) is gone, not doubled. Every golden's
      `expected.txt` is byte-identical before and after — the
      algorithms did not move — and `crypto_hash` joins the
      typescript golden list, passing where it printed U+FFFD and
      crashed the day before; `CHECK.md`'s entry carries the
      resolution.
- [x] **T55.9** — ChaCha20-Poly1305 (RFC 8439) in `crypto.cipher`:
      the block function and keystream XOR (`chacha20(key, nonce,
      counter, data)`), the one-shot Poly1305 (`poly1305(key,
      message)` — five 26-bit limbs, Donna's 32-bit radix, every
      product under 2^56), and the AEAD pair —
      `chacha20_poly1305_seal` answering ciphertext then tag,
      `chacha20_poly1305_open` answering `(R.ok, plaintext)` or
      `(R.error, "crypto: authentication failed")`, the same answer
      for a flipped byte, a wrong AAD, and a truncated box; wrong
      key/nonce/counter raise. The golden `examples/crypto_aead` pins
      the keystream block, the §2.4.2 stream, the §2.5.2 tag, the
      §2.8.2 box and its open, the three forgeries, and the
      block/pad16 boundary sizes — against the RFC's own vectors and
      a Python reference written from the RFC and self-checked
      against it first (Go keeps the construction behind
      x/crypto) — and rides all five lists byte-identically. The step
      flushed the typescript `get_u32_le` signed-read bug
      (`CHECK.md`, fixed) and two block-boundary flaws in the new
      code itself.
- [x] **T55.10** — AES and GCM in `crypto.cipher`: the block cipher
      landed S-box byte-oriented rather than T-tables — one derived
      table instead of five, the same SubBytes lookup caveat
      documented in the same breath (branchless xtime and the field
      multiply; the AES-NI C shim stays the later optional hardening
      for `c`) — with the key expansion for 128/192/256, the cipher
      and its inverse, CTR (full 128-bit big-endian counter, the
      caller's IV copied), CBC with PKCS#7 (a bad padding the value
      `(R.error, "crypto: invalid padding")`, the padded-oracle caveat
      stated), and GCM — GHASH pure bitwise (branchless, no tables,
      no such caveat), the 12-byte nonce, the 16-byte tag, nonce
      reuse the caller's irrecoverable contract violation. The S-box
      and its inverse were derived from the GF(2^8) inversion and the
      affine map, proven through a Python AES against all three
      FIPS 197 Appendix C known answers before landing. The golden
      `examples/crypto_aead` grows the AES panel — the three KATs and
      their decrypts, GCM's NIST cases 1 and 2, nine GCM sizes across
      the block and pad16 boundaries, CBC and CTR at six lengths each
      and a counter carry past the low byte — all fifty Go lines
      agreeing byte for byte; five lists byte-identically. Found on
      the way and fixed: `aes_ctr` mutated the caller's IV — the
      counter block is copied now.
- [x] **T55.11** — Ed25519 and X25519 (RFC 8032, RFC 7748): the
      probe first — `Int128` is E4005, `2^32 · 2^32` answers 0
      (multiplication wraps modulo 2^64; there is no 128-bit
      product), `(2^51 − 1)²` wraps — so the five-limb radix 2^51 is
      out and the field rides ten signed `Int64` limbs in the
      alternating radix 2^26/2^25, ref10's 32-bit shape, in
      `internal/fe25519.emo`: every limb product under 2^53, the
      wrapped terms times 19 and the odd-by-odd terms times 2, the
      ten-term sums under 2^63; the multiplier's sums generated from
      that rule and the whole limb layer mirrored in Python and
      fuzzed against big-integer arithmetic over three thousand pairs
      before transliteration (the generator's first draft dropped the
      odd-by-odd factor 2 — limbs 0 and 1 came out right and the even
      limbs from 2 up wrong, and the limb-level diff found it in one
      round); the rounding carry pass, `from_bytes` ignoring bit 255,
      `to_bytes` through the quotient estimate, the inversion and
      (p − 5)/8 chains, masked `cmov`/`cswap`; the hot path reads and
      writes the limb box directly with the carry inline — the smoke
      panel went from 2.8 to 1.4 seconds interpreted, byte-identical.
      `internal/ed25519.emo`: the point a class of four field boxes in
      extended coordinates, §5.1.4's add and double (2d and Z·2Z as
      single products so every multiplier input stays within the
      bound), scalar multiplication double-and-add-always with a
      masked select over 256 bits, decoding through
      u·v³·(u·v⁷)^((p−5)/8) with the sqrt(−1) correction and the
      x = 0-with-sign-bit refusal (a non-canonical y accepted, the way
      Go reads it), the scalars modulo L over sixteen 32-bit words —
      the schoolbook product with each word product exact as a 64-bit
      pattern and split through the logical shift, the reduction 260
      masked trial subtractions — and the scheme: the public key, the
      signature, and verification as [S]B − [k]A re-encoded against R
      (the equation without the cofactor, Go's shape), an S at or
      above L refused. `internal/x25519.emo`: the Montgomery ladder,
      255 steps with masked swaps, the clamping, the top bit ignored
      by the field's own `from_bytes`. The constants derived, not
      hand-copied: d, 2d, and sqrt(−1) as limbs, the base point as
      its encoding, L as its words. The surface: `crypto.sign` —
      `ed25519_public(seed)`, `ed25519_sign(seed, message)`,
      `ed25519_verify(public, message, signature)` answering `Bool`,
      the same false for a wrong message, a flipped byte, a signature
      that is not 64 bytes, an S at or above L, and a public key that
      does not decode, a seed or public key that is not 32 bytes
      raising — and `crypto.ecdh` — `x25519(scalar, point)` answering
      `(R, Bytes)`, the all-zero shared secret the value
      `(R.error, "crypto: x25519 low-order point")`, and
      `x25519_public(scalar)`. The goldens: `examples/crypto_sign`
      takes the five §7.1 vectors (public key, signature,
      verification) and the rejections (a flipped byte, a wrong
      message, S + L, a 63-byte signature, x = 0 with the sign bit, a
      y with no root) — 21 lines agreeing with Go's `crypto/ed25519`,
      five seconds interpreted; `examples/crypto_ecdh` takes §5.2,
      §6.1 both ways, the first iteration, u = 0 and u = 1 refused
      with the reason pinned, and a sweep — agreeing with Go's
      `crypto/ecdh`; both ride all five lists byte-identically;
      `examples/crypto_sign_sweep` (thirteen message lengths — eleven
      seconds interpreted, a tenth of a second compiled) and
      `examples/crypto_ecdh_iterated` (RFC 7748's thousand
      iterations — eighty seconds interpreted, 0.6 s compiled) are
      c-only. The step flushed a typescript emitter
      gap: a local named `public`, emitted verbatim, is a reserved
      word in strict-mode JavaScript — `ts_local` now guards the
      JS/TS reserved words with a `$` suffix no Emo identifier can
      carry, the C emitter's `c_ident` shape (`CHECK.md`, fixed).
- [x] **T55.12** — The docs: `docs/stdlib/crypto.md` and
      `docs/stdlib/rand.md` (EN + zh-CN) — the full surface of the
      root and the eight submodules with every signature, the
      raise/error split spelled per function (and tabulated for
      `rand`), the Bytes-carrier rule, the two caller's contracts the
      constructions cannot enforce (nonce reuse, the CBC padding
      oracle), the constant-time section stating the source-level
      discipline, its two documented exceptions (AES's S-box lookup,
      the comparisons on public data), and per target what `Int64`
      is and what the discipline becomes — a guarantee on none of
      them, no target measured for leakage — and the legacy warning
      with the refused algorithms named; `docs/stdlib.md`'s rows and
      sections for `crypto` and `rand`, EN and zh-CN; the README's
      reference list. The golden lists completed as the targets had
      landed them: `crypto_hash` onto the beam list and the four
      crypto goldens onto the wasm list — all byte-identical, so every
      one of the package's five declared targets is now
      golden-exercised. Two small corrections on the way: SHAKE's
      negative length raises with the package's own message (it had
      surfaced as `Bytes.new`'s E3004 from inside the engine), and the
      c-only goldens' interpreter costs are now measured, not
      estimated — the sign sweep is eleven seconds, the thousand
      X25519 iterations eighty. `plan/README.md`'s row reads done;
      M21 complete.

## M22 — File IO on `wasm`

The wasm target's host boundary grows the file-system syscalls, the
canonical host rides the compiler, and the last IO packages still
missing a hosted target land on it. `plan/step-56-wasm-file-io.md`
holds the decisions; the exit criteria: `file`, `os` (fd/directory
half), and `bufio` resolve and answer byte-for-byte on `wasm`, the
process half refuses at the call naming the capability, `emo run
--target wasm` runs an artifact under Node with the bundled host, and
every existing golden on every target stays byte-identical
(`CHECK.md`).

### Step 56 — File IO on the wasm target (and the canonical host) · `plan/step-56-wasm-file-io.md`

**Prereq:** Steps 16, 20–22, 31–38, 50. **Done when:** `emo run
--target wasm` runs `examples/os_fs_demo`, `file_read`, and
`bufio_demo` byte-for-byte; the fork refusal names `os_fork`; `emo
build --target wasm` still emits exactly `.wasm` + `.wat`; `dune
runtest` green.

- [x] **T56.1** — The protocol and the `file` pair. The import table
      grows `file_read`, `file_write`, and `fetch` — a syscall stashes
      its answer (contents, or the reason the host formatted whole
      against a Node error-code → strerror table byte-identical with
      the c runtime's) and the guest copies it out with `fetch` into a
      buffer a new `alloc` runtime bump-allocated; the `rt` index map
      went import-relative so a new import shifts every defined
      function mechanically; `Runtime_impl` lowers the two names
      through `string_args`/`fetch_string`/`r_pair`; the canonical
      host rides the compiler as generated data
      (`src/emo_codegen/wasm/wasm_host.mjs`) and the golden tests'
      inline runner is deleted for it; the bump base moves to 65536
      (page 0 stays the host's, memory opens at 2 pages). Two wasm
      runtime bugs found and fixed on the way — the bump cursor never
      moved (the copy loop's exit branch jumped past the advance,
      dead code since the backend landed, invisible while every
      consumer read its buffer before the next allocation) and the
      grow delta paged the length alone (negative past a page
      boundary → `memory.grow` failed, its `-1` dropped, the copy
      stored out of bounds — `plot_demo`'s second SVG caught it).
      Golden: the scratch probe pins ok and error bytes.
- [x] **T56.2** — The os fd/directory half. Eleven more imports
      (`os_open` behind a mode parameter, `os_read`, `os_write`,
      `os_close`, `os_list_dir`, `os_mkdir`, `os_rmdir`, `os_unlink`,
      `os_rename`, `os_getcwd`, `os_chdir`); `list_dir` rides a
      NUL-separated name stream the guest splits with the existing
      `str_split`, byte-order sorted host-side like the c runtime's
      `qsort`; the process half (`getpid`, `getppid`, `fork`,
      `waitpid`, `pipe`, `execv`, `_exit`) lowers to a run-time raise
      naming the capability — the interpreter's run-time refusals are
      the precedent, and a compile-time refusal would have killed the
      whole package (its own bodies call the process names). Golden:
      the scratch probe pins the fork refusal's message.
- [x] **T56.3** — `emo run --target wasm`: the riscv64 arm's shape —
      build into `.emo-build`, probe `node` (exit 69 without it),
      write the bundled host beside the artifact, run from the
      caller's working directory so relative paths resolve as the
      interpreter resolves them; `emo doctor`'s wasm line names the
      run path; the `--target` help and the unknown-target refusal
      name both run targets.
- [x] **T56.4** — Manifests, examples, goldens: `file`, `os`, and
      `bufio` declare `wasm`; `file_read`, `bufio_demo`, and the new
      `examples/os_fs_demo` (fd write/read, directory create/list/
      unlink/remove, both refusal shapes — byte-identical with the
      interpreter and c) join the wasm golden list, `os_fs_demo`
      joins the c list and the interpreter exclusion list; every
      lockfile pinning a changed manifest regenerated; and the test
      fixtures' root directory is created at definition instead of
      assumed — a wiped temp directory had taken every
      scratch-writing test with it. `os_demo` (it forks) stays a c
      golden; `bufio_demo`'s temp file loses its `getpid` suffix for
      the same reason.
- [x] **T56.5** — The exchange-area audit (the bump/scratch collision
      the step set out to check was real but secondary — folded into
      T56.1's finds: the base moved to 65536, and the cursor had
      never moved at all until the loop fix).
- [x] **T56.6** — The docs: `docs/demo-targets.md`'s wasm section
      (the 17-import table, the fetch protocol, `emo run --target
      wasm`, the capability story) + zh mirror; `docs/stdlib/{file,os,
      bufio}.md` and the `docs/stdlib.md` index + zh mirrors; this
      step's plan file; `plan/README.md`'s row; the `CHECK.md` trail.
      `plan/README.md`'s row reads done; M22 complete.
- [x] **T56.7** — The entropy source: `rand_bytes` joins the wasm
      import table — `(i64 n) -> (tag, size)`, the payload riding
      `fetch` (the entropy on the ok branch, the reason on the error
      one), the host answering from Node's CSPRNG, the typescript
      target's own source; `rand` declares `wasm` — the T55.7
      refusal's premise ("the wasm host supplies no entropy") died
      with the canonical host — and `rand_demo` joins the wasm golden
      list byte-identical (its entropy lines are host-independent:
      lengths, draw-divergence, zero). The docs flip the refusal
      paragraphs (EN + zh: `rand.md`, the `stdlib.md` row, the
      `demo-targets.md` import table and capability bullet).
- [x] **T56.8** — The performance baseline: `benchmarks/run.sh` grows
      the wasm rows through `benchmarks/wasm_driver.mjs` (which
      reuses the canonical host's exported import factory; module
      execution only, node startup excluded). The numbers: fib(30) at
      c parity (38 ms vs 39), the straight-line loops at ~5–6× c,
      the Bytes scan ~4× c — and the step-16 Int-unboxing follow-up
      **declined on the evidence, the trigger named** (a real
      workload whose profile shows box churn dominating; the plan
      file holds the argument). The `http_echo` bench, still calling
      the pre-M10 `net.listen` shape, repaired on the way.
- [x] **T56.9** — The second engine: `devtools/wasmtime-smoke.sh`
      compile-validates every wasm golden on wasmtime's cranelift —
      49/49, zero deltas; Node stays the execution host (the wasmtime
      CLI cannot supply a non-WASI module's custom imports; the
      Rust-driver port of the canonical host is the named follow-up).

## M23 — The httpd server

The server half of HTTP moves out of `http` into a dedicated `httpd`
package and grows to a real HTTP/1.1 server: one process per
connection over `net`, a request arriving as a value and the handler
answering with one, the connection machinery — keep-alive, bodies,
limits, timeouts, graceful shutdown — and the routing living in the
package instead of every program's accept loop. Go's `net/http`
server is the mechanism survey; the surface stays Emo's own.
`plan/step-57-httpd.md` holds the decisions; the exit criteria: the
`httpd_parse`, roundtrip, wire-shape, routing, and shutdown goldens
run byte-for-byte on the three hosted targets `net` declares, `http`
is client-only again with its callers migrated, no runtime primitive
changes, and every existing golden on every target stays
byte-identical (`CHECK.md`).

### Step 57 — The httpd package · `plan/step-57-httpd.md`

**Prereq:** Steps 13, 26–27, 28–30. **Done when:** the parser,
routing, wire-shape, roundtrip, and shutdown goldens answer
byte-identically on `ocaml`, `c`, and `typescript`; the bench and
`http_roundtrip`/`https_roundtrip`/`ssr_page` run on `httpd`; `http`
carries no server half; `dune runtest` green.

- [x] **T57.1** — The package skeleton and the pure parser: `Request`
      and `Response` as values, `response`/`error` constructors,
      `parse_head` — request line (three parts, token method,
      HTTP/1.x only), header lines (token names canonicalized, strict
      colon placement), origin-form target split into raw path +
      query map (first occurrence wins, pairs without `=` refused,
      the Host rule for HTTP/1.1), percent-decoding under the
      printable-ASCII discipline. The `httpd_parse` example walks
      fixture heads — parsed fields and refusals — byte-identical on
      the three hosted targets.
- [x] **T57.2** — The connection half: the head block read under the
      431 limit, bodies by Content-Length or chunked under the 413
      limit, `100 Continue` before a body the peer waited on,
      response writing with `Content-Length` always (the handler's
      own standing) and HEAD/204/304 stripping, the keep-alive
      negotiation (HTTP/1.1 closes on `Connection: close`, HTTP/1.0
      stays on `keep-alive`), the loop one process per connection,
      per-request timeouts (`with_read_timeout`/`with_idle_timeout`),
      `serve`/`serve_with` answering the `Server` handle — `stop()`
      graceful, `wait()` joining a drain counter process in the
      sync.WaitGroup shape — and `server_options()` with the with_*
      builders plus `with_date` (the injected clock; the language has
      none). Three compiler bugs found on the way, each with the
      probe that nailed it: the IR routed a call naming a top-level
      const holding a callable to the zero-param thunk and dropped
      the arguments whole (the middlewares died on both compiled
      targets; zero-param symbol + arguments now lowers as the value
      call); the c target built `-O2` under strict aliasing and the
      value world's word views made a garbage pointer reach
      `emo_cell_kind` — deterministic crash, layout-sensitive
      (`-O0` and `-fno-strict-aliasing` agree byte-for-byte), so the
      c target now builds `-fno-strict-aliasing` and the underlying
      pun is the named follow-up; and two ts gaps — `listenerClose`
      left a parked accept pending (Node ends the program with it),
      now rejecting the waiters like the error event does, and a
      receive's value return threw `EReturn` past `E.receive` to the
      process wrapper (a receive returning a value inside a method
      or callee def ended the program silently), now answered at the
      receive; with the emitter honoring the receive in tail
      position (`await` was dropping the def's value). The goldens:
      `httpd_serve` (middleware, roundtrip, drain) and `httpd_wire`
      (fourteen wire shapes on raw connections) answer byte-
      identical on the three hosted targets by hand, the interpreter
      legs running through the committed lockfiles in
      test/emo_project. The serve examples and `https_roundtrip` rode the c_goldens list
      after the follow-up flake was root-caused and fixed the next
      day (CHECK.md): a SIGSEGV misread as a clean exit (the first
      diagnostic never printed the child's status), caught by ASan as
      a stale release in the mutual-tail-call cluster — a sibling
      rebind jumped past the target member's local zero-init — and
      fixed by moving the hoisted-locals block after the rebind
      label; ASan 5/5 clean, the harness case 3/3 red to 3/3 green,
      and the word-view pun behind the `-fno-strict-aliasing`
      insurance eliminated alongside it (the cell is one declared
      type over the whole allocation).
- [x] **T57.3** — The Router: patterns parse once at registration —
      `handle("GET /users/{id}", h)` and the method-scoped
      `get`/`post`/`put`/`delete` taking the bare path (a pattern
      naming a method there is the raise naming both forms), literal
      and `{name}` and `{name...}` segments validated on the spot
      (the raise family: braces without closes, empty names, a rest
      that is not last, `//` and `.`/`..` — the wire's cleanup is the
      peer's business, a pattern is exact) — and same-shape
      registrations with overlapping methods raise at the second
      one. The dispatch cleans the path first (`//`, `.`/`..` with a
      climb past the root staying at the root, the trailing slash and
      the query surviving) and answers the change with 301; matching
      walks the tokens — literal outranks wildcard outranks rest,
      the longer pattern past a shared prefix wins, an exact
      pattern's trailing slash is part of the address, a subtree
      takes the slash or more segments, a rest captures everything
      left including nothing — a GET pattern answers HEAD, and the
      captures decode under the path's own `+`-is-a-plus convention
      (the query's `percent_decode` and the path's
      `percent_decode_raw` split) before `with_params` hands them to
      the handler. No match with a shape matching otherwise answers
      405 with the deduped `Allow`; the trailed spelling of a
      registered subtree answers 301 (`/static` → `/static/`);
      nothing at all answers Go's own `404 page not found\n`.
      `serve_routes`/`serve_routes_with` put the Router in the
      handler's seat of the same `Server`. The `httpd_routes`
      example walks seventeen probes — decoded and `+`-preserved
      params, empty rest, literal-over-wildcard, 405+Allow, four
      cleanup shapes with the query riding, the slash redirect, the
      subtree, the 404 — byte-identical on the three hosted targets
      by hand and through the committed lockfile in test/emo_project
      (the interpreter leg; the c/ts legs verified by hand, the
      serve examples' c_goldens deferral covering this one too).
- [x] **T57.4** — The migration and the docs: `http` returns to
      client-only (`serve`, `serve_requests`, `handle_connection`,
      `read_request`, `write_response`, and `reason_phrase` deleted;
      the header comment pointing the server half at httpd), the
      callers migrated — `benchmarks/http_echo` (deps `httpd` +
      `net`, smoke-tested through a real curl), `examples/
      http_roundtrip` and `examples/https_roundtrip` (deps gaining
      `httpd`, `httpd.serve` with the trailing block where
      `http.serve_requests` stood, outputs unchanged), `ssr_page`
      needing nothing (it names no server) — the locks regenerated
      for every package whose source moved; `docs/stdlib/httpd.md`
      and its zh-CN mirror (serving, the request and the response,
      routing, options, strictness on the wire, the honest
      limitations), `docs/stdlib/http.md` slimmed to the client
      both languages, the `docs/stdlib.md` rows split and the
      `httpd` summary section added both languages, the networking
      intro's HTTP bullet split into client and server both
      languages; the plan file's boxes ticked and `plan/README.md`'s
      row added; the migrated `https_roundtrip` c binary turned 3/3
      red under the harness while standing 3/3 green standalone —
      the named flake family again — so its c golden joins the
      deferral and its interpreter leg carries the coverage; M23
      complete.
## M24 — Macros

The metaprogramming mechanism lands as one thing: compile-time macros
behind the reserved directive namespace — `// #macro` declares, `//
@name` applies — with the body checked before it ever runs and
deterministic by construction (every effect and host-touching builtin
refusing), applications expanding between parse and check so every
target inherits by construction, the macro defs erased after expansion,
and the spliced code checked with the module. Runtime `eval`, open
classes, and `method_missing` are rejected permanently as a language
mechanism (`CHECK.md` holds the decision and the rejected
alternatives); `design/macros.md` is the working design.

### Step 58 — Compile-time macros · `design/macros.md`

**Prereq:** Steps 9 (the checker), 21 (the eval's builtins). **Done
when:** `examples/trace_demo` runs byte-for-byte on every target;
`// #macro` / `// @trace` parse, expand, and check; the strictness
battery (E2029–E2035, E3030, E4300–E4310) refuses every wrong spelling
loudly; `dune runtest` green.

- [x] **T58.1** — The directive layer: a `//` comment whose first token
      is `#` or `@` is not a comment — the lexer captures the sigil,
      name, and raw argument text as a directive token; the parser
      collects, validates placement (own line, consecutive stacking,
      directly above the declaration, nothing inside a body or trailing
      the file), and attaches the directives to the item; the LSP
      highlights the lines as macros. Unknown role names, blank-line
      floats, in-body directives, duplicates, same-line tails, and
      application arguments each refuse with their own code
      (E2029/E2030/E2031/E2032/E2033/E2035).
- [x] **T58.2** — The macro model: `Syntax` is a reserved compile-time
      type, legal only inside a `// #macro` def's signature and body
      (the checker's compile-time window opens for a macro's own
      collection, signature resolution, and body); the shape is exactly
      `(f Syntax) Syntax` (E4302); a macro body typechecks like any def
      before it ever runs; after expansion the macro defs are erased.
      `@name` resolves to a same-module macro or refuses by name
      (E4300), a macro takes no applications (E4310), and the splice
      must produce declarations (E4303).
- [x] **T58.3** — The compile-time profile: the macro body runs on the
      compiler's own interpreter with every effect refused, every
      host-touching builtin refused (`rand_bytes` through both the
      builtin and the runtime-impl paths), the output hook poisoned,
      and a step budget — determinism by construction, no effect
      system needed (E3030).
- [x] **T58.4** — The expansion pass rides the parse cache: every
      consumer — check, the backends, the evaluator — sees the expanded
      declarations; the precheck is the original module's full check,
      so files without directives take the fast path untouched and a
      macro-using module is checked before and after the splice; the
      bare interpreter (`Emo_eval.run_program`) expands with a
      lone-file precheck. Applications apply nearest-first, feeding
      each macro the previous application's result.
- [x] **T58.5** — The `Syntax` API: readers (`name`, `params`,
      `param_name`, `result`) and constructors (`rename`, `new_def`,
      `seq`, `ident`, `lit_string`, `interp`, `call`, `call_stmt`,
      `expr_stmt`, `const_stmt`, `return_stmt`, `gensym`) as builtin
      members of the `Syntax` group, bound only inside a running macro
      body; `Syntax.gensym` hands out collision-free names.
- [x] **T58.6** — The pilot: `examples/trace_demo` — a `trace` macro
      that moves the original def to a hidden name and makes the
      visible name a wrapper logging every call's arguments and answer;
      the forwarding call is built from the wrapped declaration's own
      parameter trees, so it cannot drift; the generated wrapper is
      checked with the module, which is where a wrong-arity wrapper
      dies. Design decisions and the rejected alternatives (runtime
      eval, the `by` keyword, value decorators as a separate mechanism)
      live in `design/macros.md`.

### Step 59 — Macro applications with arguments, and the quote surface · `design/macros.md`

**Prereq:** Step 58 (the directive layer, the expansion pipeline, the
compile-time profile). **Done when:** `examples/memoize_demo` runs
byte-for-byte on the interpreter and the c and TypeScript binaries;
`// @memoize(2)` checks its argument against the macro's declared
parameter and evaluates it at expansion; `quote { ... }` lays a wrapper
body out as ordinary code with `${...}` holes; the refusal paths
(E2033–E2036, E4306–E4309) refuse loudly; `dune runtest` green.

- [x] **T59.1** — Application arguments: the directive's argument list
      lexes as ordinary tokens after the name (the raw-text capture
      retired), so the args carry the file's real spans; the parentheses
      must touch the name (E2034) and close on the directive's own line
      (E2033); role directives take none (E2035); a macro's signature
      generalizes to leading scalar compile-time parameters plus the
      trailing `Syntax` tree parameter (E4302); arity (E4306) and
      per-argument type conformance (E4307) check statically in the
      builtins-only environment the expansion evaluates them in, and the
      values bind to the leading parameters inside the protected profile.
- [x] **T59.2** — The quote surface: `quote { ... }` is a contextual
      spelling in expression position — operand-start seats (`=`, `(`,
      `,`, `[`, `return`, `do`, `->`) with a same-line brace; every other
      `quote` stays an ordinary name. The rule was corpus-driven twice:
      the stdlib's JSON escaper is called as `quote(self.value)` (a
      keyword broke it) and sql's `== quote {` ends an if condition
      (brace-follow alone broke it); `foreign` is the precedent —
      parseable only inside a macro body (E4301
      elsewhere); the body parses as ordinary items over the quote's own
      token stream — real spans, no error recovery inside — with each
      `${expr}` hole parsed in place and a compiler-owned placeholder
      identifier (spelling reserved, E2036) standing in the stream; the
      placeholder spans the whole hole so the adjacency rules read it as
      one token; the evaluator substitutes each hole's tree for its
      placeholder, and a hole producing a non-expression tree is E4309.
- [x] **T59.3** — Generated runtime state: `Syntax.const_item` +
      `Syntax.empty_map` splice a module-level `Map` constant beside the
      wrapper; `Syntax.new_def` takes a whole quote as its body;
      `Syntax.seq` flattens, so nested sequences concatenate; `lit_int` /
      `lit_bool` / `lit_float` lift compile-time values into literal
      trees; a `raise` inside a macro body surfaces as the expansion's
      compile error E4308 carrying the Exception's message.
- [x] **T59.4** — The pilot: `examples/memoize_demo` — `@memoize(2)`
      wraps a def that prints on every actual evaluation; the output
      shows a cache hit skipping the computation, the table reaching the
      limit and dropping, and the evicted arguments computing again —
      byte-identical across the interpreter, the c binary, and the
      TypeScript output.

### Step 60 — `@derive` on classes · `design/macros.md`

**Prereq:** Step 59 (application arguments, the quote surface). **Done
when:** `examples/derive_eq_demo` runs byte-for-byte on the interpreter
and the c and TypeScript binaries; `// @derive_eq` above a `class`
generates the equality method from the field list; the raw module no
longer gates the expansion (the macro-domain check replaces the
whole-module precheck); the refusal paths stay loud; `dune runtest`
green.

- [x] **T60.1** — The class seat: the parser accepts applications above
      `class` items (roles stay def-only, E2031 names the rule; the
      duplicate rules E2032 apply to classes; other items still refuse),
      and the expansion passes the class tree through unchanged
      machinery — `Sx_item (Item_class _)` in, the macro's transformed
      class out.
- [x] **T60.2** — The class API: `Syntax.fields` /
      `Syntax.field_name` read the field list (names; the AST carries no
      field types — recorded as the named gap for a JSON derivation),
      `Syntax.with_methods` appends generated defs as ordinary methods,
      `Syntax.name` answers a class or def tree; the body constructors —
      `new_param`, `named_type`, `self_expr`, `bin_eq`, `bin_and`,
      `member` — plus the `Sx_field` tree variant.
- [x] **T60.3** — The precheck narrowed to the macro domain: the
      whole-raw-module gate of step 58 could not survive derive, because
      a call site naming a generated method fails against the raw class
      before the macro ever runs (found live: the first derive smoke
      died exactly there, at the runtime NoMethodError the raw-module
      precheck had been masking). `Emo_check.check_macro_domain` checks
      the `#macro` defs' shape and bodies plus every application's
      compile-time arguments — application carriers ride as hollow
      shells (bodies emptied, return dropped to Void so a hollow shell
      cannot trip the must-return rule) — and the expanded module's full
      check is where a call site naming a method the derivation does not
      produce dies. One constraint lands with it: a macro body is
      self-contained (its parameters, `Syntax`, the builtins).
- [x] **T60.4** — The pilot: `examples/derive_eq_demo` — `@derive_eq`
      generates an `eq?` method comparing every field pairwise (`self`
      against `other`, chained with `&&`, a fieldless class deriving the
      constant `true`), on two classes (an Int64 pair and a String);
      byte-identical across the interpreter, the c binary, and the
      TypeScript output.

### Step 61 — Cross-module macros · `design/macros.md`

**Prereq:** Step 60 (the class seat, the macro-domain gate). **Done
when:** `examples/derive_shared` runs byte-for-byte on the interpreter
and the c and TypeScript binaries — `derive_eq` declared once in the
sibling `eq_macros.emo`, applied qualified (`// @eq_macros.derive_eq`)
to two classes in `main.emo`; bare applications still resolve locally
and shadow; cross-module arity/type checks refuse loudly; `dune
runtest` green.

- [x] **T61.1** — The program's macro table: one raw scan over every
      registered file (no expansion — the scan cannot recurse through
      the parse cache), collecting each `// #macro` def under its
      (module path, macro name), memoized on the project record.
- [x] **T61.2** — Qualified applications: the directive lexer accepts
      dotted names (`@mod.macro`, any path depth, dots only between
      segments), and the expansion resolves them against the macro
      table — the body runs in the applying module's expansion, and each
      module's own expansion erases its own macro defs. Bare names
      resolve locally only, and a same-name local macro shadows the
      outside one (verified live: a local identity macro renaming the
      wrapped def answers a call the outside version would leave
      undefined). E4300 names the module when the path or the macro
      under it is missing.
- [x] **T61.3** — Cross-module argument checks: the macro-domain gate
      registers each outside macro as a pseudo def keyed by the dotted
      spelling — the real signature, a `Role_macro` directive (the
      `Syntax` window), and a body returning the `Syntax` name — so the
      argument checks see an outside macro exactly like a local one
      (E4306/E4307 verified across modules).
- [x] **T61.4** — The pilot: `examples/derive_shared` — one derivation
      in a sibling module, two classes applying it qualified,
      byte-identical across the interpreter, the c binary, and the
      TypeScript output. Package-boundary macros (a require-scoped
      library macro with the deps visibility rule) stay the named
      follow-up.
- [x] **T61.5** — Every target, verified: the four pilots join the
      wasm, beam, and riscv64 golden lists and pass byte-for-byte —
      `memoize_demo` waits on `Map` for riscv64 (the refusal is live,
      named in the list) — and the verification caught a real bug:
      every node a macro fabricates carried the macro body's span, so
      the span-keyed type tables had two decorated classes overwrite
      each other's entries (derive_eq's generated `self.x` typed as the
      second class on wasm and beam, invisible on the interpreter/c/ts
      where spans do not key anything). The fix is synthetic uniqueness:
      constructor-built spans move into a reserved offset range far past
      any real file, with line/col kept pointing at the constructor call.
- [x] **T61.6** — `emo dump`: the declaration surface after expansion,
      printed in source-like form — signatures, one line per statement —
      so a macro application's effect reads directly (`emo dump` lists
      the generated declarations; `emo dump --raw` shows what the macro
      author wrote, directives annotated). The macro model's visibility
      promise, kept: nothing a macro does is invisible.

## M25 — The postgres client

### Step 62 — The standard library: `postgres`

**Prereq:** Step 38 (the native-binding machinery: the manifest `link`/
`pkg_config` fields, package-carried C sources, the E5007 honesty
gate), Step 50 (the `foreign def` refusal on every other target).
**Done when:** `examples/postgres_demo` runs byte-for-byte against a
live server on the `c` target — DDL through `exec`, writes of every
parameter kind including SQL NULL, typed reads with a by-name lookup,
the error branch with SQLSTATE; the interpreter refuses with E3009 and
the other targets at resolution; docs EN+zh; `dune runtest` green.

- [x] **T62.1** — The package: `stdlib/registry/postgres/0.1.0` in the
      sqlite3 four-file shape — `package.emo`
      (`targets = ["c"]`, `pkg_config = ["libpq"]`), `internal/ffi.emo`
      (one `foreign def` per shim function, scalar ABI only),
      `emo_postgres_shim.c` (exact-ABI wrappers over libpq: the
      parameter staging between `exec_begin` and `exec_fire` with a
      bound-mask tripwire, status enums normalized in the shim,
      `_ok`/read pairs for the typed cell reads), and `postgres.emo` —
      the public API: `connect`/`connect_info` with the `ConnOptions`
      `with_*` builders, `exec`/`query` with `Param` values
      (`text`/`i64`/`f64`/`bool`/`none`) over `$1` placeholders, `Rows`
      with typed checked accessors and `finish()`, the `net` error
      split (`(R.error, reason)` values, contract violations raise).
- [x] **T62.2** — The demo and its golden: `examples/postgres_demo`
      rides a temp table against a live server (nothing left behind),
      three runs byte-identical against `expected.txt`; `postgres_demo`
      joins `c_goldens` behind the `postgres_available` probe
      (pkg-config resolution with the Homebrew-keg fallback putenv'd
      into the environment, a tiny `-lpq` link, one TCP connect to
      5432) and skips like `sqlite3_demo` does when the machine has no
      libpq or no server; the interpreter (E3009) and ocaml-resolution
      (E5007) refusals verified live.
- [x] **T62.3** — Docs and tracking: `docs/stdlib/postgres.md` + zh
      mirror (using, errors, connecting, running SQL, reading rows,
      boundaries), `docs/stdlib.md` rows and section + zh mirror —
      with the found-and-fixed `sqlite3` table row that had been
      missing since step 38 — README's references line, CHECK.md's
      decision record, `plan/step-62-postgres.md`, `plan/README.md`'s
      row. Found on the way, fixed in step: enum members need commas;
      a class's method names are in scope across sibling bodies
      (E4004); the tuple foreign return is unusable from a shim (the
      generated shape typedefs are per-program counter names).

## M26 — The Emo shell

### Step 63 — `emosh`, the shell in Emo

**Prereq:** Step 56 (the `os` surface on every target it declares, the
process half's run-time raise on wasm).
**Done when:** `projects/emo-shell` builds on the ocaml and c targets
and its fixture scripts — words and quoting, expansion, pipelines,
redirections, connectors, the builtins, the error paths — run
byte-identically on both with the pinned exit statuses; the `os`
surface grows `dup2`/`execvp`/`isatty`/`argv` and the environment and
signal halves with byte-identical reasons; docs EN+zh; `dune runtest`
green.

- [x] **T63.1** — The os plumbing four: `dup2`, `execvp`, `isatty`,
      `argv` across the interpreter, the compiled ocaml runtime, the
      c runtime (argv captured at main through `emo_args_set`), the
      checker's table, and the wasm process-half raise — the generated
      c main grows `int main(int argc, char **argv)`.
- [x] **T63.2** — The os environment and signal halves:
      `getenv` (unset the value `os: getenv NAME: is not set`),
      `setenv`, `unsetenv`, `signal_ignore`/`signal_default` with the
      classic range guard riding ahead of the call, and the signal
      constants `sig_hup`…`sig_term`; the three example locks
      re-resolved against the grown package; `docs/stdlib/os.md` + zh.
- [x] **T63.3** — The skeleton: `projects/emo-shell` (manifest
      `emo/emo-shell`, `targets = ["ocaml", "c"]`), the `Shell`
      session (status, running, the raw-descriptor writers — every
      byte through `os.write`, never a buffered stdout, so a fork
      child's output survives `_exit` and interleaving stays
      deterministic), the entry leaving through `_exit`.
- [x] **T63.4** — The lexer and the expander: words as literal and
      expandable parts (a bare run one part, so `$` reaches its name;
      quotes resolved at lex time), the operators, the `#` comment,
      the `&` refusal, unterminated quotes as values; `$var`/`${var}`
      /`$?`/`$0`/the leading tilde, unset empty, no IFS re-splitting —
      the honest contract the guide documents.
- [x] **T63.5** — The parser: line → items (pipeline + connector),
      strict about empty stages and dangling connectors, loose exactly
      where the classic shells are (a trailing `;`, a redirection-only
      command), errors as `(R.error, reason)` values — the shell has
      no catch to survive.
- [x] **T63.6** — The executor and the driver: the connector walk with
      the carried status, pipelines forked per stage wired through
      pipes and `dup2`, redirections opened onto the child, `execvp`
      and the 127 refusal, signal death as 128+signal, the child
      resetting `sig_int`/`sig_quit`/`sig_pipe` before its exec, the
      interactive ignores (Ctrl-C discards the line, the shell
      survives), the prompt, status 2 for a refused line.
- [x] **T63.7** — The eight builtins: `cd` (bare → $HOME), `pwd`,
      `echo` (verbatim, no flags), `exit` (the last status, the low
      byte's fold, the numeric-argument refusal), `export`/`unset`
      over the real environment, `true`/`false`.
- [x] **T63.8** — The goldens: six fixture scripts with pinned output
      and exit statuses, stderr merged into the one stream, run from
      the project's own directory, byte-identical on the ocaml and c
      targets in one Alcotest case (`emosh_golden`); the `projects`
      tree riding the suite's dune deps.
- [x] **T63.9** — Docs and tracking: `docs/emosh-guide.md` + zh (the
      grammar, the builtins, the honest limits), the `os.md` surface
      landed in T63.2, TASKS M26/Step 63 EN+zh,
      `plan/step-63-emosh.md` + `plan/README.md`'s row, CHECK.md's
      decision record, README's references line.

## M27 — The `websocket` and `playwright` packages

### Step 64 — Browser automation: `websocket`, then `playwright`

**Prereq:** Step 37 (`net`'s TCP surface and the per-operation
deadline), Step 62's package anatomy (manifest, registry embedding,
demo golden, docs EN+zh). **Done when:** `examples/websocket_demo`
echoes byte for byte on the interpreter and the `c` target;
`examples/playwright_demo` runs the full door ladder against the
repo's own miniature driver over real websocket frames — a
fragmented message joined, a ping answered with a masked pong the
driver reads back, the eight-byte length form riding a 120000-char
reply, both dispatcher error shapes — byte-identical on the
interpreter and the `c` target; `dune runtest` green with both demos
in the lockfile suite and in `c_goldens`; docs EN+zh.

- [x] **T64.1** — The `websocket` package:
      `stdlib/registry/websocket/0.1.0` — `websocket.emo` carrying
      both halves: `connect` (upgrade request with a `rand`-keyed
      `Sec-WebSocket-Key`, the accept verified against
      `crypto.legacy.sha1` before the first frame, the answer's
      header walk reading to the blank line so no handshake byte
      leaks into the frame stream), `accept` (the request checked for
      the upgrade, version 13, and the key; `101` answered), and one
      `Websocket` for both roles — `send_text` masking on the client
      side only, `recv_message` refusing masked frames at the client
      and bare frames at the server, assembling continuations,
      answering pings with their own payload, skipping unsolicited
      pongs, and answering a close before closing the socket; the
      frame reader takes all three length forms and refuses a peer's
      mask where the role forbids it. `package.emo`:
      `targets = ["ocaml", "c", "typescript"]`, deps `net`/`base64`/
      `crypto`/`rand`.
- [x] **T64.2** — The `playwright` package's engine:
      `stdlib/registry/playwright/0.1.0/internal/channel.emo` — one
      JSON document per text frame, commands `{id, guid, method,
      params, metadata}`, answers settled by id, `__create__` and
      `__dispose__` maintaining the guid object table, every other
      event skipped, the driver's error wrapping unwrapped into
      `(R.error, "playwright: " + text)`, and the null-safe field
      readers (`field`/`string_field`/`int_field`/`guid_field`) that
      keep driver data off the raise path.
- [x] **T64.3** — The facade: `playwright.emo` — `connect`/
      `connect_with` dialling the run-server endpoint with the
      browser on the `?browser=` query parameter (chromium, firefox,
      webkit; unknown names raise), the initialize handshake pinning
      the root Playwright channel and the pre-launched browser, and
      the core doors — `Browser.new_page`/`version`/`close`,
      `Page.goto` answering a `PageResponse` tree with the null
      response for a navigation that earns none, `click`/`fill`/
      `press` routing to the page's main frame, `title`/`content`,
      `text_content` answering a `Text` tree whose null reads through
      `is_null?()`, `screenshot` decoding the driver's base64 into
      `Bytes`, `close` at every level.
- [x] **T64.4** — The demos: `examples/websocket_demo` (echo server
      through `websocket.accept`, client round trips through
      `connect`: multi-byte, a 70000-byte message riding the two-byte
      length form, the goodbye); `examples/playwright_demo` (the
      miniature driver answering the run-server shapes over raw
      frames — the initialize object group, a skipped event, the
      page create with its main frame, the fragmented 70013-byte
      document, the ping the client must answer, the 120000-char
      screenshot reply riding the eight-byte form and assembled by
      hand around the json package's stack-depth landmine, both
      error shapes, the goodbye — the client half climbing every
      door); both goldens byte-identical across three interpreter
      runs and the `c` binary.
- [x] **T64.5** — The registrations: two `tc` cases in
      `test/emo_project/emo_cli_test.ml`'s sibling suite
      (`emo_project_test.ml`), `websocket_demo` and
      `playwright_demo` in `c_goldens`, lockfiles resolved through
      `emo deps resolve` after every package edit. Found on the way,
      fixed in step: the c backend's method lookup compared the
      reserved-word-escaped call name (`goto_c`) against the IR's
      plain name, refusing every C-keyword-named method — the call
      now names itself off the matched declaration.
- [x] **T64.6** — The docs: `docs/stdlib/websocket.md` and
      `docs/stdlib/playwright.md` EN+zh, `docs/stdlib.md` rows and
      sections + zh mirror, README's references line, CHECK.md's
      decision record, `plan/step-64-playwright.md`,
      `plan/README.md`'s row. Found on the way, documented: the json
      package's escape-length walk recurses per character and a
      120000-char `json.encode` rides past the c target's fiber
      stack (the interpreter survives; found-not-fixed, the demo
      works around it by hand-assembling the one large reply).
- [x] **T64.7** — The live check: `npm install -g playwright`
      (1.65.0, chromium headless shell 158.0.8127.18), then the
      whole door ladder against a real `playwright run-server`
      through `examples/playwright_live` — handshake, initialize
      with the pre-launched browser, the context-then-page dance,
      navigation against the program's own httpd page, title,
      multi-byte DOM text, a missing selector answering the 30000 ms
      metadata deadline as the error value, a real screenshot, the
      goodbye — **byte-green on the `c` target**; the interpreter
      trips the det scheduler's parked-read wall during the same
      wait (found-not-fixed, recorded in CHECK.md). The driver
      version is recorded in CHECK.md.

## M28 — The RocksDB half

### Step 65 — emo-db's RocksDB half

**Prereq:** Step 38 (the native-binding machinery: the manifest's
`link`/`pkg_config` fields, package-carried C sources, the E5007
honesty gate), Step 62 (the package anatomy: shim, staging, error
split, golden), `docs/emo-db.md` D1–D9 (D10 is settled in T65.1).
**Done when:** the project-local `emo/rocksdb` binding opens and closes
a database with column families, writes and reads arbitrary `Bytes`,
commits a WriteBatch atomically, iterates, scans a prefix, and reads at
a snapshot — all on the `c` target through `projects/emo-db/check.sh`,
whose KV golden runs three times byte-identical; the C ABI's `Bytes`
borrowed view lands as D10; the interpreter refuses with E3009 and every
other target at resolution with E5007, both verified live; docs EN+zh;
the repo builds.

- [x] **T65.1** — D10 in the design record EN+zh: the `Bytes` borrowed
      `{data, len}` view, argument-only, the out-parameter read, the
      refused return, `c`-only; D1's binding sentence, the architecture's
      storage item, the two open items, and the M28 ladder row. Doc-only;
      the wording is the contract the later tasks implement.
- [x] **T65.2** — The runtime's byte view: `emo_bytes_view` and
      `emo_bytes_view_build` in `emo_c_runtime.h`/`.c` (the cell's inline
      bytes plus its length, a borrow for the call only); additive, so
      `dune build` stays green with no program using it yet.
- [x] **T65.3** — The checker: `Bytes` joins `ffi_ok` on the `c` target
      alone, a `Bytes` foreign return reports E4200 with the
      out-parameter message, and the struct-shape field tier still
      refuses it; four `bytes_ffi` cases in `emo_check_test.ml` pin the
      clean parameter, the refused return, the non-c refusal, and the
      refused field. The test binary builds; the behavior is also probed
      through `emo check`/`emo build --target ocaml` by hand.
- [x] **T65.4** — The emitter: `foreign_c_type` maps `Bytes` to
      `emo_bytes_view`, the call site builds the view with
      `emo_bytes_view_build`, and the result position keeps a
      refusal guard. The compiler builds; the demo's `c` build at T65.11
      is the end-to-end proof.
- [x] **T65.5** — `docs/intro/native-builds.md` + zh: the FFI tier
      paragraph names `Int64`, `Void` returns, struct shapes, callbacks,
      and `Bytes` (the borrow, the refused return, the out-parameter).
- [x] **T65.6** — The binding's skeleton, open/close, and column
      families: `projects/emo-db/rocksdb/` with `package.emo`
      (`emo/rocksdb`, `targets = ["c"]`, `pkg_config = ["rocksdb"]`),
      `internal/ffi.emo`, `internal/reason.emo`, the shim's wrapper and
      one last-error buffer, `cfs_new`/`cfs_add`/`cfs_free`/`open`/
      `close`, `cf`/`cf_create`/`cf_list` and `destroy_db`, and the
      facade's `Db`/`Cf` with the `(R, reason)` split. `emo check` green;
      the demo's open/close and family beats verify it.
- [x] **T65.7** — Values: `put`/`get_len`/`get_into`/`delete` through the
      shim and `Cf`, the two-pass read (length first, copy into a
      caller-owned `Bytes`), the 0-or-1 `get`, and the `(R, reason)`
      storage split with contract violations raising. The demo's text,
      NUL, empty, and missing beats verify it. Found on the way, fixed
      in step: a NULL RocksDB status is success, and the first shim's
      error helper treated it as failure — `emo_rdb_check` now splits the
      void-shaped calls from the NULL-is-failure ones. Also settled:
      `(R, Void)` is not a shape, so writes answer the resource.
- [x] **T65.8** — Batches: `batch_new`/`batch_put`/`batch_delete`/
      `batch_write`/`batch_close`, the `Batch` facade, the same-database
      guard, and the Db's live-handle attach. The demo's batch beat
      commits two puts and a delete in one write.
- [x] **T65.9** — Iterators: `iter_new`/`iter_seek`/`iter_seek_to_first`/
      `iter_valid`/`iter_next`/`iter_key`/`iter_value`/`iter_close`, the
      key/value copy pair, and the `Iter` facade. The surface is
      prefix-scan capable: the demo seeks a prefix and walks while the
      key starts with it.
- [x] **T65.10** — Snapshots and the lifecycle guards: `snapshot_new`/
      `snapshot_close`, the shim's snapshot-plus-readoptions bundle, the
      `Snapshot` facade and the iterator count, `Db.close` refusing under
      a live batch/snapshot/iter, `Snapshot.close` refusing under a live
      iterator, and double-close raising. The demo's snapshot beats
      verify it. Found on the way, fixed in step: a local `const live`
      inside `close` collides with the `live()` method (E4004) — renamed
      `running`.
- [x] **T65.11** — The demo skeleton and the text beat:
      `projects/emo-db/kv_demo` (`package.emo`, `main.emo`'s die-on-
      failure helpers), destroy, open with `default` + `notes`, a text
      put/get, and `expected.txt` seeded. Builds and runs on `c`.
- [x] **T65.12** — The binary proof: a four-byte value `00 01 ff 41`
      round-trips (bytes=4, value=0001ff41), an empty value is present
      with zero bytes, and a missing key is an empty result — the three
      edges a NUL-terminated crossing cannot tell apart.
- [x] **T65.13** — The batch and prefix-scan beats: a three-effect batch
      (two puts, one delete) and a `user:` seek that walks the three
      keys and stops at `other:1`.
- [x] **T65.14** — The snapshot, `cf_create`, and reopen beats: a
      snapshot answers the old value while the latest state answers the
      new one, an iterator at that snapshot reads the old view and closes
      before the snapshot, a family created after open persists, and the
      reopen finds the bytes and the three family names. `expected.txt`
      is final at twelve lines. Found on the way, fixed in step: top-
      level consts used only by thunks still emit root-entry locals and
      earn unused-variable warnings — `digits` moved into `hex` and the
      second const inlined.
- [x] **T65.15** — The gate: `projects/emo-db/check.sh` resolves RocksDB
      (default pkg-config, then the Homebrew keg, then a tiny link
      probe), stages the binding into a content-named registry, checks
      the package, builds the demo, runs it three times against
      `expected.txt`, and pins E3009 (exit 70) and E5007 (exit 65) live.
      `kv_demo/package.lock` is generated with `emo deps resolve` after
      the last package edit and committed.
- [x] **T65.16** — `projects/emo-db/README.md` + zh: the layout, the
      binding's shape (binary keys and values, the error split, the
      lifecycle), the RocksDB prerequisite, the gate, and the M28 status.
- [x] **T65.17** — The close-out: the TASKS rows EN+zh, `plan/README.md`'s
      M28 bullet and step row, `CHECK.md`'s entry, the sqlite3 blob
      caveat (docs EN+zh, the package comment, and the re-resolved
      `examples/sqlite3_demo/package.lock`), `plan/step-65-emo-db-
      rocksdb.md`, and `dune build` / `dune build @fmt` green.

## M29 — The record layer

### Step 66 — The record layer

**Prereq:** Step 65 (the `emo/rocksdb` binding and the `Bytes` view).
**Done when:** the project-local `emo/record` package creates a table in
the catalog, inserts rows covering the v0 type subset (NULLs, an
embedded NUL in BYTEA, UTF-8 TEXT), reads them back by rowid, scans the
table, and finds rows through a secondary index — all on the `c` target
through `projects/emo-db/check.sh`, whose record golden runs three
times byte-identical and whose KV golden and E3009/E5007 pins stay
green; the catalog and the index CFs survive a reopen; docs EN+zh; the
repo builds.

- [x] **T66.1** — The spec and the tracker: `plan/step-66-record-layer.md`
      (the encoding contract), the plan README row, and this section
      EN+zh.
- [x] **T66.2** — The design notes: `docs/emo-db.md` + zh — D7's REAL
      note, the architecture's shared `data` CF, the M29 row, and the
      open items (range scans, streaming scans).
- [x] **T66.3** — `rocksdb.list_families(path)`: the shim's list handle
      over `rocksdb_list_column_families` (`list_new`/`count`/`name`/
      `free`, a missing path answering empty), the FFI declarations, and
      the facade's `(R, Array[String])`. The KV demo's gate stays green.
- [x] **T66.4** — `projects/emo-db/record/` skeleton and
      `internal/codec.emo`: `Buf`/`Reader` for u8/u32/u64/i32/i64/
      bytes/string with bounds checks, plus the UTF-8 length and
      bytes-prefix helpers. The encoders and the catalog codec live in
      `record.emo` — a root ↔ internal reference is a module cycle when
      the internal module calls root defs.
- [x] **T66.5** — The public types in `record.emo`: `ColType`,
      `Column`, `Index`, `ColumnDef`, `IndexDef`, `Value`, `Row`,
      `Table`, `Store`, the value constructors, `type_name`, and the
      contract checks (unique names, indexes reference columns, a
      positive VARCHAR length, primary implies NOT NULL).
- [x] **T66.6** — The row encoder/decoder, the value encoder, the
      index-key encoder, the VARCHAR code-point check, and the
      malformed-input guards (in `record.emo`).
- [x] **T66.7** — The catalog keys, the table definition
      encoder/decoder, the oid counters, and the load/save through the
      binding (in `record.emo`).
- [x] **T66.8** — `Store.open`/`close`/`table`/`tables`/`create_table`:
      CF enumeration, the base-CF open, the catalog load with the
      index-CF verification, oid allocation, index-CF creation, the
      catalog batch, and the reopen path.
- [x] **T66.9** — `Table.insert`: value validation, the unique-index
      prefix check, the rowid, the row/index/catalog batch, the counter update
      on success, and the duplicate-key error value.
- [x] **T66.10** — `Table.get`/`scan`/`scan_index`: the row-key reads,
      the table prefix scan, the index prefix scan with the rowid
      suffix, and the ordered results.
- [x] **T66.11** — `projects/emo-db/record_demo/` skeleton: destroy,
      open, create `users`, list the catalog, close; the seeded
      `expected.txt`.
- [x] **T66.12** — The demo's insert beats: three rows covering every
      type, NULLs, an embedded NUL in BYTEA, UTF-8 TEXT, and a
      duplicate unique key answering the error value.
- [x] **T66.13** — The demo's read beats: get by rowid, the table scan,
      the name-index equality scan, the id-index scan, and the reopen
      listing the catalog and the rows.
- [x] **T66.14** — The gate: stage `emo/record`, build the record demo,
      run it three times against `expected.txt`, and keep the KV demo
      and the E3009/E5007 pins green; the record demo's lock via
      `emo deps resolve`.
- [x] **T66.15** — The project README + zh: the record layer's formats,
      the demo, and the gate.
- [x] **T66.16** — The close-out: TASKS EN+zh, the plan README, the M29
      row, `CHECK.md`'s entry, and `dune build`/`@fmt` green.

## M30 — The SQL front-end's DML and DDL

### Step 67 — The SQL front-end's DML and DDL

**Prereq:** Step 30 (the `sql` package's SELECT surface and expression
grammar). **Done when:** the `sql` package parses `CREATE TABLE` (the v0
column types, `NOT NULL`, `PRIMARY KEY`), multi-row `INSERT`, `UPDATE`,
and `DELETE` beside `SELECT`, renders every tree back to canonical SQL,
and answers malformed input with a reason and a byte offset; the SELECT
grammar is unchanged; `example/sql_demo` and `sql_edge` print the pinned
bytes on the interpreter and all five hosted targets; docs EN+zh; the
repo builds.

- [x] **T67.1** — The spec and this section EN+zh.
- [x] **T67.2** — The AST: the four `StmtKind` members, `SqlType`,
      `ColumnDef`, `CreateTable`/`Insert`/`Update`/`Delete`,
      `Assignment`, and the canonical renderers.
- [x] **T67.3** — The token helpers and `is_reserved` additions.
- [x] **T67.4** — `parse_create_table`: name path, column list, types
      (including `DOUBLE PRECISION` and `VARCHAR(n)`), constraints,
      duplicate-column checks, unsupported-constraint refusals.
- [x] **T67.5** — `parse_insert`: `INTO`, optional column list, VALUES
      rows, row-width checks, duplicate columns, unsupported tails.
- [x] **T67.6** — `parse_update`: SET assignments, duplicate check,
      optional WHERE, trailing-token refusals.
- [x] **T67.7** — `parse_delete`: FROM, optional WHERE, trailing-token
      refusals.
- [x] **T67.8** — `parse_stmt` dispatches the five statements.
- [x] **T67.9** — `examples/sql_demo`: the DDL/DML parses, renderings,
      and AST reads; `expected.txt` regenerated.
- [x] **T67.10** — `examples/sql_edge`: the old INSERT refusal replaced;
      new malformed DDL/DML cases; `expected.txt` regenerated.
- [x] **T67.11** — The package header, `docs/stdlib/sql.md` + zh, and
      the index row if its wording moved.
- [x] **T67.12** — The close-out: the two `sql` locks re-resolved,
      `plan/README.md`, the M30 row, `CHECK.md`, `dune build`/`@fmt`,
      and the evidence.

## M31 — The planner and executor

### Step 68 — The planner and executor

**Prereq:** Step 66 (the record layer) and Step 67 (the SQL AST's DDL/
DML). **Done when:** an embedded engine turns SQL text into rows on the
`c` target — CREATE TABLE, INSERT, single-table SELECT with WHERE and
projection (table scan and equality index scan), UPDATE, and DELETE —
with the plan text pinned and the PG-shaped errors (`42P01`, `42703`,
`42883`, `42804`, `23505`, `23502`, `22012`, `0A000`) answered as
values; the engine demo runs three times byte-identical through
`projects/emo-db/check.sh`; the record/KV goldens and the E3009/E5007
pins stay green; docs EN+zh; the repo builds.

- [x] **T68.1** — The spec and this section EN+zh.
- [x] **T68.2** — The record layer's `Table.update`/`delete` with index
      maintenance and the unique checks.
- [x] **T68.3** — The engine skeleton: manifest, `SqlError`, `Result`,
      `open`/`close`.
- [x] **T68.4** — The analyzer: table/alias/column resolution, the type
      mapping, conformance, PG-shaped errors.
- [x] **T68.5** — Typed expressions and their evaluators (3VL, IS/IN/
      BETWEEN/LIKE/CASE, coercions, runtime errors).
- [x] **T68.6** — CREATE TABLE execution (types, constraints, pkey
      index, refusals).
- [x] **T68.7** — INSERT execution (column list, NULL fill, coercion,
      not-null, duplicate mapping).
- [x] **T68.8** — SELECT planning/execution (scan choice, filter,
      projection).
- [x] **T68.9** — UPDATE/DELETE planning/execution.
- [x] **T68.10** — The plan text and the result's plan field.
- [x] **T68.11** — The engine demo and `expected.txt`.
- [x] **T68.12** — The gate: stage the engine, build/run the demo three
      times.
- [x] **T68.13** — The project README + zh, the package docs, the locks.
- [x] **T68.14** — The close-out: TASKS, plan README, CHECK.md, build/
      fmt.

## M32 — Transactions and the session plane

### Step 69 — Transactions and the session plane

**Prereq:** Step 66 (the record layer), Step 67 (the SQL AST), Step 68
(the engine). **Done when:** BEGIN/COMMIT/ROLLBACK work over the
record layer's new transaction (one WriteBatch, a per-statement
snapshot, read-your-writes through the pending overlay, rowid counters
published on commit); the engine's session plane holds table locks
through an Emo lock-manager process, blocks a second writer, aborts a
deadlock with `40P01`, and releases on commit/rollback; a two-session
golden shows read committed, the block, and the deadlock on `c`, three
runs byte-identical through `projects/emo-db/check.sh`; the existing
goldens and the E3009/E5007 pins stay green; docs EN+zh; the repo
builds.

- [x] **T69.1** — The spec and this section EN+zh.
- [x] **T69.2** — `sql`: `BEGIN`/`COMMIT`/`ROLLBACK`, the examples'
      cases, the five-target re-run.
- [x] **T69.3** — The record `Txn` and the `Table` tx methods.
- [x] **T69.4** — The engine's transaction state and autocommit path.
- [x] **T69.5** — The `LockClient` interface and the engine's table
      locks.
- [x] **T69.6** — The lock-manager process and the deadlock check.
- [x] **T69.7** — The session process and `RemoteLocks`.
- [x] **T69.8** — `txn_demo`: the three scenarios and `expected.txt`.
- [x] **T69.9** — The gate: the fourth demo and the build-failure
      guards.
- [x] **T69.10** — The docs EN+zh and the design record's notes.
- [x] **T69.11** — The close-out: TASKS, the plan README, CHECK.md,
      build/fmt.

## M33 — The wire

### Step 70 — The wire

**Prereq:** Step 66 (the record layer), Step 67 (the SQL front-end),
Step 68 (the engine), Step 69 (transactions and the lock manager).
**Done when:** emo-db speaks PostgreSQL protocol v3's simple query path
over `net` — startup (with the SSL/GSSENC refusal and trust
authentication), ParameterStatus/BackendKeyData/ReadyForQuery,
Query with a multi-statement string, RowDescription with the v0 type
OIDs, DataRow in text format, CommandComplete, EmptyQueryResponse, and
ErrorResponse with PG's field convention; an error stops the remaining
statements and leaves the session's transaction state clean; one
session actor per connection, over a shared Store, with the table
locks of Step 69; psql drives the surface end-to-end and the standard
library's `postgres` client connects and runs the same script through
its new zero-parameter simple path, both pinned byte-for-byte behind
`psql`/`libpq` availability probes; the existing goldens stay green;
docs EN+zh; the repo builds.

- [x] **T70.1** — The spec: this section EN+zh and
      `plan/step-70-wire.md`.
- [x] **T70.2** — `sql.split`, the statement splitter over the
      lexer's own token stream, and its `sql_demo`/`sql_edge` cases on
      the six paths.
- [x] **T70.3** — The engine's `Result.types` (the projection's value
      types for RowDescription), and `engine.start_lock_manager` /
      `engine.RemoteLocks` moved out of `txn_demo` into the package.
- [x] **T70.4** — The `postgres` shim's zero-parameter `PQexec` simple
      path, so the standard client can talk to a server without the
      extended protocol.
- [x] **T70.5** — `emo/wire`: the byte buffer, the startup message
      forms (SSLRequest/GSSENCRequest answered `N`, CancelRequest
      closed), the backend message builders, and the v0 OIDs and text
      encoding.
- [x] **T70.6** — The query cycle: split, empty query, multi-statement
      execution, error response and stop, ReadyForQuery's transaction
      status, and the clean abort.
- [x] **T70.7** — The session actor and the accept loop: one Engine
      and one `RemoteLocks` per connection over the shared Store, the
      max-connections stop, and the lock manager.
- [x] **T70.8** — `wire_demo` (the server, with the ready file) and
      `wire_client` (the `postgres` client), with their goldens.
- [x] **T70.9** — The gate: build the wire package and the two demos,
      probe `psql` and `libpq`, run the two phases, pin the goldens.
- [x] **T70.10** — The docs EN+zh: the project README, the design
      record's wire notes, the `postgres` zero-parameter path, the
      `sql.split` API.
- [x] **T70.11** — The close-out: TASKS, the plan README, CHECK.md,
      build/fmt.

## M34 — Conformance and documentation

### Step 71 — Conformance and documentation

**Prereq:** Steps 65–70 (the whole row-store arc). **Done when:** the
engine's SQL surface has a text-comparable corpus in the SQLLogicTest
spirit — statement cases with pinned command tags, query cases with
pinned rows, and error cases with pinned `code: message` strings —
run against one fresh database and byte-identical three times through
`projects/emo-db/check.sh`; a measured-performance table records only
numbers the bench script actually measured, with the machine, date, and
method; `docs/emo-db.md` grows a shipped-surface section, the corpus
and benchmark pointers, corrected stale claims, and an arc-two review
against what arc one built (EN+zh); the project READMEs carry the new
gate and the M34 status; the repo builds.

- [x] **T71.1** — The spec: this section EN+zh and
      `plan/step-71-conformance.md`.
- [x] **T71.2** — The corpus format and `corpus_runner` — one fresh
      database per invocation, per-file counts, failures collected and
      a nonzero exit.
- [x] **T71.3** — The corpus files: DDL, the v0 types, DML, SELECT and
      its expressions, transactions, and the error/SQLSTATE surface.
- [x] **T71.4** — The gate: build and run the corpus three times
      byte-identical.
- [x] **T71.5** — The bench program and `bench/run.sh` (warmup plus
      three timed runs), and the recorded measurement.
- [x] **T71.6** — The gate's bench smoke: the modes' counts checked
      without pinning a time.
- [x] **T71.7** — `docs/emo-db.md` + zh: the shipped surface, the
      corpus and benchmark sections, the measured table, the corrected
      open items, and the arc-two review.
- [x] **T71.8** — The project READMEs EN+zh: the corpus, the bench, the
      gate's new checks, and the M34 status.
- [x] **T71.9** — The close-out: TASKS, the plan README, CHECK.md,
      build/fmt.

## M35 — The column format

### Step 72 — The column format

**Prereq:** Step 71 (arc one closed). **Done when:** `CREATE TABLE ...
STORE = COLUMN` parses (the canonical rendering spells `STORE =
COLUMN`, `STORE = ROW` is the default), the catalog's table definition
moves to version 2 with a `store` field while a version-1 record reads
as row storage, and the record layer stores a column table as 1024-row
blocks in one column family per column — insert through the
transaction's pending overlay and batch, a full-block scan, and the
reopen's column-family verification; column tables carry no indexes
(`PRIMARY KEY` and secondary indexes answer `0A000`); the engine maps
the DDL and bridges DML/SELECT with the named `0A000`; a record-layer
golden (create, insert, reopen, scan, the refusals) runs three times
byte-identical through `projects/emo-db/check.sh`; every existing
golden stays green; docs EN+zh; the repo builds.

- [x] **T72.1** — The spec: this section EN+zh and
      `plan/step-72-column-format.md`.
- [x] **T72.2** — `sql`: `StoreKind`, `CreateTable.store`, the tail
      parse, the rendering, the examples, the six paths.
- [x] **T72.3** — `record`: `Storage`, `TableMeta.store`, the
      version-2 encoding, the column families, the column insert and
      scan, the reopen verification.
- [x] **T72.4** — `column_demo` and its golden.
- [x] **T72.5** — `engine`: the DDL mapping and the bridge.
- [x] **T72.6** — The gate: the fifth demo.
- [x] **T72.7** — The docs EN+zh and the close-out.

## M36 — The column executor

### Step 73 — The column executor

**Prereq:** Step 72 (the column format). **Done when:** a SELECT on a
column table routes to the batch executor — the block scan, the shared
filter and project over block-materialized values, and the global
aggregates COUNT/SUM/AVG/MIN/MAX (COUNT answers 0 over zero rows, the
others NULL; SUM widens integer to BIGINT and real to DOUBLE PRECISION;
AVG is DOUBLE PRECISION; MIN/MAX answer the argument's type); the
select list is all plain items or all aggregate calls (a mixture
answers `42803` with the column named); aggregates are whole select
items only (nested calls keep the function refusal); `count(*)` with no
WHERE takes the block-count fast path; UPDATE and DELETE answer
`0A000: column-store tables are insert-only in v0` and INSERT rides the
column blocks through the same transaction; the plan text shows
`column scan`/`aggregate`; the engine demo grows the executor's cases
and everything stays byte-identical three times through
`projects/emo-db/check.sh`; docs EN+zh; the repo builds.

- [x] **T73.1** — The spec: this section EN+zh and
      `plan/step-73-column-executor.md`.
- [x] **T73.2** — `record`: `scan_column_batches`,
      `column_block_counts`, `scan_column_tx` on the batches.
- [x] **T73.3** — `engine`: the routing, the refusals, the column plan
      nodes, and the aggregate machinery.
- [x] **T73.4** — The engine demo's executor cases.
- [x] **T73.5** — The gate green three times.
- [x] **T73.6** — The docs EN+zh and the close-out.

## M37 — The two-engine proof

### Step 74 — The two-engine proof

**Prereq:** Steps 72–73 (the column format and the column executor).
**Done when:** one database holds both storages and one session crosses
them inside one transaction — `htap_demo` seeds a row table and a
column table (1100 rows, across the block boundary) through the engine
and serves the wire; psql runs a script that reads both engines, updates
the row table and inserts into the column table inside BEGIN/COMMIT,
and reads the post-commit aggregates, pinned byte-for-byte; the standard
library's `postgres` client runs the same script through its simple
path, pinned; the corpus gains `column.test` (the DDL, projections, the
five aggregates, the zero-row rule, the mixing/type/DISTINCT/insert-only/
primary-key refusals) and the runner's transcript stays byte-identical
three times; the bench gains the column-scan and column-aggregate rows
with the measured numbers recorded; docs EN+zh; the repo builds.

- [x] **T74.1** — The spec: this section EN+zh and
      `plan/step-74-two-engines.md`.
- [x] **T74.2** — `htap_demo` and `htap_client` with their goldens.
- [x] **T74.3** — The gate's two-engine phases.
- [x] **T74.4** — The corpus's `column.test`.
- [x] **T74.5** — The bench's column modes and the recorded numbers.
- [x] **T74.6** — The docs EN+zh and the close-out.
## M38 — The wasm capability

### Step 75 — The wasm package: the execution surface and the host interface

**Prereq:** Steps 20–22 (the Emo-written runtime: decoder, validator,
interpreter, spec-suite goldens). **Done when:** the package lives at
`stdlib/registry/wasm/0.1.0/`, resolved like any bundled package; a user
project declaring `"wasm" = "0.1.0"` loads a module from bytes, serves
its imports with Emo closures, instantiates it, calls its exports, reads
its globals, and moves bytes through its linear memory — every failure
an `(R.error, reason)` value, never a raise; `examples/wasm_demo` pins
the ladder (load → host → instantiate → call → memory round-trip)
byte-identical across runs; the smoke slice rides `dune test` from the
package's new home and the `wasm_spec` / `wasm_runs` aliases still
report zero pending and zero failed; docs EN+zh.

- [x] **T75.1** — The move: `runtime/wasm/` →
      `stdlib/registry/wasm/0.1.0/` — `wasm.emo`, `internal/`, the
      manifest, the drivers and fixtures, `testdata/`, the package
      README, and the dune rules carrying the smoke slice and the two
      aliases; the root `dune` comment and `devtools/vendor-wasm-spec`'s
      output paths follow; plan steps 20–22 stay as history.
- [x] **T75.2** — The public surface: the R-split execution defs on
      the package root (`load`, `instantiate`, `call`, `get_global`,
      `read_memory`, `write_memory`, `register_instance`, `describe`),
      the value constructors (`i32`/`i64`/`f32`/`f64` and the
      `from_bits` pair) and the `as_*` accessors, the `(kind, bits)`
      encoding documented; `load` migrates from the five-tuple, the
      fixtures update with it; `decode` keeps its diagnostic verdict.
- [x] **T75.3** — The host table: `(module, name, fn)` import triples
      riding `instantiate`, the uniform host signature
      `-> (args Array[(Int64, Int64)]) (Int64, Int64)`, the resolution
      order explicit table → register namespace → `spectest`;
      fixtures: a module importing from `env` served by an Emo
      closure, the order pinned, a missing import link-failing as
      before.
- [x] **T75.4** — The demo golden: `examples/wasm_demo/` with a
      hand-built module (hex in Emo, reviewable) exercising the whole
      ladder; the golden runs through the interpreter with the
      registry pointed at the bundled copy.
- [x] **T75.5** — The docs: `docs/wasm.md` EN+zh (the surface, the
      value encoding, the host interface, the limits — no WASI yet, no
      GC types, `["ocaml"]` only); `docs/stdlib.md` row + section +
      zh mirror; the temp notes retire to the new reference; README's
      row; `plan/README.md`'s row; CHECK.md's decision record. The
      package reference lands at `docs/stdlib/wasm.md` (the house's
      per-package location), not `docs/wasm.md`; the temp notes move
      out of the repository. `wasm.emo`'s smoke driver renames from
      `main.emo` to `smoke.emo` — the package root's `main.emo` is the
      module a require binds when it exists, and the smoke driver's
      file would have shadowed the surface.
- [x] **T75.6** — The c backend grows module-level `var`: one
      `static emo_value` cell per `pglobal` declared before every body,
      reads handing out pooled claims (unboxing at native-typed read
      sites), assignments through the write barrier a local's overwrite
      uses, the cells initialized in declaration order at
      `emo_root_entry`'s start; the interpreter's dep-check universe
      resolves against the `c` target, so without this the package
      could not be consumed across a deps edge at all. Proven by
      byte-identity: all five fixtures and the demo golden answer
      identically on the interpreter and the c target; the whole
      repo's `dune runtest` stays green; the package's manifest widens
      to `["ocaml", "c"]` — verified, not assumed (CHECK.md).

### Step 76 — `emo wasm run`: the CLI rung

**Prereq:** Step 75 (the package and its execution surface). **Done
when:** `emo wasm run foo.wasm` loads, validates, and instantiates the
artifact through the embedded driver — the instance's start function
runs, the entry ladder answers `_start`, then `main`, then the
one-line summary for a module that names neither; results print in the
runtime's `value : kind` format; every failure (bad artifact, failed
link, trap) answers with the reason and a nonzero exit, never a raise;
a binary-only machine (no registry, no project) runs the artifact; the
publish/login embedded paths behave unchanged; `dune runtest` green;
docs EN+zh.

- [x] **T76.1** — The generalized embedded runner: `run_embedded`
      delegates to `run_embedded_deps` (the dependency list a
      parameter); the wasm driver program lands as an embedded string
      (`__artifact` global, the entry ladder, the `value : kind`
      result format over the public surface). The embedded scratch
      projects stop printing the lockfile-commit notice — the manifest
      it points at dies with the run.
- [x] **T76.2** — The `emo wasm run` command: the `wasm` group, the
      run subcommand (artifact argument, absolute-path resolution
      before any chdir), the error verdict to stderr with exit 1, the
      doctor line naming the command.
- [x] **T76.3** — The tests: six cases in `test/emo_cli`'s
      `wasm_run` group — the export's results, the start-only summary,
      the trap, the failed link with the import's name, the malformed
      artifact in the decode phase, the missing artifact's read
      reason. The artifacts ride as hex decoded in the test (the
      corpus discipline: no `.wasm` blob enters the repository), each
      verified against the runtime before pinning.

### Step 77 — WASI preview1: the rung other toolchains' modules run on

**Prereq:** Steps 72 (the package and its host interface), 73 (the CLI
rung). **Done when:** the built-in host answers `wasi_snapshot_preview1`'s
twelve-function subset (args, environ, proc_exit, fd_write, fd_close,
fd_seek, fd_fdstat_get, random_get, clock_time_get ENOSYS,
sched_yield) with everything else link-refusing by name; the CLI takes
extra arguments as the WASI argv and maps proc_exit's code to its exit
code, and a module's stdout survives its own exit; a real
`rustc --target wasm32-wasip1` module (target installed with the
user's approval) runs through `emo wasm run` — printing, seeding its
HashMaps through random_get, and exiting through proc_exit; the
fixtures pin the errno numbering and the iovec walk; `dune runtest`
green; docs EN+zh.

- [x] **T77.1** — The wasi host: `internal/wasi.emo` — the errno
      names, the function table, the memory io (iovec walks, guest
      writes, the fdstat layout), proc_exit's verdict on the trap
      channel, the argv consumer. `clock_time_get`'s precision
      parameter is an i64 — the one non-i32 in the subset, checked.
- [x] **T77.2** — The resolution arm (explicit table → wasi → register
      → spectest, signatures checked) and the dispatch arm (host calls
      touching the caller instance's live memory);
      `wasm.set_wasi_args` on the package root; the package's
      `deps` grows `rand` for random_get's entropy, and the demo's
      lockfile re-resolves.
- [x] **T77.3** — The CLI: extra positional arguments as the wasi
      argv (argv[0] the artifact's basename), proc_exit's code parsed
      from the driver's verdict line and mapped to the exit code
      silently. The embedded runner splits into
      `run_embedded_deps_out` (the pair: verdict and partial stdout) —
      a module that prints and then exits or traps still has its
      bytes delivered. The embedded programs stop printing the
      lockfile-commit notice (already landed with 73).
- [x] **T77.4** — The fixtures: `wasi-fixture.emo` — the iovec walk
      byte-exact with nwritten read back through the package's own
      memory door, proc_exit's code on the trap channel, the argv
      encoding (pointers, then the nul-terminated buffer), EBADF,
      ENOSYS, random success, the fdstat layout, the mistyped import
      binding to nothing, and path_open failing the link with its
      name. Found and fixed on the way: dune's parallel fixture rules
      raced the shared package cache — a shared temp name renaming
      files out from under a sibling materialization, half-written
      files digesting, a torn manifest parse — fixed in `materialize`
      (per-process temp, atomic rename, the open retrying behind a
      fresh directory) and by pinning each fixture action's
      `EMO_CACHE_DIR` to a sandbox-local directory (CHECK.md).
- [x] **T77.5** — The live check: `rustc --target wasm32-wasip1`
      (1.98.1, std installed with the user's approval) — hello world
      printing through fd_write with argv counting; a HashMap module
      seeding through random_get; `process::exit(7)` riding to the
      CLI's exit code with the earlier prints surviving. All green.
- [x] **T77.6** — The docs: the WASI section in
      `docs/stdlib/wasm.md` EN+zh (the subset table, the honest edges:
      no clock, no filesystem, fds 1/2 only; the `emo` host module's
      deferral argued); TASKS/plan/CHECK updated.

## M39 — Text templates

The `template` package renders text with holes from a `json` context —
Go `text/template`'s mechanism with Emo's own surface, pure Emo over
the shared runtimes, so every hosted target answers byte for byte. It
is the text-templating genre the raw-strings settle named as its
revisit trigger; EmoUI's "no template language" ruling stands — that
was about UI composition, and this engine's expressions are data paths
over the json tree, never Emo code, so the checker never sees them and
nothing evals at runtime.

### Step 78 — The standard library: `template` · `plan/step-78-stdlib-template.md`

**Prereq:** Step 31 (json — the value tree the context rides and the
error split) and step 47 (csv — the byte-scanner discipline and the
all-five-golden shape). **Done when:** `require "template"` renders a
template with a json context byte-identically on all five targets —
the one-shot `render`, the `Set` (new/with/render), `if`/`else
if`/`else`/`end`, `for` over arrays and objects with `else`,
`template` includes with the depth cap, trim markers, comments, seven
ASCII-safe filters — parse strict and render strict, goldens on all
five paths; `dune test` green.

- [x] **T78.1** — The package: `stdlib/registry/template/0.1.0`
      (manifest over all five targets, deps `json` + `float`),
      `template.emo` — the root: `render`, `new`, the `Set` with
      `with`/`render` — and `internal/engine.emo` — the AST, the byte
      scanner, the parser (loop-based, recursion bounded by the 512
      nesting cap), and the renderer (nearest-binding-then-root
      resolution, the filter table, includes with the depth cap).
- [x] **T78.2** — The goldens: `examples/template_demo` (the whole
      walk: one-shot, the set with partials, if chains, for over
      arrays and objects, for-else, every filter, trim markers,
      comments, bracket paths, includes with and without a pipeline)
      and `examples/template_edge` (the refusal matrix: every parse
      error shape, every render error shape, the include cap, the
      boundary that holds) — both on all five golden lists:
      bootstrap, typescript, c, wasm, beam.
- [x] **T78.3** — The docs: `docs/stdlib/template.md` + zh-CN mirror
      (using, the grammar, resolution, truthiness, includes, filters,
      errors, boundaries), `docs/stdlib.md` row + section + zh mirror,
      README's references line.
- [x] **T78.4** — The tracking: `plan/step-78-stdlib-template.md`,
      `plan/README.md`'s milestone bullet and status row, CHECK.md's
      settle record, this section and its zh mirror.

Two compiler bugs the goldens flushed, both verified against the full
suite: **the IR's module-level def mangle skipped `sanitize_ident`**
(`filter_exists?` lowered to a raw `?` — illegal in TypeScript and
OCaml identifiers; class methods had the sanitizer, module-level defs
and `emo` group members did not — both mangle sites now sanitize), and
**the BEAM emitter's case-in-threaded-chain path registered a branch's
pattern bindings into the scope before the per-branch save** — the
map's save rode after `emit_pattern`, whose `fresh_var` registers — so
a sibling arm's pattern variables leaked into the enclosing scope and
into a later continuation's live set, dying as `unbound variable` in
erlc (the `stmt` case path already had the save before the pattern;
`expr`'s threaded case and `emit_threaded_control`'s now match it).
The `template_edge` golden also settled the bare-`}}` question the
other way from the plan draft: a `}}` outside an action is text, not
an error — code-generation templates close nested braces in their
static text, and Go's own scanner agrees.

## M40 — The repl's line editor

### Step 79 — The repl's line editor (linenoise)

**Prereq:** Step 08 (the repl itself). **Done when:** the interactive
session edits its input with the vendored upstream linenoise — arrow-key
history recall persisted to a state file, multi-line editing of long
lines, the continuation prompt indented by bracket depth, Ctrl-C
abandoning instead of killing — while pipes, redirects, and the tests
keep the plain line path byte for byte; the vendored C compiles through
dune's `foreign_stubs` behind a binding module whose stubs map the
library's errno verdicts onto variants; the tests drive the real editor
over a pipe through upstream's `LINENOISE_ASSUME_TTY` hook; `dune
runtest` green; docs EN+zh.

- [x] **T79.1** — The vendored editor: `linenoise.c`/`linenoise.h` at
      upstream `a473823d74b93eab2ba83480df16ed37617493f2` (2026-05-01)
      with the two marked patches — the edit session's temporary
      history entry pops on the Ctrl-C and end-of-input exits exactly
      as ENTER pops it, end-of-input answers `ENOENT` (upstream leaks
      one empty entry per Ctrl-C into the history otherwise), and the
      blocking read's verdict errno is captured before the stop's
      cleanup and restored after (that cleanup probes the terminal and
      would clobber the verdict). The C stubs and the `emo_linenoise`
      binding module — the stubs follow OCaml's mixed-variant
      encoding, constants and payload constructors numbered
      independently; dune's `foreign_stubs`.
- [x] **T79.2** — The seam: the input function receives the prompt
      text (the editor renders it itself), and its answer distinguishes
      `Line` from `Aborted` and `Eof`; `unbalanced` shares its bracket
      count with the continuation prompt, which indents two spaces per
      open `{`/`(`/`[` and keeps the plain dots when the lexer cannot
      scan the pending source; the editor session loads, adds, and
      saves the history with its warnings.
- [x] **T79.3** — The tests: the repl suite on the new seam; the
      depth/indent units; the history-file resolution (`EMO_STATE_DIR`
      → `XDG_STATE_HOME` → `$HOME`, no home no file); the editor smoke
      over a pipe — the typed line, the up-arrow recall, the Ctrl-C
      that abandons without leaking an empty entry, the input's end,
      and a two-session persistence round-trip through the state file.
- [x] **T79.4** — The docs: the repl section in `docs/toolchain.md`
      EN+zh; TASKS/plan/CHECK updated.

## M41 — The standard library: `uuid`

### Step 80 — The `uuid` package (RFC 9562)

The identifier as one value and the versions that mint it. The step's
tasks, all landed:

- [x] **T80.1** — The package `stdlib/registry/uuid/0.1.0`, pure Emo
      over `crypto` and `rand`: the `Uuid` class (`to_string` the
      protocol method rendering the lowercase hex-and-dash form,
      `to_bytes` the network-byte-order bytes, `version` the high
      nibble of octet 6, `variant` the Table 1 reading of octet 8's
      top bits — `ncs`/`rfc`/`microsoft`/`future` — `is_nil?`/
      `is_max?`, and `compare` the RFC 6.11 big-endian order), and
      the module doors — `nil`/`max`, `from_bytes` (any 16 bytes; a
      length other than 16 refused), `parse` (exactly the canonical
      36-character form, hex case-insensitive per the RFC's own
      ABNF, the first offending byte named), `v4` (122 random bits
      over `rand.bytes`, the entropy reason passed through),
      `v7(now_ms)` (the caller's clock — the language has none — 48
      bits of Unix time over 74 random bits; a negative or
      48-bit-overflowing timestamp raises, the year-10889 bound),
      `v3`/`v5` over `crypto.legacy`'s MD5 and SHA-1 (deterministic;
      the namespace bytes then the name's UTF-8 bytes; any `Uuid` a
      custom namespace), and `ns_dns`/`ns_url`/`ns_oid`/`ns_x500`.
      One `source_of` map drives both `parse` and `to_string`, so
      both directions read the same 36-character shape.
- [x] **T80.2** — The golden `examples/uuid_demo`: the RFC's Figure 1
      example parsed, rendered lowercase, version/variant read back;
      the Appendix A.2 and A.4 name-based vectors
      (`5df41881-3aed-3515-88a7-2f4a814cf09e`,
      `2ed6657d-e927-568b-95e1-2665a8aea6a2`) and one more name in
      the URL namespace — all verified against Python's standard
      implementation before freezing; the Table 3 namespace IDs;
      Nil/Max and their order; the 16-byte round trip and the wrong
      length refused; the strict refusals (32/35/38/45 characters, a
      bad dash at 8, a bad digit at 35) each with its byte offset;
      and the random doors printed structure-only — v4's version,
      variant, and two draws differing; v7's version, variant, the
      A.6 timestamp `1645557742000` read back out of the bytes, two
      draws at the same millisecond differing, and the next
      millisecond sorting after — so the golden rides every target
      byte for byte.
- [x] **T80.3** — The registration: `uuid_demo` onto `wasm_goldens`,
      `beam_goldens`, and `c_goldens` in `test/emo_cli`, the
      typescript golden list and the bootstrap list in
      `test/emo_project`; verified byte-identical on the
      interpreter, the `c` target, and the `typescript` target
      before landing.
- [x] **T80.4** — The docs: `docs/stdlib/uuid.md` EN+zh; the
      `docs/stdlib.md` row and section EN+zh; the README reference
      lists EN+zh; TASKS/plan/CHECK updated.

