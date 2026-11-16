# Step 58 — the Wayland client package

**Milestone:** the noctalia track's foundation (emo-desktop M18) ·
**Related:** `plan/step-57-httpd.md` (the package-on-`net` precedent),
`projects/emo-desktop/docs/TASKS.md` M18 (the task ladder),
`projects/emo-desktop/docs/assessment.md` (the lineage) · **Status:**
done 2026-11-12 (A18.1–A18.12)

## What landed

`stdlib/registry/wayland/0.1.0` — the Wayland client wire protocol in
pure Emo: the message codec (header, int/uint/fixed/string/array,
the fd's ancillary queue), the core tables (`wl_display`,
`wl_registry`, `wl_callback`), the `wl_compositor`/`wl_surface` pair,
`wl_shm`/`wl_shm_pool`/`wl_buffer`, and the `xdg-shell` family
(`xdg_wm_base`, `xdg_surface`, `xdg_toplevel`) with
`wait_configure` — the configure-before-commit discipline made
structural. Targets: `c` alone (the sqlite3 precedent).

The runtime half, in `emo_c_runtime.c` and the emitter/check/eval
tiers beside it: AF_UNIX listen/connect, the fd passage
(`net_sendmsg_fd`/`net_recvmsg_fd`, SCM_RIGHTS, one fd a call), and
the shm tier (`os_shm_open` — a private file unlinked at birth —
`os_ftruncate`, `os_pwrite`). The interpreter refuses the fd natives
at runtime, honestly (the OCaml Unix module carries no sendmsg; the
c-only fd tier is the shape, the interpreter stubs the named
follow-up).

The verification, two legs: `examples/wayland_wire` and
`examples/wayland_handshake` — the codec against hand-computed
fixtures and a mock compositor over a real Unix socket (four requests
byte-exact, the pool fd round-tripped, its bytes read at the far
end), both in `c_goldens`; and `devtools/wayland-smoke.sh` — the
paint demo's C compiled in a cc+sway+grim container, run under
headless sway, `grim` the eye, the pattern's pixels counted. The
smoke leg exits 0: **the first frame an Emo program put on a real
compositor.**

## The decisions the wire graded

- **The fd argument takes no word in the argument stream.** The
  protocol prose suggests a placeholder word; the actual wire (sway's
  libwayland, graded twice) reads the next argument where the
  placeholder would sit. The codec's fd rides the ancillary queue
  alone, and `Args.fd` claims it from that queue — with the
  placeholder word present, the compositor answered "invalid size
  (0)" (the pool's size arriving as the placeholder), and with the
  fd's own number there, "invalid width, height or stride" (the size
  arriving as the fd's number). Both messages decoded the shape
  literally.
- **The opcodes are hand-written and the compositor grades them.**
  sway's error events named every miss: `create_positioner` at 1 and
  `get_xdg_surface` at 2 on `xdg_wm_base` (the first smoke run
  silently minted a positioner@8 and the compositor read the
  toplevel's bind as its `set_size`), `ack_configure` at 4
  (`set_window_geometry` at 3), and the wl_surface family one higher
  than a first reading guesses (`destroy` at 0: attach 1, damage 2,
  commit 6).
- **macOS's POSIX shm objects refuse read and pwrite outright**
  (mmap-only), so `os_shm_open` is a private file unlinked at birth —
  seekable and mappable on both platforms, and the shape the wl_shm
  pool accepts.
- **The checker's `(R.error, why)` convention only knew the pair**;
  the three-slot `(R, data, fd)` result crashed `fold_left2` after
  the E4013 report. The convention now reads any `(R, ...)` shape,
  and the arity guard refuses instead of proceeding to the fold.

## Found, not fixed

- **A bare `{ ... }` block miscompiled silently** (the handshake
  demo's first shape lost its tail; the case-wrapped shape worked).
  Recorded for the compiler track — **fixed 2026-11-14 (`64e3a944`,
  the shell's fork-loop shape named the mechanism)**: the void body's
  tail rewrite folded every branch-trailing bare call into a
  `Return_stmt`, so a call ending an `if`/`case`/`receive` that was
  not the body's last statement made the rest of the block dead code.
  The rewrite keys on exit position (`rewrite_exit`), pinned by the
  two IR goldens in `test/emo_ir`; the mid-body `if`, the mid-body
  `case`, and the demo's `c` build byte-identical with its golden
  verified 2026-11-16.
- **The generated C seeded module consts in the root entry**, so a
  const no script statement read warned under `-Wall` (`w` unused —
  the seed bound the const's value to a local only the script's own
  statements read; a def's read goes through the memoized thunk, so
  the def-only shape warned too). The corpus's own pre-existing
  shape — **fixed 2026-11-16 at the IR**: an unread const seeds as
  the effect it is, the eager call stays (the interpreter
  initializes eagerly), the dead local goes, and a capture or a
  script read keeps the binding; pinned by three IR goldens in
  `test/emo_ir` and re-verified against the sampled examples and
  this demo's `c` golden.

## Named follow-ups

The interpreter's fd-passage stubs (dune `foreign_stubs`), the input
tables (`wl_seat`/`wl_pointer`/`wl_keyboard` and the keymap fd), the
event loop's reader-process shape, memfd_create on Linux as the
pool's faster door, and the second phase of the noctalia track — the
directions the foundation now makes concrete.
