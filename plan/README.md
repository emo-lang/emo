# Implementation Plan

The reference implementation of Emo is written in OCaml 5 (self-hosting is
explicitly not a goal). This directory breaks the work into MVP-first,
incrementally shippable steps — one file per step, executed in order.

## Milestones

- **M1 — MVP interpreter (steps 01–08):** single-file Emo programs run through
  `emo run` / `emo repl` with a hand-written pipeline: lexer → recursive-descent
  parser → tree-walking evaluator.
- **M2 — Compile-time experience (steps 09–11):** the built-in gradual type
  checker, the structural module system (directory tree = module tree), and
  packages with MVS resolution.
- **M3 — Concurrency & networking (steps 12–13):** processes and message
  passing on an effects-based scheduler, plus the direct-style networking API.
- **M4 — Compilation targets (steps 14–19):** native code generation, then
  wasm / TypeScript / BEAM / riscv64.
- **M11 — The standard library (steps 31–38):** the bundled stdlib
  packages — `json`, `yaml`, `xml`, `os`, `base64`, `slog`, `bufio`, and the
  native-binding `sqlite3` — each with a full API reference and a runnable
  golden, on every target it declares. (The full milestone list is in
  `docs/TASKS.md`.)
- **M15 — EmoUI (step 48):** one declarative EmoUI tree renders on a
  terminal, a server-rendered page, a macOS/AppKit window, and a GTK 4
  window behind thin per-platform entries, with the browser DOM following
  its own runtime path; the portable core and the pure-Emo backends answer
  byte-for-byte, the composition syntax is identical everywhere, and
  per-platform component libraries share convergent names. The design is
  `docs/emo-ui.md`.
- **M16 — Value-family reclamation (step 49):** landed 2026-10-17 —
  the `c` target reclaims
  the value-semantic kinds as well as the identity cells, so a
  long-running program's arena bytes and identity liveness stay flat
  across renders; array growth becomes linear. Scheduled when the
  2026-10-14 arena-scope spike ruled region reclamation out
  (`spike/arena-scope`, `CHECK.md`). Not a prerequisite for step 48 —
  the native UI backends are built at demo scale with the limit
  documented.
- **M18 — TLS on the `c` target (step 51):** the three existing `net`
  TLS builtins — implemented on the interpreter, the standalone OCaml
  runtime and `typescript` since step 13 — land on the default target,
  the C runtime binding the system OpenSSL/LibreSSL behind
  hand-declared prototypes and IR-keyed conditional linkage, so
  `http`'s `https://` works end-to-end on `c` while a non-TLS build
  never links OpenSSL. Conformance, not surface: the ocaml scheduler
  is the semantic reference. Decisions settled 2026-10-17
  (`CHECK.md`, `plan/step-51-tls-c-target.md`).
- **M21 — The crypto package (step 55):** the portable primitives
  layer beneath every protocol — the SHA-2 and SHA-3 families with
  SHAKE, HMAC, HKDF and PBKDF2, the constant-time compares,
  ChaCha20-Poly1305, AES with GCM and the block modes, and
  Ed25519/X25519 — pure Emo and byte-identical on the five hosted
  targets, the RFC/NIST vectors plus Go-generated companions frozen
  into the goldens so the interop claim is a diff. Its own `rand`
  package carries the OS entropy the pure core cannot conjure. TLS
  stays on the system library (step 51); the broken legacy set
  (DES/RC4/DSA/MD4) is declined outright, with MD5 and SHA-1 behind
  `crypto.legacy` for existing data only; RSA waits on a bignum
  foundation. The plan is `plan/step-55-stdlib-crypto.md`.
- **M22 — File IO on `wasm` (step 56):** the wasm target's host
  boundary grows the file-system syscalls — a syscall stashes its
  answer and the guest copies it out with `fetch` — and the canonical
  host rides the compiler as generated data, so `emo run --target
  wasm` runs an artifact under Node with the bundled host. `file`,
  `os` (the fd/directory half; the process half raises at the call
  naming the capability), and `bufio` resolve and answer byte-for-byte
  alongside the pure packages; the sockets' refusal stands. The plan
  is `plan/step-56-wasm-file-io.md`.
- **M28 — The RocksDB half (step 65):** emo-db's storage half as the
  project-local `emo/rocksdb` binding — a package-carried C shim over
  RocksDB's official C API, keys and values crossing as `Bytes`
  through the C ABI's borrowed byte view (D10), resolved through the
  manifest's `pkg_config` field, and a KV golden (writes, a batch
  commit, a prefix scan, snapshot isolation, close/reopen) run three
  times byte-identical on `c`. The design record is `docs/emo-db.md`;
  the plan is `plan/step-65-emo-db-rocksdb.md`.
- **M29 — The record layer (step 66):** the catalog over its own
  column family, the v0 row encoding (null bitmap, fixed-width and
  length-prefixed values), the rowid inside the insert's WriteBatch,
  and one column family per secondary index; a table-creation, insert,
  and index-scan golden on `c`. The format is
  `plan/step-66-record-layer.md`.
- **M30 — The SQL front-end's DML and DDL (step 67):** the `sql`
  package grows `CREATE TABLE` (the v0 types, `NOT NULL`,
  `PRIMARY KEY`), multi-row `INSERT ... VALUES`, `UPDATE ... SET ...
  [WHERE]`, and `DELETE FROM ... [WHERE]` beside `SELECT`; pure Emo,
  canonical renderings, the SELECT grammar untouched, and the two
  examples' goldens byte-identical on all five hosted targets. The plan
  is `plan/step-67-sql-dml-ddl.md`.
- **M31 — The planner and executor (step 68):** the `emo/engine` package
  over the SQL AST and the record layer — the analyzer's name/type
  resolution, the typed expressions with three-valued NULL logic, the
  scan/filter/project plan (an equality on an indexed column becomes an
  index scan), CREATE TABLE/INSERT/UPDATE/DELETE, the plan text, and
  the PG-shaped error strings; an embedded SQL-in/rows-out golden on
  `c`. The record layer grows `Table.update`/`delete` with index
  maintenance. The plan is `plan/step-68-planner-executor.md`.
