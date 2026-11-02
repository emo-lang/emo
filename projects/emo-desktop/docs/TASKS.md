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

- [x] **A7.1** — The fb backend's hosted core: measure, place, clip,
  and blend against a buffer interface, pure portable Emo, dual-run
  in the corpus (the tui backend's discipline). **Landed 2026-11-02**
  as [`fb/`](../fb) — package `emo/ui_fb` (`ui_fb.emo`, `canvas.emo`,
  `test.emo`), its golden (`fb/golden/`) and its gate (`fb/check.sh`),
  the first code in the project. The box model is `ui_tui`'s to the
  letter, in pixels: a leaf measures to its label in glyph cells of the
  bitmap font's fixed 8×16 cell (A8.1's font, measured ahead of its
  pixels), containers stack and line up with the same `padding`, `gap`,
  `align`, `grow`, `width` and `height` arithmetic. Painting is
  rectangles — every node, containers included, fills the rectangle it
  was placed in with its role's color from a platinum palette whose
  roles each lean on a different channel (a swapped byte order shows as
  a tint, never as a matching gray); `Spacer` paints nothing. **The walk
  paints as it goes** — no draw list between layout and surface — so a
  frame allocates nothing beyond the tree it was handed, the arena's
  price on the metal; the first shape collected draws in an
  `ArrayBuilder`, and the riscv64 probe refused it by name. `clip` is
  the core's verb (the windows and the damage rectangle clip against
  bounds that are no surface's own) and `over` is integer source-over
  with the coverage in the color's top byte, rounded to nearest so
  every target lands on the same byte. **The seam is `Surface`** —
  `width`, `height`, `at`, `fill`, `blend` — the one thing a host
  provides; `canvas.emo` is the hosted one, pixels as XRGB8888 words in
  one `Bytes` through `set_u32_le`/`get_u32_le` (whole words, the
  assessment's blit rule, kept on the hosted twin so it exercises the
  stores the carve will), and a module of its own because riscv64 lowers
  `Bytes.new` but none of its accessors, so the metal's registry stages
  the core without it. `ppm` writes any surface as P3 text, the format
  the metal's `screendump` eye reads. **The backend class rides along**
  (`Fb` over a caller-owned surface and a scripted `Input`, the tui's
  shape) because it is load-bearing, not sugar: the `beam` and `wasm`
  emitters build an interface call's dispatch from the classes in the
  program that implement it, and a core with no `ui.Backend` implementor
  was refused by both (`method patch has no dispatch`) — with one, all
  five hosted targets compile the package. Its sink is typed from
  birth, `Box.new(unmounted())` holding a `ui.Events` that delivers to
  no one, the shape the core's own backends still lack (below). The
  gate: the package and its test type-check, 36 assertions as values
  (measure, clip, over, the canvas as a `Surface`, paint's layering and
  clipping, `ppm`, the script, the backend's repaint through `ui.run`),
  the five targets build, and the golden — an app whose row holds one
  button per count, driven add, add, sub on a 48×32 screen smaller than
  its tree, so the frame carries the panel, the title's ink, the row cut
  at the right edge with its last button a 2-pixel sliver, and the input
  clipped away below — prints the same bytes on the interpreter,
  `ocaml`, `c`, `typescript` and `beam`, `wasm`'s `printf` refusal pinned
  by name (the tui golden's four). **The metal leg, probed by hand**: the
  core module with `ui.emo` lowers to a riscv64 user ELF as it stands,
  given only the two manifest lines (`riscv64` on `emo/ui` and
  `emo/ui_fb`) — those land with the carve surface and the first frame
  (A7.2), not ahead of them. The convergence corpus entry (`corpus/fb`
  beside `debug`, `ssr`, `tui`) is A10.1's, with the sixth family.
  **Found on the way, fixed the same day as T48.14**: EmoUI's own gates
  (`projects/emo-ui/check.sh` and the backends' under it) had been red
  since 2026-10-18 — the checker's class-field typing (`8171d0d`) made
  every backend's `self.sink = Box.new(0)` a `Box[Int64]` that `mount`
  could no longer `replace` with the loop's `ui.Events` (`debug.emo`,
  `ui_tui.emo`, E4004), and none of those gates run under
  `dune runtest`. The fb gate stages the core as `ui.emo` alone — the fb
  backend never names `ui.debug` — and was green against the core as it
  was; the six backends now carry the fb sink's shape (T48.14, the Emo
  tree's tracker).
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
