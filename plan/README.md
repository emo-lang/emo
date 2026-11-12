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

The deep-C-FFI assessment (`plan/hosted-native-ffi.md`) precedes step 23; it is a design record, not a numbered step.
