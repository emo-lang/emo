# Step 65 — emo-db's RocksDB half

**Milestone:** M28 · **Prereq:** steps 38, 62 (the native-binding shape)
and step 64's branch base · **Status:** landed 2026-11-12 (code, golden,
docs; the suite rides the next requested `dune runtest`)

## Why this step exists

emo-db's design record (`docs/emo-db.md`, D1–D10) puts the storage layer
under RocksDB and starts the ladder with the KV half: before a catalog,
a row encoding, a planner, or a wire can exist, the project needs a
proven way to open a database, write and read bytes, commit a batch,
scan, take a snapshot, and use column families — with the C side
carrying no locks, because the scheduler serializes every call.

The step's other half is a language gap the design record did not name:
the `sqlite3`/`postgres` bindings cross `String` as a NUL-terminated
`char *`, so they truncate binary data at the first zero byte. RocksDB's
keys and values are arbitrary bytes — M29's null bitmap and fixed-width
row fields are full of NULs — so D10 lands here: `Bytes` crosses the C
ABI as a borrowed view, argument-only, with reads filling a caller-owned
out-parameter.

## Decisions settled here (the trail)

- **D10 — the byte view.** A `Bytes` foreign parameter crosses as
  `emo_bytes_view { unsigned char *data; int64_t len; }`: a borrow of the
  cell's inline bytes, valid for the call only; the C side never retains
  the pointer. A `Bytes` **return** stays refused (E4200 names the
  out-parameter answer), because ownership of a C buffer cannot cross a
  generic ABI. A read asks the length first and then copies into a
  `Bytes` the Emo side allocated, so the bytes' owner is always Emo. Only
  the `c` target admits it; the interpreter keeps E3009 and every other
  target keeps its marshaling tier.
- **The package is project-local, not a stdlib package.** It lives at
  `projects/emo-db/rocksdb/` as `emo/rocksdb`, `targets = ["c"]`,
  `pkg_config = ["rocksdb"]`. `pkg_config`, not `link` (sqlite3's field):
  RocksDB's headers live under a prefix `cc` does not search by default,
  so the field must answer both the include path and `-lrocksdb` — the
  `postgres` precedent.
- **`(R, reason)` for storage failures, not sqlite3's raise.** A
  database server must turn a disk or corruption failure into an error
  response, not end the process; the `postgres` split is the right one.
  A missing key is a value, not an error: `get` answers an empty array
  (absent) or a one-element array (present) — the sql package's 0-or-1
  reading. Contract violations raise: touching a closed database, using a
  handle after its owner closed, reading an invalid iterator, mixing a
  batch with another database's column family.
- **Writes answer the resource, not a fabricated count.** `put`/`delete`
  answer `(R.ok, cf)` and `batch.put`/`batch.write` answer the batch —
  the codebase's "success with no payload" idiom (`websocket.send_text`,
  `playwright.close`), since RocksDB reports no affected-row count.
- **Column families are staged at open and owned by the Db.** A foreign
  def cannot take an array, so names arrive through `cfs_new`/`cfs_add`
  (the postgres staging precedent). `default` is required — RocksDB
  demands every existing family named at open — and a list without it is
  a loud failure. The shim's wrapper owns the handles and destroys them
  at close; `cf_create` grows the table, `cf_list` reads it.
- **Reads are two-pass, and the shim stays stateless.** `get_len` does a
  real get and frees it; `get_into` repeats the lookup and copies into the
  caller's buffer. The block cache makes the second lookup cheap, and the
  shim never pins a RocksDB-owned buffer between calls — no hidden
  lifetime, no ownership transfer. M34 measures; if the duplicate lookup
  ever matters, the pinned-slot alternative is stated here as the next
  shape.
- **A snapshot bundles its read options.** `rocksdb_snapshot_t` and the
  `rocksdb_readoptions_t` naming it live in one shim struct, so a read at
  a snapshot is one handle and no per-read option allocation. Iterators
  reuse the bundle's options; the facade's Snapshot refuses to close
  while an iterator made from it is live.
