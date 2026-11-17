# Step 88 — WASI's file half, rung two: listing, stats, mutations

**Milestone:** M49 · **Prereq:** step 87 (preopens and path_open) ·
**Status:** complete

Step 87's rung opened and read files inside a granted directory; this
rung completes the file story a real toolchain's module lives in:
directories list, files and paths stat, and the four path mutations
(create directory, remove directory, unlink file, rename) land — the
os package's own semantics projected onto preview1, the same
discipline as rung one.

## Decisions

- **Directories open.** The DIRECTORY oflag opens the directory
  itself — a stat before the open answers ENOTDIR for a file —
  read-only, through the same os_open_read door POSIX opens
  directories with. Such fds (kind 3) carry their host path and the
  grant root they came from, so every resolution stays confined; rung
  one's "opens files, not directories" refusal retires.
- **The fd table carries the host path and the root.** Six-wide now:
  (kind, host_fd, guest name, host path, root, fdflags) — the host
  path is what fd_readdir, fd_filestat_get, and the mutations resolve
  against, the root is the confinement floor, and the guest name is
  what the discovery walk answers.
- **fd_readdir is stateless.** The os door's sorted listing walks
  fresh every call: the caller's cookie is the d_next it saw last (0
  to start), entries serve whole-only into the buffer, d_next is the
  one-based position, d_ino answers 0, and d_type answers UNKNOWN —
  the type channel is path_filestat_get, which wasi-libc calls
  whenever a dirent's type is unknown.
- **One stat door, path-shaped.** `os_stat(path)` answers (is_dir,
  size, atime_ms, mtime_ms, ctime_ms) — the times at the wall door's
  millisecond resolution, scaled to nanoseconds for the wire.
  fd_filestat_get stats the fd's own host path (a file unlinked after
  its open answers the miss — named, not hidden); stdio answers
  character device with no size and no times.
- **The lookupflags' symlink-follow bit is required.** The doors
  carry no lstat, so a no-follow lookup refuses EINVAL rather than
  follow silently.
- **The mutations ride the doors that already exist** — os_mkdir,
  os_rmdir, os_unlink, os_rename — with the errno text channel
  extended to the branches a real module acts on: EEXIST (20),
  ENOTEMPTY (55), EXDEV (75), EPERM (63) joining the vocabulary, the
  shared normalized phrases matching as rung one's do.

## Tasks

- [x] **T88.1** — The `os_stat` door: the checker's table, the
      interpreter's frame binding and dispatch arm, the c emitter and
      runtime, the ocaml target's runtime.
- [x] **T88.2** — The host: the six-wide fd table, the shared
      resolve_under (the confinement walk seeded from the base path's
      own components, the grant root the floor), DIRECTORY opens with
      their stat-before-open, fd_readdir's cookie walk, the two
      filestats, and the four mutations.
- [x] **T88.3** — The fixture: the stat pair (filetype and size
      pinned, times present), the root listing with its cookie resume,
      the directory made, opened, and listed through the guest, and
      the rename/unlink/rmdir chain — every verdict pinned byte for
      byte; the link-refusal probe moves to `fd_pread`.
- [x] **T88.4** — The docs: this plan, `plan/README.md`'s row,
      `docs/stdlib/wasm.md` + zh mirror, TASKS.md + zh mirror,
      CHECK.md's settle record.
