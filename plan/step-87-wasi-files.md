# Step 87 — WASI's file half: preopens and path_open

**Milestone:** M39 · **Prereq:** step 77 (WASI preview1), the os
package's fd half · **Status:** complete

Step 77 answered the twelve preview1 functions a hello-world module
touches and left the file names link-refusing, the pressure recorded
in step 74's ledger and named as this ring in the wasm capability
ladder: `path_open` and the preopens. The prerequisite the ladder
named — "the runtime's own file semantics take the shape of WASI's
preopens" — turned out half-settled already: step 85 projected the os
package's fd half onto `wasi:filesystem` for the compiled-to-wasm
direction. This ring projects the same os semantics onto the preview1
host, so both directions speak one file story.

## Decisions

- **The os package is the foundation.** The host serves files through
  the os doors (`os_open_read`/`os_open_write`/`os_open_append`/
  `os_read`/`os_write`/`os_close`, and the new `os_lseek`), the same
  POSIX surface the ocaml, c, and interpreter targets already carry —
  not a second file story. Package-internal code calls the doors
  directly, the `cli.emo` precedent (`file_read`).
- **The grant is explicit and empty by default.** The preopen table
  (`wasm.set_wasi_preopens`, the CLI's repeatable
  `--dir HOST[::GUEST]`, guest defaulting to `/`) is the whole file
  system: no grant, no files — wasmtime's posture, and the strictness
  rule the host already lives by. A new grant replaces the table and
  drops every fd the previous grants produced.
- **Lexical confinement.** `path_open` resolves inside the preopen's
  root: "." and empty components skip, ".." pops, a pop past the root
  is ENOTCAPABLE, and an absolute path under no preopen is the same
  refusal. The operator chose the directory; nothing beyond it is the
  guest's to name. Symlinks are not realpathed (recorded below).
- **One direction per open.** The doors serve read, write (create +
  truncate — the stdio "w" shape the CREAT/TRUNC oflags land on), or
  append (the APPEND fdflag). A two-direction open, the DIRECTORY and
  EXCL oflags, a truncating read, an append without write, and any
  fdflags bit past APPEND refuse EINVAL rather than half-honor. This
  rung opens files, not directories; opening the preopen root itself
  is EINVAL.
- **The errno table matches wasip1.h.** The ring found the host's
  ENOSYS and ESPIPE off by one (51/69; the real 52/70) — harmless
  until now, because only the host's own fixture read them, but
  load-bearing the moment a real wasi-libc module branches on ENOENT
  (44). Corrected, with ENOENT, ENOTDIR (54), ENOTCAPABLE (76),
  EISDIR (31), and ENAMETOOLONG (37) joining the vocabulary.
  `fd_seek`'s import shape was the same story: its i64 offset was
  pinned as an i32, so a real module's import refused before this
  ring; the corrected shape is pinned by the fixture's seekpipe
  module.
- **The doors' failure channel is the reason text.** The os doors
  answer `(R.error, reason)` and the reason's machine content is the
  shared normalized strerror text both runtimes print. The branches a
  real module acts on match their phrases ("No such file or
  directory" → ENOENT, "Is a directory" → EISDIR, "Illegal seek" →
  ESPIPE); everything else answers EIO. A structured errno channel
  through the doors is the recorded follow-up if more branches earn
  it.

## Scope

### In

- `src/emo_check`, `src/emo_eval`, `src/emo_codegen/emo_c.ml`,
  `src/emo_codegen/c/emo_c_runtime.c`,
  `src/emo_codegen/ocaml/emo_ocaml_runtime.ml` — the `os_lseek` door,
  the five hosted spots.
- `stdlib/registry/wasm/0.1.0/internal/wasi.emo` — the preopen and fd
  tables, the prestat pair, `path_open`, `fd_read`, and the file-fd
  growth of `fd_write`/`fd_close`/`fd_seek`/`fd_fdstat_get`.
- `stdlib/registry/wasm/0.1.0/wasm.emo` — `set_wasi_preopens`.
- `src/emo_project/emo_project.ml`, `src/emo_cli/emo_cli.ml` — the
  `--dir` flag through the embedded driver's `__dirs`.
- The wasi fixture: the sandbox, five hand-encoded modules, the
  byte-pinned expected file.

### Out

- `fd_readdir`, `fd_filestat_get`, `path_filestat_get` — the second
  half, with the path mutations (`path_create_directory`,
  `path_unlink_file`, `path_remove_directory`, `path_rename`); the
  names keep link-refusing, the fixture's refusal probe now names
  `fd_readdir`.
- `fd_pread`/`fd_pwrite`, `fd_renumber`, `fd_advise`, `fd_allocate`,
  `poll_oneoff`, `sock_*` — no consumer.
- Symlink confinement: the lexical walk does not realpath; a symlink
  inside a granted directory pointing out is the operator's grant to
  make or not make, recorded here rather than silently resolved.

## Tasks

- [x] **T87.1** — The `os_lseek` door: the checker's table, the
      interpreter's frame binding and dispatch arm, the c emitter and
      runtime, the ocaml target's runtime.
- [x] **T87.2** — The host: the tables, the prestat pair, path_open's
      resolution and direction rules, fd_read's read-and-scatter, the
      file-fd growth, the errno corrections, fd_seek's shape fix.
- [x] **T87.3** — The fixture: the os-door sandbox, one preopen, five
      modules (no-grant, discovery, open/read/seek/close,
      create-write, escape), the seekpipe shape pin, the `fd_readdir`
      refusal probe, and the byte-pinned expected file.
- [x] **T87.4** — The CLI: `--dir HOST[::GUEST]` through `__dirs`.
- [x] **T87.5** — The docs: this plan, `plan/README.md`'s row,
      `docs/stdlib/wasm.md` + zh mirror, TASKS.md + zh mirror,
      CHECK.md's settle record.