- **Lifetime counters at the Db.** A phantom-free `rocksdb_close` is not
  observable before the crash, so the facade counts open batches,
  snapshots, and iterators and refuses `Db.close` while one is live —
  strictness instead of a use-after-free. Column families themselves are
  not counted: they own no shim memory beyond the Db's table, and any use
  after close raises through the Db's flag.
- **The demo's bytes are the proof.** The golden's output prints keys and
  values in hex and includes a four-byte value `00 01 ff 41`; a
  NUL-truncating crossing would answer `bytes=0` or `bytes=1`, not
  `bytes=4 value=0001ff41`. The demo also shows the batch's three
  effects, the prefix scan stopping at `other:1`, a snapshot answering
  the old value while the latest read answers the new one, and a reopen
  finding both the bytes and the family names.
- **The gate fails loudly without RocksDB.** Unlike the postgres golden,
  which skips when no server answers, the binding's gate cannot verify
  anything without the library; a missing `rocksdb.pc` or a failed link
  prints the install line and exits 1. The pkg-config resolution keeps the
  Homebrew-keg fallback (the postgres probe's escape).

## Tasks

- [x] **T65.1** — D10 in the design record EN+zh (D1's binding
      sentence, the architecture's storage item, the two open items, the
      M28 ladder row); the wording is the contract the rest implements.
- [x] **T65.2** — the runtime's byte view: `emo_bytes_view` and
      `emo_bytes_view_build` in `emo_c_runtime.h`/`.c` (the cell's inline
      bytes plus its length, borrowed for the call).
- [x] **T65.3** — the checker: `Bytes` a `foreign def` parameter on `c`
      only, a return refused with the out-parameter message, shape fields
      still refused; four `bytes_ffi` cases in `emo_check_test.ml`.
- [x] **T65.4** — the emitter: `emo_bytes_view` in `foreign_c_type`, the
      call-site `emo_bytes_view_build`, the result-position guard.
- [x] **T65.5** — `docs/intro/native-builds.md` + zh: the FFI tier names
      `Int64`, `Void` returns, shapes, callbacks, and `Bytes`.
- [x] **T65.6** — the binding skeleton, open/close, and column families:
      `package.emo`, `internal/ffi.emo`, `internal/reason.emo`, the
      shim's wrapper/error buffer and open/close/CF functions, the
      `Db`/`Cf` facade with the `(R, reason)` split.
- [x] **T65.7** — values: put/get_len/get_into/delete, the two-pass read,
      the 0-or-1 `get`, the `(R, reason)` split; found on the way: a NULL
      RocksDB status is success (`emo_rdb_check`), and `(R, Void)` is not
      a shape.
- [x] **T65.8** — batches: `batch_new`/`put`/`delete`/`write`/`close`,
      the `Batch` facade, the same-database guard, the Db attach.
- [x] **T65.9** — iterators: new/seek/seek_to_first/valid/next/key/
      value/close, the key-value copy pair, prefix-scan capability.
- [x] **T65.10** — snapshots and the lifecycle guards: the
      snapshot-plus-readoptions bundle, the iterator count, Db close under
      live handles, Snapshot close under live iterators; found on the
      way: the local `live` name collides with `live()` (E4004).
- [x] **T65.11** — the demo skeleton and the text beat: `kv_demo/
      package.emo`, the helpers, destroy/open/close, a text put/get, the
      seeded `expected.txt`.
- [x] **T65.12** — the binary proof: `00 01 ff 41`, the empty value, the
      missing key.
- [x] **T65.13** — the batch and prefix-scan beats.
- [x] **T65.14** — the snapshot, `cf_create`, and reopen beats; the
      twelve-line `expected.txt`; found on the way: top-level consts used
      only by thunks earn unused-variable warnings.
- [x] **T65.15** — the gate: the RocksDB probe, the content-named
      registry, the build, three byte-identical runs, E3009/E5007; the
      lock via `emo deps resolve`.
- [x] **T65.16** — `projects/emo-db/README.md` + zh.
- [x] **T65.17** — the close-out: TASKS EN+zh, the plan README, `CHECK.md`,
      the sqlite3 caveat and its re-resolved lock, `plan/step-65-emo-db-
      rocksdb.md`, `dune build`/`@fmt` green.

## Evidence

- RocksDB 11.13.2 (Homebrew), resolved by `pkg-config rocksdb`:
  `-I/opt/homebrew/Cellar/rocksdb/11.13.2/include
  -L/opt/homebrew/Cellar/rocksdb/11.13.2/lib -lrocksdb`.
- `projects/emo-db/check.sh` green: the binding type-checks; the demo
  builds on `c`; three runs byte-identical with `expected.txt`; `emo run`
  exits 70 with E3009; `emo build --target ocaml` exits 65 naming the
  missing target.
- The demo's output (the golden's twelve lines): `open: notes`,
  `cf_create: indexes`, `get user:1: bytes=5 value=616c706861`,
  `get bin:1: bytes=4 value=0001ff41`,
  `get empty: found=1 bytes=0`, `get user:404: found=0`,
  `batch: seed=0 user:2=74776f user:3=7468726565`,
  `scan user: 757365723a31=616c706861,757365723a32=74776f,757365723a33=7468726565`,
  `snapshot: get=616c706861 latest=62657461`,
  `snapshot scan: first=757365723a31=616c706861`,
  `reopen: user:1=62657461 families=default,notes,indexes`, `done`.
