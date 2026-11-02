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
  the core without it (A7.2 made it a package of its own,
  `emo/ui_fb_canvas`, so the core's manifest could say `riscv64`). `ppm`
  writes any surface as P3 text, the format
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
- [x] **A7.2** — The first frame: a full-screen pass paints through
  the core into the authorized carve buffer and presents it; the
  golden's eye is the `screendump` PPM checksum. **Landed 2026-11-02.**
  The screen pass (`projects/emo-os/hello/main.emo`, T8.2's) now paints
  the desktop's first frame before its proof: the mode is the device's
  answer (`output_info`), the carve at that mode is the core's
  `Surface` — `Carve`, the raw shim the assessment keeps on the metal's
  side alone, a pixel a 32-bit word at the identity the grant mapped,
  `poke32` the store and `peek32` the load, no verb and no copy — the
  tree is `emo/ui_fb_frame`'s (a title strip, a body that takes the
  height left over, a dock with two buttons: M7's picture, rectangles),
  `ui_fb.paint` lays it in, and the pass's own fold over the carve's
  words goes on the wire as `frame 1234944000` before the grant's
  present puts the frame on the display; T8.2's pattern words go back
  over the frame after the present, so the exit's read-back still finds
  them and the display still holds the frame. **The eye is three
  readings of one number**: the pass's digest of the carve it painted,
  the hosted canvas's digest of the same tree
  (`fb/frame/golden/expected.txt`, the same bytes from the interpreter
  and all five hosted targets), and `run.sh`'s fold over the monitor's
  screendump at `present ok` — the fold `d = (d * 31 + word) mod 2^32`,
  row-major, in Emo on both sides and in Python on the display's bytes;
  the second screendump's model (T8.8's) is built on the first, the
  frame its base where the gradient was. **The packages were reshaped
  to make the manifests true**: a package names the targets every module
  it carries compiles on, so the canvas — a `Bytes`, which riscv64 does
  not lower — is its own package now, `emo/ui_fb_canvas` (five hosted
  targets), and the core, the first frame (`emo/ui_fb_frame`, the tree
  and the digest) and EmoUI's core declare `riscv64` — their reachable
  modules lower for a user program, pinned without a machine by
  `fb/probe/metal/` (the core gate pins `beam` and `wasm` through the
  goldens instead of the directory build: those emitters lower an
  interface call only against an implementor in the program, and the
  core alone carries none). The user image's manifest names the three
  packages beside the stub; `start.sh` stages them with the stub into a
  registry (`EMO_REGISTRY` names the one registry a build resolves from)
  and the `dune` smoke stages the same files; `hello/ui.emo` is
  `console_ui.emo` now, the module path `ui` being the dependency's.
  **What the metal taught, in order**: a method's body is the dynamic
  convention and every computed `Int64` in it a boxed cell in the arena
  that no pool reclaims (value kinds carry no claims) — the first paint
  was `user heap 22 gone` before the first row ended, and the pixel
  loops moved into fully typed top-level defs, which compute raw (the
  rule for every pixel loop on the metal, `CHECK.md`); `Float64.to_int64`
  was not lowered on riscv64 — the dynamic dispatch knows `to_string`
  and `length` alone, so the box model's first `padding().to_int64()`
  was an invisible `emo_fail` — and is now, `fcvt.l.d rtz`, the
  truncation every hosted target answers, pinned in `examples/floats`
  (EmoOS T8.10); the user runtime's `emo_fail` says nothing on the wire
  from U-mode — its console emit never reaches the gate, and the
  kernel's `user fault … cause 2` on the park's `wfi` was the only trace
  — found, not fixed; and three gaps named by the emitter stand:
  program-wide def values (the loop's `ui.run(view, update, …)`, A8.3's
  blocker), `ArrayBuilder`, and `Bytes`' accessors. **The pins**:
  `run.sh` green under both timer transports, three consecutive rounds
  byte-identical, the ledger `frames 77 45` unchanged; the fb gate 51
  ok; `dune runtest` and `@fmt` green.
- [x] **A7.3** — The corpus leg: `run.sh`'s display counterpart for
  the hosted runs (`-display none`, checksums asserted). **Landed
  2026-11-02, the same day as A7.2, whose machinery carries the leg's
  substance** — the corpus leg proper is `fb/frame/golden/`: the first
  frame's tree rendered on the hosted canvas at the display's baseline
  mode, its digest pinned in `expected.txt`, byte-identical from the
  interpreter and all five hosted targets, asserted by `fb/check.sh`.
  What A7.3 adds is the counterpart made mechanical. `run.sh` asserts
  the corpus's **file**, not its own copy of the number: the line the
  screen pass prints (`frame <digest>`, whole, between the mode's line
  and the present's) and the fold over the monitor's screendump at the
  present both read `../emo-desktop/fb/frame/golden/expected.txt` — a
  missing file is the loud end with the path named, and a wrong number
  is refused with the display's real digest named — so the metal and
  the corpus cannot drift apart, because there is one number and it
  lives in the corpus (`fb/frame/golden/main.emo`'s header says so).
  The `dune` smoke runs `run.sh` from a scratch tree that carries no fb
  tree and points `FRAME_EXPECTED` at the repository's file, asserting
  it exists before the machine boots. Windowless on both sides: the
  metal's asserted leg has run `-display none` since T8.8, and the
  corpus has no window at all — the checksums are the whole truth each
  side keeps. **With this the A7 ladder closes and M7 is complete on
  both sides of the gate** (EmoOS Step 8's nine tasks and T8.10 beside
  them; the desktop's A7.1–A7.3) — both READMEs' milestone rows say so.
  **The pins**: `run.sh` green in-repo against the default corpus file;
  a wrong corpus number refused (`the display's frame digests to
  1234944000; the corpus's first frame is 1`); the missing file
  refused; the `emo_os` `dune` suite green (3 of 3, the smoke
  corpus-pointed); `@fmt` green.

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
