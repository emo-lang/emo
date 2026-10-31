# emo-desktop — the task tracker

The desktop-side half of the ladder; the kernel-side half of every
milestone lives in [EmoOS's tracker](../../emo-os/docs/TASKS.md)
(Step 8). The record behind the ladder is the
[assessment](assessment.md); the ABI's stability contract is
[`desktop-abi.md`'s](../../emo-os/docs/desktop-abi.md). Compiler-track
tasks (the literal fix, the N-block arena, the pool) are the Emo
tree's and EmoOS's, listed there.

## Step 0 — the decisions ahead of the screen (decided 2026-10-31)

- [x] **D1** — The compositor's home: a service process in the
  kernel image, the `fs.emo` lineage.
- [x] **D2** — M7's present shape: the client direct-mapped to the
  carve, `present` only the flush.
- [x] **D3** — The font route: fix the codegen's wide literals; the
  disk is the fallback.
- [x] **D4** — The pool's scheduling: beside M7 — M8's Elm loops
  need it.
- [x] **D5** — The resolution baseline: 1024×768 XRGB8888, the
  carve sized to it.

## M7 — the screen (the desktop side)

- [ ] **A7.1** — The fb backend's hosted core: measure, place, clip,
  and blend against a buffer interface, pure portable Emo, dual-run
  in the corpus (the tui backend's discipline).
- [ ] **A7.2** — The first frame: a full-screen pass paints through
  the core into the authorized carve buffer and presents it; the
  golden's eye is the `screendump` PPM checksum.
- [ ] **A7.3** — The corpus leg: `run.sh`'s display counterpart for
  the hosted runs (`-display none`, checksums asserted).

## M8 — glyphs & pointer (the desktop side)

- [ ] **A8.1** — The bitmap font renderer through the fb core (the
  font's home per D3).
- [ ] **A8.2** — The pointer sprite: the compositor's cursor plane,
  moved by the merged event stream.
- [ ] **A8.3** — The Elm loop on metal: an event-driven fb app whose
  per-event tree rebuild survives the arena (the pool's first
  consumer, on the compiler track's schedule).

## M9 — windows (the desktop side)

- [ ] **A9.1** — The window shell: toplevel surfaces with roles
  (refuse the rest by name), the composited stack, drag and focus
  through `win_move`/`win_focus`.
- [ ] **A9.2** — The kill-and-restart acceptance: a window stack that
  survives a client's death and rebirth with the machine whole.
- [ ] **A9.3** — The five M9 increments the growth contract adds
  (with the assessment's seams as the spec).

## M10 — the desktop (the desktop side)

- [ ] **A10.1** — The EmoUI fb backend whole: `emo/ui_fb` as the
  sixth backend family, the Elm loop unchanged.
- [ ] **A10.2** — The dock and the desktop shell (`emo_desktop`).
- [ ] **A10.3** — The first apps: a counter, a file browser, an
  editor — each a corpus package, dual-run where hosted.

## M11 — honest multi-app (the desktop side)

- [ ] **A11.1** — The corpus apps become disk ELFs in place: loaded
  by the filesystem, per-image segment tables, per-process gate
  checks (the kernel-side tasks are EmoOS's Step 8).
- [ ] **A11.2** — The multi-image acceptance: two apps, two images,
  one desktop, the golden's hands (`sendkey`/`mouse_move`) driving
  both.