- The checker probes, run through the built compiler: a `Bytes` foreign
  parameter checks clean on `c`; a `Bytes` return reports E4200 with "take
  an out-parameter"; the `ocaml` target refuses the parameter; a carrier
  class field of `Bytes` stays out of the struct shape tier.
- `dune build src/emo_cli/emo.exe test/emo_check/emo_check_test.exe`
  green (the test binary compiled, not run — the auto-test rule).

## Found on the way

- **A NULL RocksDB status is success, and the first shim treated it as
  failure.** `emo_rdb_error(err, 1)` was called on every put; with no
  error string it recorded "unknown RocksDB error" and answered 1, so the
  demo's first run died at `put`. The fix is the `emo_rdb_check`/`
  emo_rdb_error` split: a void-shaped call checks for NULL and answers 0,
  while the call sites where NULL is the failure (open, cf_create) keep
  the error constructor. The golden's first run is the regression test.
- **`(R, Void)` is not a shape.** A Void-returning function takes no
  `return`, and a tuple cannot carry Void; the writes answer the resource
  (the existing idiom) rather than inventing a `Bool` that is always
  true.
- **The aggregate's method list keeps its names in the class scope.** A
  local `const live` inside `Snapshot.close` collided with the `live()`
  method (E4004); it is `running` now. This is the postgres step's
  local-name-versus-method finding, restated.
- **Top-level consts are emitted in the root entry even when only thunks
  use them**, so unused-variable warnings appear for `digits` and
  `notes_again`; moving `digits` into `hex` and inlining the second const
  keeps the demo warning-free. The compiler behavior is noted, not
  changed here.

## Open, deliberately

- **`WriteOptions.sync`** — the plain write path leaves it off; M32's
  COMMIT is the consumer that turns it on.
- **`Bytes` foreign returns** — the out-parameter rule covers every
  arc-one read; a return position waits for an API that needs one.
- **A pinned result slot for reads** — the two-pass read repeats the
  lookup; the block cache makes it cheap, and M34 measures before any
  cache-shaped shim state is introduced.
- **Multiple databases in one process** — the shim keeps one last-error
  buffer and the package is written for one database; the design record
  is a single-node server, and a second handle waits for a consumer.
- **Column family drop, prefix extractors, TTL, compaction knobs** —
  none has a consumer in arc one yet.
- **Large values** — a value is read fully into one `Bytes`; streaming a
  value larger than memory waits for a consumer and a binary file story.