- **M32 — Transactions and the session plane (step 69):** BEGIN/COMMIT/
  ROLLBACK over the record layer's `Txn` (one WriteBatch, a
  per-statement snapshot, a pending overlay for read-your-writes, the
  rowid counters published on commit), the engine's session state and
  table locks, and an Emo lock-manager process with a wait-for graph and
  the deadlock abort; a two-session golden shows read committed, the
  write-write block, and the deadlock on `c`. The `sql` package grows
  the three transaction statements. The plan is
  `plan/step-69-transactions-session.md`.
- **M37 — The two-engine proof (step 74):** `htap_demo` seeds a row
  table and a column table (1100 rows, across the block boundary)
  through the engine and serves the wire; psql and the `postgres`
  client both drive a script that reads both engines, carries the row
  table's UPDATE and the column table's INSERT inside one
  BEGIN/COMMIT, and reads the post-commit aggregates — each phase a
  fresh server, pinned byte-for-byte behind the availability probes;
  the corpus gains `column.test` (15 cases: the DDL, the projections,
  the five aggregates, the zero-row rule, and the refusals), and the
  bench gains the column rows (the block scan 304 ms for 10000 rows
  against the row store's 675; the aggregate 142 ms). The plan is
  `plan/step-74-two-engines.md`.
- **M36 — The column executor (step 73):** a column table's SELECT
  routes to the blocks — plain projections and WHERE through the
  shared typed expressions over block-materialized values, and the
  global aggregates COUNT/SUM/AVG/MIN/MAX accumulating over the blocks
  (the `count(*)` fast path sums the block counts without decoding);
  the select list is all plain or all aggregate (`42803` names the
  column otherwise), aggregates are whole select items only,
  UPDATE/DELETE answer the insert-only `0A000`, and INSERT rides the
  column blocks through the same transaction; the plan text shows
  `column scan` and `aggregate`. The plan is
  `plan/step-73-column-executor.md`.
- **M35 — The column format (step 72):** `CREATE TABLE ... STORE =
  COLUMN` in the parser (the canonical rendering spells only the
  written column tail) and the catalog's version-2 table definition
  (a `store` field; a version-1 record reads as row storage); the
  record layer's column half — one column family per column, 1024-row
  blocks (row count, null bitmap, the row encoding's widths), the
  trailing partial block re-read and rewritten inside the transaction,
  the block scan in rowid order, and the reopen's column-family
  verification; no indexes on column tables (the engine and the record
  layer both refuse `PRIMARY KEY` and secondary indexes), and the
  engine's named `0A000` bridge for DML and SELECT until step 73's
  batch executor. The plan is `plan/step-72-column-format.md`.
- **M34 — Conformance and documentation (step 71):** the SQL corpus as
  data — six `.test` files, 126 cases, `statement ok`/`statement
  error`/`query` with pinned tags, rows, and `code: message` lines —
  run against one fresh database by a data-only runner, three runs
  byte-identical through the gate; the bench (`bench/run.sh`, warmup
  plus three timed runs) and the measured table, which found and fixed
  the read-only statement's fsync; the shipped-surface documentation,
  the corrected stale claims, and the arc-two review against the row
  store's actual plug points. The plan is
  `plan/step-71-conformance.md`.
- **M33 — The wire (step 70):** PostgreSQL protocol v3's simple query
  path in a new `emo/wire` package over `net` — startup with the
  SSL/GSSENC refusal and trust authentication, ParameterStatus /
  BackendKeyData / ReadyForQuery, Query with a multi-statement string
  (split by `sql.split` over the lexer's tokens), RowDescription with
  the v0 type OIDs, text-format DataRow, CommandComplete,
  EmptyQueryResponse, and ErrorResponse; one session actor per
  connection over the shared Store with the table locks, and the
  `postgres` client's zero-parameter statements taking libpq's simple
  path. psql and the client are both goldens behind availability
  probes. The engine's lock manager moves into the package
  (`engine.locks`) for the server to share. The plan is
  `plan/step-70-wire.md`.

- **M39 — Text templates (step 78):** the `template` package — text
  with holes rendered from a `json` context, Go `text/template`'s
  mechanism with Emo's own surface, pure Emo over the shared runtimes
  and byte-identical on all five targets. One-shot `render` and the
  parse-once-render-many `Set` (new/with/render); `{{ }}` holes over
  bare dotted paths with bracket accessors; seven ASCII-safe filter
  pipelines (upper/lower/trim/length/join/default/escape_html);
  `{{ if }}`/`{{ else if }}`/`{{ else }}`/`{{ end }}` on "not the zero
  value" truthiness; `{{ for x in e }}` over arrays and objects (one
  name the element, two the index and element — or key and value) with
  `{{ else }}`; `{{ template "name" e? }}` includes with bindings never
  crossing the edge and the depth cap naming the chain; `{{- ` / ` -}}`
  trim markers and `{{! ... }}` comments; strict parse and strict
  render, every failure a `(R.error, reason)` with the byte position.
  No arithmetic, no comparison — the template renders, the program
  computes. The plan is `plan/step-78-stdlib-template.md`.

- **M41 — The standard library: `uuid` (step 80):** the `uuid`
  package — the RFC 9562 identifier as one immutable 16-byte value,
  scoped to Go's standard `uuid` spine and filled in where the RFC
  pins the shape, pure Emo over `crypto` and `rand`, byte-identical
  on all five targets. The value renders itself through the
  `to_string` protocol, answers `to_bytes`/`version`/`variant`/
  `is_nil?`/`is_max?`, and sorts through the RFC 6.11 big-endian
  `compare`; `v4` draws 122 random bits from the OS entropy,
  `v7(now_ms)` takes the Unix time in milliseconds from the caller's
  own clock (`time.now()`) over 74 random bits — raising on
  a negative or 48-bit-overflowing timestamp — and `v3`/`v5` are the
  deterministic name-based doors over `crypto.legacy` with the four
  IANA namespace IDs beside them. `parse` takes exactly the canonical
  36-character form, hex case-insensitive, every rejection naming the
  first offending byte; the braced, urn, and undashed forms are the
  caller's trim, visibly. v1/v2/v6 and a v8 constructor are out,
  named. The plan is `plan/step-80-stdlib-uuid.md`.

- **M42 — The clock and the heartbeat (step 81):** the `time`
  package — the wall clock and the monotonic clock over three runtime
  doors, the calendar, the formatting, and the timing family pure Emo
  over them, byte-identical wherever a golden can pin. A `Time` of UTC
  epoch milliseconds with pure-Emo calendar fields, `mono()` the
  explicit monotonic instrument, durations plain Int64 milliseconds,
  the strict nine-token layout (UTC always), and the seconds-speaking
  family: `sleep` the park, `after` the one-shot, `tick` the calling
  process's never-returning heartbeat. The plan is
  `plan/step-81-stdlib-time.md`.

## Ground rules

- Every step ends with the repo building, `dune test` green, and the step's
  acceptance examples passing. Do not start the next step on a red build.
- `README.md` (repo root) is the design source of truth. Where the README is
  silent on an implementation detail, the step file names a **provisional
  decision**, marked as such; once settled, language-surface decisions move
  into the README and library-level ones into `docs/`. Never silently.
- Pending design decisions live in `CHECK.md`. Steps that depend on an open
  decision list it under "Open design items" — settle it in `CHECK.md` /
  `README.md` *before* implementing that task.
- Strictness first: when in doubt, reject early with a clear diagnostic. No
  auto-fixing, no implicit additions, no silent fallbacks.
- Loop forms landed: C-style `for`/`while` run on the interpreter and every
  target (steps 26–27), keeping guaranteed tail calls (README, Syntax and
  `CHECK.md`). The Go pre-1.22 loop-capture trap is prevented — a `var`
  cannot escape its block, and capturing one in a closure that outlives the
  block is a compile error (README, Syntax).
- Compiler sources live under `src/` as dune libraries; `website/` is the
  docs site and unrelated to the compiler. Acceptance example programs live
  under `examples/` once step 07 creates it.

## Status

| Step | Focus | Status |
|------|-------|--------|
| 01 | Project scaffold & CLI skeleton | done |
| 02 | Lexer | done |
| 03 | Parser — expressions | done |
| 04 | Parser — declarations | done |
| 05 | Interpreter — core values & evaluation | done |
| 06 | Interpreter — classes, enums, interfaces | done |
| 07 | Function groups (`emo` keyword) | done |
| 08 | CLI & diagnostics (`run`, `repl`, `check`) | done |
| 09 | Gradual type checker | done |
| 10 | Structural module system | done |
| 11 | Packages & version resolution | done |
| 12 | Processes & message passing | done |
| 13 | Networking library | done |
| 14 | Native backend | done |
| 15 | Other targets (wasm / TS / BEAM / riscv64) | done — all four targets promoted to their own steps (16–19); the decision trail is recorded in `plan/step-15-other-targets.md` |
| 16 | Wasm target (WasmGC) | done — T16.5's WASI/IO audit closed in favor of refusing `net`/`http`; the socket API is preview2/component-shaped and no reference host supplies it |
| 17 | TypeScript target | done |
| 18 | BEAM target (Core Erlang) | done |
| 19 | RISC-V target (freestanding RV64) | done (T19.1–T19.4; the `%g` float to-string follow-up landed 2026-10-17) |
| 20 | The systems layer (wasm runtime) | done |
| 21 | Wasm runtime: decoder & validator | done |
| 22 | Wasm runtime: interpreter core & spec goldens | done — 25135 runs claimed, 0 pending, 0 failed; a smoke slice rides `dune test` |
| 23 | C target (emit C) | done (close-out recorded; the native → ocaml rename landed; aligned 2026-10-10 — Void foreign returns, `emo_defs.h`, content-keyed caches, cross-module calls and types) |
| 24 | Toolchain distribution & release | done (M7 complete) |
| 25 | Target independence (runtimes decoupled from the host) | done (M8 complete; every runtime embedded, the ocaml target installation-independent) |
| 26 | Loop surface: lexer, parser, checker, interpreter | done |
| 27 | Loops on every target: IR and the six backends | done |
| 28 | Error-handling surface: `R`, binding patterns, raise discipline | done |
| 29 | The stdlib migration: tuples replace raises, package by package | done |
| 30 | Checker strictness: Box typing and cross-module value signatures | done |
| 31 | The standard library: `json` | done on interpreter/ocaml/typescript/c (2026-10-10 on c — the landing flushed the c Bytes-arm guess on gradual receivers and the vtable's `_q`/`?` spelling); wasm, beam wait on their own capability walls |
| 32 | The standard library: `yaml` | done on interpreter/ocaml/typescript/c (2026-10-10 on c — flushed the trampoline's cluster-scope collision); wasm, beam wait on their own capability walls |
| 33 | The standard library: `xml` | done on interpreter/ocaml/typescript/c; the cross-module-types gate resolved (2026-10-10); wasm, beam wait on their own capability walls |
| 34 | The standard library: `os` | done on interpreter/ocaml/c; the browser and bytecode targets refuse the package (no process to fork) |
| 35 | The standard library: `base64` | done on every target — the first package on all five goldens; flushed out the wasm `&&` cast, the wasm zero-length copies, and the beam logical-op/tuple-index/Exception gaps |
| 36 | The standard library: `slog` | done on interpreter/ocaml/c/typescript; wasm, beam waited on `Map` support (attrs are a Map) — the wall fell in step 52 (2026-10-19) and the manifest widened to all five; loggers are values, no state, no clock — the first package whose golden needed zero compiler changes |
| 37 | The standard library: `bufio` | done on interpreter/ocaml/c; the package rides `os`, so wasm/beam/typescript refuse it at resolution like `os` does |
| 38 | The standard library: `sqlite3` | done on c — the first native-binding package: the manifest's `link` field and package-carried C sources land with it; every other target refuses at resolution, the interpreter at run time (E3009) |
| 39 | Compiler and language enablers for plotting | planned |
| 40 | T0 completion: continuous axes and the remaining marks | planned |
| 41 | Figure fidelity: scales, domains, legend, grid, themes, color | planned |
| 42 | Table and channels | planned |
| 43 | T1 dataset charts | planned |
| 44 | Terminal renderer | done — `internal.term.TermRenderer` is the second `Renderer` behind the internal interface (braille cells, ink levels from luminance contrast against the figure background, halftoned fills); `svg` and the new `plot.terminal` walk one figure through one `render`, and `plot_demo` prints four of its figure values both ways, byte-identical on all six paths |
| 45 | PNG renderer | done — `internal.png.PngRenderer` is the third `Renderer` (2 × supersampled scanline rasterizer, the Hershey Simplex stroke font, the package's own DEFLATE, CRC-32, and Adler-32, no host image library); `plot.png(fig)` answers `Bytes` — a `String` cannot carry a PNG on typescript — and `png_demo` pins the file on all six paths |
| 46 | Unit test framework: `emo test` and the `expect_*` builtins | done |
| 47 | The standard library: `csv` | done |
| 48 | EmoUI | done — T48.1–T48.13 landed (portable core, Elm loop, debug, TUI, SSR, macOS and GTK 4 backends, the `term` stdlib package, the native packaging fields, the browser runtime path, its DOM backend, the convergence corpus, and the documentation pass); the settled design is in `README.md`, the evidence in `docs/emo-ui.md`, and the package references under `projects/emo-ui/docs/` |
| 49 | Value-family reclamation | in progress — T49.3 landed (`ArrayBuilder`); T49.1, T49.2, T49.4, and T49.5 open (`spike/arena-scope`, `CHECK.md`) |
| 50 | Cross-target conformance | done — `foreign def` refusal, snapshot `send`, and the raising child process settled (`CHECK.md`) |
| 51 | TLS on the `c` target | done — the three `net` TLS builtins run on the C runtime against the machine's OpenSSL/LibreSSL behind `EMO_HAS_TLS` conditional linkage; `https_roundtrip` byte-identical interp-to-c; the macOS-linkage premise the settle predates corrected in `CHECK.md` |
| 52 | `Map` on `wasm` and `beam` (M19) | done — the wasm `$vmap` and the beam pdict-backed map helpers land with their lowerings and the send snapshot; `examples/map` and `slog_demo` ride the goldens on all five targets, and `slog`'s manifest widens to all five; `riscv64` stays the one target that refuses `Map` |
| 53 | The `math` package: the transcendental surface, complex arithmetic, the FFT, BLAS1, the dense solver, and the special functions | done — the pure functions are fixed-order series with their coefficients written into the source, byte-identical on all five targets (`erf`/`erfc`/`tgamma`/`lgamma` included); the ELEFUNT-derived battery in `examples/math_elefunt` prints each function's max and rms bit loss and its `expected.txt` is the accuracy record; the native fast lane is step 54 |
| 54 | The native fast lane: the `fastmath` and `quad` packages | done — `fastmath` carries `math`'s whole scalar surface as host-libm bindings on `c`/`ocaml` (the four unreleased twins moved out of `math` unsuffixed, so `math` stays pure and byte-identical), pinned by its target list (E5007 at load elsewhere, E3009 under the interpreter), with the natives' ELEFUNT battery in `examples/fastmath_elefunt` printing verdicts against stated loss budgets; `quad` vendors f2c-translated QUADPACK (`dqags`/`dqagi` chains, `d1mach` as literals) behind the C shim's workspace and the one FFI shape — a single-method-interface integrand — mapping the ier codes onto the `(R.ok, …)`/`(R.error, …)` split; `examples/quad_demo` pins the c golden |
| 55 | The standard library: `crypto` and `rand` | done — T55.1 landed (the word layer and the package skeleton; `>>` measured arithmetic and `<<` wrapping, 29 probe vectors byte-identical interpreter-to-c, and the c-target corner found: a module-const wiring answers dynamic, and the dynamic world refuses bitwise — internal calls go through the direct qualified path); T55.2 landed (the SHA-2 family over `crypto.sha2` and `internal/sha256.emo`, the hasher's state in one `Bytes` box, `crypto.hex_encode`/`hex_decode`, the RFC 6234 suite with Go-generated companions frozen as the golden, the million-`a` vector c-only); T55.3 landed (the 64-bit family in `internal/sha512.emo` with spec-derived constants, the `Wide` class, SHA-1/MD5 behind `crypto.legacy` one-shot only, the golden at 98 Go-agreed vectors, and the OCaml emitter's unparenthesized negative-Int64-literal bug flushed and fixed); T55.4 landed (the `Hash` interface in `crypto.hash` that `Digest` and `Wide` answer by shape, HMAC over the SHA-2 family one-shot in `internal/hmac.emo` with the RFC's key preparation, the golden at 134 Go-agreed vectors riding RFC 4231); T55.5 landed (HKDF and PBKDF2 in `crypto.kdf` over `internal/kdf.emo` — extract documented as the HMAC call it is, the 255-hash-length cap and the iteration floor raising, the count a plain argument, the golden at 145 Go-agreed lines with RFC 5869's and RFC 7914's vectors, and `examples/crypto_kdf` c-only pinning the 4096-iteration classic); T55.6 landed (SHA-3 and SHAKE in `crypto.sha3` over `internal/keccak.emo` — the sponge after the Keccak team's compact reference, no tables, one-shot; the golden at 175 Go-agreed lines; two language walls flushed: the gradual-type constructor rule behind six parameterized door helpers, and E3005's shift-count proof behind the word layer's narrowing guards); T55.7 landed (the `rand` package — `rand_bytes` through the runtime-impl table on the interpreter, ocaml, `c`, typescript, and beam, wasm refused by the target list; `rand.bytes` answering `(R, Bytes)` and the one-shot HMAC-DRBG `rand.drbg_sha256` answering `Bytes` over crypto's first byte doors, `examples/rand_demo` byte-identical on all five lists; found, not fixed in `CHECK.md`: the crypto String surface is unsound on typescript, the Bytes doors its migration's proven shape); T55.8 landed (the decision did: every door of `crypto` now takes and answers `Bytes`, the String plumbing removed not doubled, every golden byte-identical before and after, and `crypto_hash` joined the typescript golden list passing where it had crashed); T55.9 landed (ChaCha20-Poly1305 in `crypto.cipher` — the stream, the Poly1305 MAC in Donna's 26-bit limbs, and the AEAD pair over Bytes; `examples/crypto_aead` pins the RFC vectors, the forgeries, and the boundary sizes against a self-checked Python reference on all five lists; the typescript `get_u32_le` signed-read bug flushed and fixed in `CHECK.md`); T55.10 landed (AES and GCM in `crypto.cipher` — the block cipher S-box byte-oriented with its tables derived and proven through the FIPS 197 KATs, CBC/CTR/GCM over Bytes, `examples/crypto_aead` growing the AES panel with all fifty Go lines agreeing on five lists); T55.11 landed (Ed25519 and X25519 — the limb width measured, no 128-bit product, so ten signed `Int64` limbs in radix 2^26/2^25 in `internal/fe25519.emo`, the limb layer mirrored and fuzzed in Python first; the curve, the scalars modulo L, and the scheme in `internal/ed25519.emo`, the ladder in `internal/x25519.emo`; `crypto.sign` and `crypto.ecdh` over Bytes; `examples/crypto_sign` and `examples/crypto_ecdh` pin the RFC vectors, the rejections, and the low-order refusal against Go's `ed25519`/`ecdh` on five lists, the sweep and the thousand iterations c-only; the typescript emitter's reserved-word gap flushed and fixed in `CHECK.md`); T55.12 landed (`docs/stdlib/crypto.md` and `docs/stdlib/rand.md`, EN and zh-CN — the full surface, the error split per function, the constant-time discipline with each target's honest status, the legacy warning — the `docs/stdlib.md` rows and sections, `crypto_hash` onto the beam list and the four crypto goldens onto the wasm list so every declared target is golden-exercised, SHAKE's negative length raising with the package's message, the interpreter costs measured); M21 complete (`plan/step-55-stdlib-crypto.md`) |
| 56 | File IO on the wasm target (and the canonical host) | done — the import table grows the file-system syscalls (`file_read`/`file_write` plus the eleven `os_*` calls, each answering `(tag, …)` with the payload waiting for the guest's `fetch`, the reasons byte-identical with the c runtime's), the canonical host rides the compiler as generated data and `emo run --target wasm` runs under it; `file`, `os` (the fd/directory half), and `bufio` declare `wasm` with `os_fs_demo` byte-identical on interpreter/c/wasm while the process half raises at the call naming the capability (`os_demo`, which forks, stays a c golden); two wasm runtime bugs found and fixed — the bump cursor never moved (the copy loop's exit branch jumped past the advance) and the grow delta paged the length alone (out of bounds past the first page boundary, `plot_demo`'s second SVG caught it) — and the bump base moved to 65536 so page 0 stays the host's; M22 complete (`plan/step-56-wasm-file-io.md`) |
| 57 | The `httpd` package — the server half of HTTP | done — the pure parser (`parse_head`: token header names canonicalized, the Host rule, first-occurrence-wins queries, percent-decoding honest about the String boundary) and the connection half (keep-alive one process per connection, Content-Length and chunked bodies under the 413 limit, `100-continue`, responses always carrying `Content-Length` with HEAD/204/304 stripped, the `Server` handle's stop/wait draining through a counter process, `server_options` with the with_* builders plus the injected `with_date` clock); the Router (patterns parse once at registration and conflict-raise, `{name}`/`{path...}` feeding `req.params`, literal-over-wildcard-over-rest precedence, 405 with `Allow`, 301 cleanup and slash redirects, GET answering HEAD) through `serve_routes`; the goldens flushed three compiler bugs — the IR dropped arguments on calls naming a top-level const holding a callable, the c target's `-O2` strict aliasing crashed the value world's word views (now built `-fno-strict-aliasing`), and two ts gaps (a parked accept surviving its listener's close; a receive's value return escaping `E.receive` to the process wrapper) — with the harness flake on the wire example's c binary named, not rooted; `http` slimmed back to client-only with the bench and roundtrip examples migrated, docs EN+zh for both packages; M23 complete (`plan/step-57-httpd.md`) |
| 62 | The standard library: `postgres` | landed — the standard library's second native-binding package and its first wire-protocol database client: `foreign def`s against a package-carried shim over libpq, resolved through the manifest's `pkg_config` field; `$1`-style `Param` parameters (text/i64/f64/bool/none) through `PQexecParams`, `Rows` with typed checked accessors and a by-name lookup, the `net` error split (a down server and a broken constraint answer `(R.error, reason)` with the server's message and SQLSTATE; contract violations raise); the FFI's no-array wall bridged by a shim-side staging with a bound-mask tripwire, the no-tuple-return wall by `_ok`/read pairs, every C status numeral normalized in the shim; `postgres_demo` rides a temp table against a live server, three runs byte-identical, joining `c_goldens` behind the `postgres_available` probe (pkg-config resolution with the Homebrew-keg fallback, a tiny `-lpq` link, one TCP connect); E3009 and E5007 verified live; docs EN+zh, with the found-and-fixed `sqlite3` table row (`plan/step-62-postgres.md`) |
| 63 | The Emo shell: `emosh` | landed — `projects/emo-shell`, the general-purpose command interpreter written in Emo over the grown `os` surface: `dup2`/`execvp`/`isatty`/`argv` and the environment and signal halves land in `os` in place at 0.1.0 (the net+TLS precedent; three example locks re-resolved), with reasons byte-identical across the interpreter and the c runtime by construction (the getenv miss hand-written, setenv named over the OCaml putenv, the signal range guard ahead of the call) and the generated c main capturing argc/argv through `emo_args_set`; the shell lexes words into literal and expandable parts (a bare run one part, so `$` reaches its name), expands `$var`/`${var}`/`$?`/`$0`/the leading tilde with no IFS re-splitting, parses lines into items (pipeline + connector) strict about empty stages and loose exactly where the classics are, walks `;`/`&&`/`||` with the carried status, forks pipelines per stage wired through pipes and `dup2`, opens `<`/`>`/`>>` onto the child, answers the eight builtins (`cd` `pwd` `echo` `exit` `export` `unset` `true` `false`), folds exit statuses into the kernel's low byte, and lives by the ignored-interrupt discipline — the shell ignores sig_pipe everywhere and sig_int/sig_quit interactively, the fork child resets all three before its exec; every byte through raw `os.write` (never a buffered stdout, so a fork child's output survives `_exit` and the two targets compare byte for byte), errors as `(R.error, reason)` values (the shell has no catch to survive), six fixture scripts with pinned merged output and exit statuses byte-identical on the ocaml and c targets in one Alcotest case (`emosh_golden`); docs EN+zh (`emosh-guide.md`, the grown `os.md`), TASKS M26/Step 63, CHECK.md's decision record; found-and-fixed: the byte-per-part lexer hiding `$names`, the line-start refusal eating `> log`, and the `pwd` golden pinning the sandbox's cwd (`plan/step-63-emosh.md`) |
| 64 | Browser automation: the `websocket` and `playwright` packages | landed — RFC 6455 as a stdlib package over `net` (client dial with accept verification reading the answer's headers to the blank line, server accept checking upgrade/version/key, one text message per exchange, masking by role, pings answered, closes answered with the socket taken down, fragmented receives joined past 4096 pieces), then the Playwright client speaking the driver's channel protocol to `playwright run-server` through those frames — the pre-launched-browser shape (`denyLaunch`), `?browser=` selection, the root-channel initialize handshake, and the core doors (goto answering a PageResponse tree, click/fill/press on the main frame, title/content, text_content's null `Text`, screenshot's base64 into `Bytes`), driver refusals as `(R.error, "playwright: " + text)` with the dispatcher's wrapping unwrapped; both demos carry their own counterparty so the goldens need no browser and no Node — byte-identical on the interpreter and the `c` target; found and fixed: the c backend's reserved-word method lookup (`Page.goto` the first carrier), found-not-fixed: the json package's per-character escape-length recursion riding past the c fiber stack at 120000 chars (`plan/step-64-playwright.md`) |
| 65 | emo-db's RocksDB half | landed — `projects/emo-db/` with the project-local `emo/rocksdb` binding: a package-carried C shim over the official C API (`pkg_config = ["rocksdb"]`), open/close, column families (staged names at open, lookup, create, list), get/put/delete, WriteBatch, iterators, and snapshots bundling their read options; the C ABI's `Bytes` borrowed view (D10) carries arbitrary binary keys and values, with reads filling caller-owned out-parameters and `Bytes` returns refused; `(R, reason)` for storage failures, missing keys as an empty result, contract violations raising, and Db-level lifetime counters refusing a close under live batches/snapshots/iterators; the KV golden runs three times byte-identical through `projects/emo-db/check.sh` (text and embedded-NUL values, an atomic batch, a prefix scan, snapshot isolation, close/reopen), with E3009 and E5007 verified live; docs EN+zh (`plan/step-65-emo-db-rocksdb.md`) |
| 66 | emo-db's record layer | landed — the `emo/record` package over the binding: the catalog CF (tables/columns/types/indexes by oid), the v0 row encoding (null bitmap, 4-byte INTEGER, 8-byte BIGINT/REAL/DOUBLE, boolean, length-prefixed TEXT/VARCHAR/BYTEA), the rowid inside the insert's WriteBatch, and one CF per secondary index (`idx_<oid>`, value-marker + rowid keys, equality-prefix scans); `rocksdb.list_families` reopens a database with index families, the catalog verifies every index CF, and the record demo's golden covers every type, a duplicate unique key, three index scans, and a reopen (`plan/step-66-record-layer.md`) |
| 67 | The SQL front-end's DML and DDL | landed — the `sql` package grows `CREATE TABLE` (the v0 types, column-level `NOT NULL`/`PRIMARY KEY`), multi-row `INSERT ... VALUES` with an optional column list, `UPDATE ... SET ... [WHERE]`, and `DELETE FROM ... [WHERE]` beside `SELECT`: one class per statement behind `Stmt`, canonical `to_string()` renderings, the SELECT grammar untouched, and the parser validates the statement shape (duplicate columns/assignments, row widths, a positive `VARCHAR(n)`, the unsupported tails by name); `sql_demo` and `sql_edge` are byte-identical on the interpreter and all five hosted targets, with both locks re-resolved (`plan/step-67-sql-dml-ddl.md`) |
| 68 | The planner and executor | landed — the `emo/engine` package over `emo/sql` and `emo/record`: the analyzer (table/alias/column resolution, the v0 type mapping, numeric/text conformance, the PG-shaped `code: message` failures), typed expressions with SQL's three-valued NULL logic (comparisons, AND/OR, arithmetic, `||`, IS/IN/BETWEEN/LIKE/CASE), the scan/filter/project plan with an equality index scan, CREATE TABLE (the v0 types, the primary-key index), INSERT (column list, NULL fill, coercion, not-null/duplicate mapping), and UPDATE/DELETE (the record layer's new update/delete, index entries rewritten in one batch); the embedded engine demo pins SQL text in and rows out with the plan tree on `c` (`plan/step-68-planner-executor.md`) |
| 69 | Transactions and the session plane | landed — the `sql` package's `BEGIN`/`COMMIT`/`ROLLBACK`; the record layer's `Txn` (one WriteBatch, a per-statement snapshot, the pending overlay, the rowid counters, the `Table` tx methods, commit/rollback); the engine's transaction state, autocommit path, `LockClient`, and table-level locks; the lock-manager process (owners, FIFO waiters, the wait-for graph, the deadlock abort, the release grant); the two-session `txn_demo` (read committed, write-write block, deadlock) three runs byte-identical on `c` (`plan/step-69-transactions-session.md`) |
| 70 | The wire | landed — PostgreSQL protocol v3's simple query path in `emo/wire`: startup (SSLRequest/GSSENCRequest answered `N`, trust AuthenticationOk), the ParameterStatus set, BackendKeyData, ReadyForQuery, Query with multi-statement strings split by the new `sql.split` over the lexer's tokens, RowDescription with the v0 OIDs, text-format DataRow (booleans `t`/`f`, BYTEA `\x` hex, NULL -1), CommandComplete, EmptyQueryResponse, and ErrorResponse; one session actor per connection over the shared Store, the lock manager moved to `engine.locks` and attached through `RemoteLocks`, `Result.types` carrying the projection types; `wire_demo` (ephemeral port through a ready file, a max-connection stop) and `wire_client` (libpq's zero-parameter `PQexec` path through the standard `postgres` package) pin psql's multi-statement script, the error stop, the client's rows and error, byte-identical across three `check.sh` runs; also the BEAM emitter's `__inst_recv` temp fix, found by the new `sql_demo` loop (`plan/step-70-wire.md`) |
| 71 | Conformance and documentation | landed — the SQL corpus in the SQLLogicTest spirit: six files, 126 cases (`statement ok` with a pinned tag, `statement error` with a pinned `code: message` line, `query` with pinned rows rendered canonically) over one fresh database per run, executed by the data-only `corpus_runner` with per-file counts and collected failures, three runs byte-identical through `projects/emo-db/check.sh` (59 checks); the bench (`bench.emo` modes, `bench/run.sh` timing with one warmup and three timed runs) and `bench/results.md`'s measured table; the measurement found and fixed the read-only statement's WAL fsync (a write-less transaction closes without a batch write) and the corpus found and fixed the DDL-in-transaction refusal leaving the block open; the shipped-surface and measured sections, the corrected stale claims, and the arc-two review of the row store's actual plug points (`plan/step-71-conformance.md`) |
| 72 | The column format | landed — `sql`'s `StoreKind` and the `CREATE TABLE ... STORE = COLUMN` tail (row renders nothing, column renders verbatim, `STORE = TEXT` refuses by name), the catalog's version-2 table definition with the `store` field (a version-1 record decodes as row storage), the record layer's `Storage`/`TableMeta.store`, `create_table_store` refusing column indexes and a primary column, one column family per column (`col_<oid>`), the 1024-row block encoding (row count, null bitmap, the row encoding's widths), `insert_column_tx` rewriting the trailing block through the transaction, `scan_column_tx` walking blocks in rowid order, the reopen's column-family verification, the row path's named guards, the engine's DDL mapping and the `0A000` bridge, the `column_demo` golden (1030 rows across the block boundary, reopen, refusals) three runs byte-identical on `c` through the gate (66 checks), and the encoding-order bug the golden caught on its first run (`plan/step-72-column-format.md`) |
| 73 | The column executor | landed — the record layer's `scan_column_batches` (block id + per-column value arrays) and `column_block_counts` (row counts without decoding), `scan_column_tx` rebuilt on the batches; the engine's routing (SELECT branches to `select_column`, INSERT branches to `insert_column_tx`), the insert-only refusals, the `PColScan`/`PColAggregate` plan nodes, and the aggregate machinery (`classify_select` with the `42803` mixing error naming the column, `resolve_aggregate` with the alias/name rule and the type mapping — COUNT bigint, SUM bigint/double by the argument, AVG double, MIN/MAX the argument's type, `DISTINCT` aggregates refused, zero-row sums NULL — and `AggState` stepping per row and answering); the `count(*)`-only no-WHERE fast path; the engine demo's column section grew to the executor's cases (scan, filter, the five aggregates, the mixing and type errors, the insert-only refusals, the reopen) three runs byte-identical on `c` through the gate (66 checks) (`plan/step-73-column-executor.md`) |
| 74 | The two-engine proof | landed — `htap_demo` (the seeding server: `items` a row table, `cold_items` a column table with 1100 rows across the block boundary, both seeded through the engine, then the wire served exactly as wire_demo) and `htap_client` (the standard `postgres` package reading both engines, then one BEGIN/COMMIT carrying the row UPDATE and the column INSERT, then the post-commit reads); the gate's two-engine phases pinned byte-for-byte behind the psql/libpq probes (psql: the seeded aggregates `1100|605550|1.0|row-999`, the cross-engine transaction `BEGIN/UPDATE 1/INSERT 0 1/COMMIT`, and the post-commit `1101|606651`); the corpus's `column.test` (15 cases: the DDL, the projection and filtered projection, the five aggregates, the zero-row rule `0|NULL`, the mixing/type/DISTINCT/star/insert-only/primary-key refusals) lifting the corpus to 141 cases; the bench's column modes (`column-seed`, `column-scan`, `column-agg`) and the measured rows (the block scan 304 ms / 32895 rows per second, the aggregate 142 ms / 70423 rows per second) (`plan/step-74-two-engines.md`) |
| 77 | WASI preview1 | landed — the built-in host answers `wasi_snapshot_preview1`'s twelve-function subset (args/environ/proc_exit/fd_write/fd_close/fd_seek/fd_fdstat_get/random_get/clock_time_get ENOSYS/sched_yield), everything else link-refusing by name, signatures checked (clock_time_get's i64 precision the one non-i32); resolution explicit table → wasi → register → spectest; the CLI's extra arguments ride the wasi argv and proc_exit's code maps to the exit code, with a module's stdout surviving its own exit (the embedded runner split into `run_embedded_deps_out`, verdict and partial stdout); random_get honest through the `rand` package (the package's first dep); fixtures pin errno numbering, the iovec walk, the argv encoding, and the refusals; the live check runs real `rustc --target wasm32-wasip1` modules — hello world, HashMap seeding, `process::exit(7)` — through `emo wasm run`; found-and-fixed: dune's parallel fixture rules raced the shared package cache (materialize now writes through a per-process temp with an atomic rename and one self-healing retry, and each fixture action pins EMO_CACHE_DIR to a sandbox-local directory); the `emo` host module deferred with the earned-place argument (`plan/step-77-wasi.md`) |
| 78 | The standard library: `template` | landed — text with holes rendered from a `json` context: Go `text/template`'s mechanism, Emo's own surface, pure Emo over the shared runtimes; one-shot `render` and the parse-once-render-many `Set` (new/with/render, redefinition refusing), bare dotted paths with bracket accessors over nearest-binding-then-root resolution, seven ASCII-safe filters in pipelines (upper/lower/trim/length/join/default/escape_html), if/else-if/else chains on "not the zero value" truthiness, `for` over arrays and objects (one name the element, two the index and element — or key and value) with `else`, `template` includes with bindings never crossing the edge and the depth cap naming the chain, `{{- ` / ` -}}` trim markers and `{{! }}` comments; parse and render both strict, every failure an `(R.error, reason)` with the byte position, and the value split refusing what has no text (a null hole, a container hole); `template_demo` and `template_edge` byte-identical on all five targets; the goldens flushed two compiler bugs — the IR's module-level def mangle skipped `sanitize_ident` (a def name's `?` lowered raw into TypeScript/OCaml identifiers), and the BEAM emitter's threaded-chain case registered a branch's pattern bindings before the per-branch save (a sibling arm's bindings leaked into a later continuation's live set, dying as erlc `unbound variable`) — and settled the bare-`}}` question: outside an action it is text, not an error (`plan/step-78-stdlib-template.md`) |
| 79 | The repl's line editor | landed — the interactive session edits its input with the vendored upstream linenoise (BSD-2, pinned at `a473823d`, two marked patches: the edit session's temporary history entry pops on Ctrl-C and end-of-input as ENTER pops it — upstream leaks one empty entry per Ctrl-C into the history file — and the blocking read's verdict errno is captured before the stop's cleanup and restored after, that cleanup's `isatty`/`tcsetattr` probe clobbering the verdict otherwise), compiled into the CLI through dune's `foreign_stubs` behind the `emo_linenoise` binding module whose stubs follow OCaml's mixed-variant encoding (constants and payload constructors numbered independently — the first global numbering read `Interrupted` as `End_of_input` and made `Ok ()` a read through address −7); the input seam carries the prompt text and answers `Line`/`Aborted`/`Eof`, `unbalanced` shares its bracket count with the continuation prompt (two spaces per open `{`/`(`/`[`, plain dots for an unlexable pending source), and the editor takes the seat only when stdin and stdout are both terminals — pipes, redirects, and the tests keep the plain path byte for byte; the history rides per line (1000 entries), loaded and saved at the session's edges to `EMO_STATE_DIR/repl-history` else `XDG_STATE_HOME/emo/repl-history` else `$HOME/.local/state/emo/repl-history` (unreadable/unwritable warns on stderr, missing says nothing, no home means no file), every non-empty line added as typed; Ctrl-C abandons the pending input and the session survives; the tests drive the real C editor over a pipe through upstream's `LINENOISE_ASSUME_TTY` hook — the typed line, the up-arrow recall, the leak-free interrupt, the input's end, and a two-session persistence round-trip; the live pty run on a real terminal pinned the indented continuation prompts, the Ctrl-C abandon, and the cross-process recall; TAB completion deliberately out (the callback rides the binding; what completes is a design of its own) (`plan/step-79-repl-linenoise.md`) |
| 81 | The standard library: `time` | landed — the language's clock arrives as the standard library's `time` package over three runtime doors (`time_now_ms`, `time_mono_ns`, `time_sleep_ms`), the timing family pure Emo over them: a `Time` of UTC epoch milliseconds whose calendar fields compute in pure Emo (Hinnant's civil arithmetic, floor division everywhere, byte-identical on every target), `mono()` the explicit monotonic instrument, the strict nine-token layout formatting (UTC always, a token letter that opens no complete token raising naming the byte, `format_iso`/`format_http` the presets), durations as plain Int64 milliseconds with the conversion family playing the constants' role, and the seconds-speaking timing family (`sleep` the exact-ish park, `after` the scheduled one-shot in its own process, `tick` the calling process's never-returning heartbeat whose block's `halt()` is the stop); the doors ride the interpreter and both OCaml schedulers (a `Sleep` effect on the IO deadlines' timer lists), the C runtime (a sleeper field beside the fd park, send never waking it), the wasm host (the clock half as two imports, the timing half raising at the call), the TypeScript hosts (Node and browser), and BEAM (`os:system_time`, `erlang:monotonic_time`, `timer:sleep`); the goldens flushed a compiler-structure gap and four emitter bugs — the IR's Void-body exit positions lowered a bare trailing call as an Effect, invisible to every backend's tail machinery (the lowering now turns it into the Return it is, with the C emitter's Void return path emitting its expression without re-pooling the answer's own claim, and the interpreter's frame threading tailness through the statement walk), the c backend's Void-return discard pooling the claim twice (emosh segfaulted on a doubly-released builder cell), the c backend's closure capture never walking a `Send` statement's operands (the heartbeat's `owner <- ...` capture now lands), the TS emitter's `receive` statement carrying no trailing `;` (a following `(`-opening statement parsed as a call), and the BEAM emitter learned that Core Erlang has no wildcard (two `_` in one pattern now lower as distinct fresh variables); stale "the language has no clock" stances updated to name the owner (`plan/step-81-stdlib-time.md`) |
| 76 | `emo wasm run`: the CLI rung | landed — the CLI executes a `.wasm` artifact through the embedded driver (the compiler never linking the runtime): the artifact's absolute path rides in as a host-injected binding, the driver reads it through `file` and loads it through `wasm` both shipped in the binary, instantiates (the start function runs), and walks the entry ladder (`_start`, then `main`, then the one-line summary for a module naming neither); results in the runtime's `value : kind` format, every failure the reason on stderr with exit 1; `run_embedded` generalized to `run_embedded_deps` (the publish/login paths delegating unchanged), the embedded scratch projects' lockfile notice quieted; six tests in `test/emo_cli`'s `wasm_run` group, artifacts as hex decoded in-test (no blob in the repository); docs EN+zh (`plan/step-76-wasm-cli.md`) |
| 75 | The wasm package: the execution surface and the host interface | landed — the Emo-written runtime moves into the bundled registry as the `wasm` stdlib package with its execution layer on the root (`load`/`instantiate`/`call`/`get_global`/`read_memory`/`write_memory`/`register_instance`/`describe`, the value constructors and `as_*` accessors over the `(kind, bits)` model) over the R error split; the host-import table of `(module, name, fn)` triples with the uniform closure signature resolves ahead of the register namespace and the built-in `spectest` host and refuses an entry naming no import; the c backend grows module-level `var` (static cells, pooled-claim reads, the write-barrier assign, declaration-order init at the root entry) because the interpreter's dep-check universe resolves against `c` — all five fixtures and the demo golden byte-identical on the interpreter and the c target, the whole repo's runtest green, the manifest honestly claiming `ocaml` and `c`; the package reference at `docs/stdlib/wasm.md` EN+zh, the temp notes retired, and `examples/wasm_demo` riding the committed-lockfile suite; rung one of the M35 ladder (73 the CLI's `emo wasm run`, 74 the `emo` host module / WASI) (`plan/step-75-wasm-package.md`) |
| 80 | The standard library: `uuid` | landed — the `uuid` package: the RFC 9562 identifier as one immutable 16-byte `Uuid` value rendering itself through the `to_string` protocol, answering `to_bytes`/`version`/`variant`/`is_nil?`/`is_max?` and sorting through the RFC 6.11 big-endian `compare`; `v4` drawing 122 random bits over `rand.bytes`, `v7(now_ms)` taking the Unix time in milliseconds from the caller's own clock (`time.now()`) over 74 random bits with a negative or 48-bit-overflowing timestamp raising, and `v3`/`v5` the deterministic name-based doors over `crypto.legacy` with the four IANA namespace IDs of Table 3 beside them; `parse` taking exactly the canonical 36-character hex-and-dash form, case-insensitive on the digits, every rejection naming the first offending byte, and `from_bytes` refusing a length other than 16; scoped to Go's standard `uuid` spine with the name-based versions and the introspection pair filled in where the RFC pins the shape; v1/v2/v6 and a v8 constructor out, named; `uuid_demo` riding the RFC's Figure 1 and Appendix A vectors (verified against Python's standard implementation) structure-only on the random doors, byte-identical on the interpreter, c, typescript, wasm, and beam lists (`plan/step-80-stdlib-uuid.md`) |

The deep-C-FFI assessment (`plan/hosted-native-ffi.md`) precedes step 23; it is a design record, not a numbered step.
