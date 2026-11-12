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
  carve sized to it. M14's D6 supersedes it.

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

- [x] **A8.1** — The bitmap font renderer through the fb core (the
  font's home per D3). **Landed 2026-11-02.** The font is the project's
  own, drawn in [`fb/glyphs/glyphs.txt`](../fb/glyphs/glyphs.txt) — the
  95 printable ASCII characters and a hollow cell for every other byte,
  a 1-pixel stroke on the fixed 8×16 cell the box model has measured
  labels by since A7.1 — and written into `fb/font.emo`'s `rows` table
  by `fb/glyphs/gen.py` (the gate refuses a stale table; the drawing's
  directory is not `font/` because a sibling directory claims the module
  path the file holds): four 32-bit words per glyph, four rows to a
  word, the top row in the high byte, so the 96 glyphs are 384 boxed
  cells on the metal's arena rather than 1,536. That is D3's route — the
  font's home is the code, the wide-literal fix carrying the table to
  the metal, no disk and no second image. `font.glyph_of` finds a
  one-byte string's glyph in the alphabet (`index_of`; a control byte or
  one byte of a multi-byte character is the hollow cell on every target
  alike), and `top_rows`/`bottom_rows` hand a glyph's sixteen rows as
  two words. **The core paints labels now**: `place` fills a leaf's box
  as before, then lays its label's glyphs from the box's top-left corner,
  one cell per byte, in the role's ink (`ink_of`: dark on the panel, the
  input's paper and the image's caption, light on a button's steel);
  `Text` fills no box any more — its glyphs are ink on whatever it sits
  on — and the surface's bounds are what clip a cell, never the node's
  rectangle, the terminal backend's rule, so a label wider than its box
  runs on as the terminal's does. **`Surface` grows a `glyph` verb** —
  `(x, y, top, bottom, color)`, one call per cell, the row arithmetic
  shared through `ui_fb.glyph_row` — rather than painting a glyph as
  rows of `fill`: on the metal an interface call boxes every Int64 it
  carries into a cell the pool never reclaims, so a frame of text
  painted pixel by pixel, thousands of calls, would spend the arena
  before its first line ended; the hosted canvas and the carve
  (`carve_glyph`, a typed def in `hello/main.emo`) each implement it,
  and the user image's registry carries the font beside the core
  (`start.sh`, the `dune` smoke). **The compiler track lowered three
  String methods for riscv64** where the metal first asked for them
  (T8.10's precedent): `substring` and `index_of` as runtime helpers
  over the String block, and `length` read on the block for a static
  String receiver — the dynamic dispatch answered `length` boxed, which
  a typed frame took for the raw word it trusts (`i < s.length()` in a
  typed def walked past the String's end: found, fixed), and the String
  methods the metal does not lower refuse by name at the build now
  rather than failing namelessly at run time. **Two more finds on the
  way, fixed**: an `Index` read (and a class field read) in a native
  frame left the element's tagged cell where the frame trusts a raw
  Int64 — unexposed until now, because a def with an Array parameter is
  dynamic and the first native shape that indexes is a typed def over a
  module-level const table, the font's; the metal's first try drew every
  glyph as the cells' own addresses — and an index expression in a native
  frame was boxed only to be read back, a 16-byte birth per read the
  pool never reclaims, read raw now. `examples/glyph_lookup` pins the
  walk whole (the interpreter and QEMU printing the same lines) and a
  refusal test pins the refusal. **The pins**: the fb gate 52 ok — the
  core's test 32, the canvas's 28, the glyph table against its drawing,
  the probe (which paints the first frame through a counting surface
  now, 6 boxes and 75 glyphs) built for the metal, both goldens on every
  target; `run.sh` green under both timer transports, `frame 3285341944`
  the one number read off the carve, the hosted canvas and the display's
  screendump alike, the ledger `frames 77 45` unchanged; `dune runtest`
  and `@fmt` green. **Standing**: a glyph's five boxed arguments, the label
  walk's own temporaries (`text` takes a `Surface`, and a def with an
  interface, class or Array parameter is a dynamic frame on the metal —
  the per-pixel work is `carve_glyph`'s, all-numeric and typed, A7.2's
  rule) and the per-character `substring` (a String, which the pool does
  not hold) are arena births per frame — nothing to the first frame's
  hundred glyphs, and the Elm loop's to count (A8.3), on the compiler
  track's schedule with the def values it already waits on.
- [x] **A8.2** — The pointer sprite: the compositor's cursor plane,
  moved by the merged event stream. **Landed 2026-11-02.** The sprite is
  the desktop's — a Wayland client's cursor is the client's — drawn in
  [`fb/pointer.emo`](../fb/pointer.emo) as rows of cells (`#` the
  outline's ink, `o` the body's paper, `.` clear): a 12×17 arrow, a
  1-pixel outline around a white body, the hotspot its tip; the module's
  `paint` lays it on any `Surface` (the hosted twin, pinned by the
  canvas's test at the tip, the body, the tail and off a corner), and
  the one drawing is read three ways — by `paint`, by the metal's
  screen pass, which writes it cell by cell into the carve's sprite
  memory (the carve's last 64 KiB, past the proof pattern's line: the
  header after the pixels, so a torn read is no sprite — the contract
  is [`desktop-abi.md`'s](../../emo-os/docs/desktop-abi.md)), and by
  `run.sh`'s model of the display, which composites the rows off the
  file at the beat's position. **The plane is the compositor's, in
  software** (EmoOS T8.11, the kernel side): the display's screendump
  is the golden's eye and a device cursor never reaches a screendump,
  so the pointer the golden can see is the one the carve holds — the
  compositor saves the words under the sprite, stores its opaque
  pixels, hides it around every window blit, and presents the one
  rectangle the old and the new places lie in; **moved by the merged
  event stream's pointer half**: the tablet (absolute axes, so the hand
  names a position) is a driver process of its own, its events into the
  stream through a ring after the keyboard's and its reports' positions
  into cells the compositor scales by the axes' maxima the device's
  config states, one notice per report. **The desktop-side pins**: the
  fb gate 52 ok (the core's test 39 — the drawing's shape — the
  canvas's 35, the probe painting the pointer through its counting
  surface for the metal); the user image's registry carries the sprite
  beside the font (`start.sh`, the `dune` smoke). **The metal's**: the
  pass's `move 0 16384` and `move 1 16384` after `byte 75`, the
  compositor's `pointer 512 384`, the second screendump's model grown
  by the sprite at zero mismatches with the window copies composited
  around it, `run.sh` green under both transports, the ledger
  `frames 80 45`. **Found on the way** (all fixed, EmoOS T8.11's
  record): the shim completed the input line's claim with a clobbered
  register — the first input interrupt was the last a device could
  raise; a kernel service cannot `gate_reply` another (the notice rides
  the new `gate_post`); a device-waiter's ring needs a wake of its own
  (`device_wake`); and the monitor's `mouse_move` is relative motion an
  absolute device drops — the hand is QMP's `input-send-event`.
  **Standing**: the ride's pointer costs a rect flush per report, the
  whole sprite redrawn each time; a device cursor on the virtio-gpu's
  cursor queue is Tier B's relocation when a display the golden cannot
  see earns it.
- [x] **A8.3** — The Elm loop on metal: an event-driven fb app whose
  per-event tree rebuild survives the arena (the pool's first
  consumer, on the compiler track's schedule). **Landed 2026-11-03.**
  The app is the counter — the Elm architecture's own example, the
  console renderer's pixel twin (`projects/emo-os/docs/ui.md`) —
  written once in [`fb/frame/counter.emo`](../fb/frame/counter.emo) as
  a model, a pure `update` and a pure `view`, and run through
  `ui.run(counter.view, counter.update, counter.initial(), backend)`,
  **the loop unchanged from the hosted backends'**, on both sides of the
  gate: the screen pass runs it with the carve as the surface and the
  merged input stream in the input's seat (`Keys` in `hello/main.emo`:
  `a` the add, `b` the sub, `q` the input's end, every other event —
  the device's key reports, the pointer's moves — dropped, never
  guessed at), and the first frame's golden (`fb/frame/golden/`) runs
  the same three defs on the hosted canvas with a script in the seat,
  so one program answers on the interpreter, five hosted targets and
  the metal. **The first frame is the loop's mount now** —
  `ui_fb_frame.tree()` is the counter's view at its initial model —
  and the corpus file grew from one line to the session's four: the
  mount's frame and one per key (add, add, sub; the second and fourth
  the same number, the counter at one both times). **`Surface` grows
  `present`** — the commit the backend makes after every paint, the
  stability contract's sixth seam at the seam the host provides: the
  hosted canvas has nothing to commit, the carve's flushes itself
  through the gate's verb and says its digest first (`frame <n>`, then
  `present ok`), one pair per frame; `run.sh` asserts the four lines in
  the file's order, folds the display's screendump at the first
  present and at the fourth, and builds T8.8's model on the session's
  last frame. **The compiler track's fifth piece met here** (EmoOS
  T8.12): the riscv64 target lowers program-wide def values — a def
  named without its call is a capture-less closure record over the
  def, its code the def itself when its signature is all tagged words
  and an adapter thunk otherwise (the caller's words unboxed into the
  typed banks, the raw answer boxed back, a Void answer the false
  immediate) — pinned in `examples/def_values`, and four emitter bugs
  found on the way, all fixed and pinned (`CHECK.md`): a tail call
  through a block reloaded only its owning arguments after the drain;
  a static Box's `read` and `replace` claimed twice (a `Block` payload
  the loud overflow, a typed instance payload one release too many);
  a const thunk's `return` tail-called past its memo; and **a field
  store or a Box `replace` of an identity value kept the old word in
  t1 across the retain and the new in t2 across the release, both
  registers the runtime spends** — the field held `3`, and every
  object held in a field on the metal was reached through it for the
  first time by this loop. **The count, measured on the arena**: the
  pool takes the frame before's nodes, styles, extents and rectangles
  back, and what stays is the walk's own boxed numbers and glyph
  strings — about 3 KiB a node and 600 bytes a glyph — so the first
  picture (the title strip, the body, the dock: 65 glyphs) left 42 KiB
  per event and died on the third key, and the counter is the panel,
  the count and two buttons (four nodes, 28 glyphs), 18 KiB per event,
  the pass's 128 KiB holding the session with room for two more. The
  pool's share of a frame is about a kibibyte; the bound is the dynamic
  convention's, and typed method bodies are the lever (the compiler
  track's). **The pins**: the fb gate 52 ok (the probe runs the loop
  for the metal, `looped 4 frames` under QEMU in the kernel profile);
  `run.sh` green under both timer transports, three rounds
  byte-identical, the ledger `frames 80 45` unchanged; `dune runtest`
  (340 in the compiler's suite, the `emo_os` smoke) and `@fmt` green. **With this M8 is complete on both sides of the
  gate** — both READMEs' milestone rows say so.

## M9 — windows (the desktop side)

- [x] **A9.1** — The window shell: toplevel surfaces with roles
  (refuse the rest by name), the composited stack, drag and focus
  through `win_move`/`win_focus`. **Landed 2026-11-03** (the kernel
  side is EmoOS T8.13: verb 17 `win_role`, verb 18 `input_info`, the
  stack's roles, raise-on-focus, the walk). The shell is the desk
  pass, a branch of the user image's program (the screen pass's
  lineage): two toplevel surfaces of its own — `alpha` and `beta`,
  384×128, their buffers win_new's runs mapped into the pass's own
  table, declared with `win_role(grant, 0)` and placed with
  `win_move` — painted through the desktop's fifth package,
  [`fb/win/`](../fb) (`emo/ui_fb_win`: the title bar in the steel a
  focus changes, the body's paper, one line of ink per window), each
  present committing its frame with the digest on the wire
  (`frame <n>`, the hosted twin's numbers) and the compositor's
  composition carrying the whole stack into the carve. The protocol's
  third seam is on the wire twice: the pass that owns the buffer asks
  for the three roles the compositor does not implement and names
  each refusal (`role popup r4`, `role subsurface r4`, `role panel
  r4` — the kernel refuses by the number, the caller who chose the
  role names it, the seventh seam's shape), presents the role-less
  buffer and meets the surface's absence (`present r4` — the gate's
  checks pass, the stack has no entry for it), then declares the
  toplevel role and from there the buffer is a window. The pointer's
  scale is the device's own answer, verb 18's (`desk range 32767
  32767` on the wire — the input side of the second seam, the
  absolute reports' range never a constant of the shell's). The
  pass owns the merged stream and is the desktop's policy over it: a
  press inside a window focuses it (`win_focus`, which raises it to
  the stack's top; the bar's steel says which one), a press on a
  window's bar begins a drag — every report moves the window with the
  pointer through `win_move`, its x on the blit's word granularity,
  the window kept on the display — and the release is the present
  that shows where it went; a key byte `a` routes to the focused
  window alone, which counts it on its body line (`desk key <grant>
  <n>`); `q` ends the shell, the windows closed behind it. The
  composition itself changed with the stack (T8.13): the carve is
  cleared to the compositor's own background before the walk, so a
  moved window leaves the background behind it and the last entry
  lies over the rest — the counter's full-screen frame and the proof
  pattern are gone from the display the moment the first window
  presents, and the T8.8-era model of the display is rebuilt for the
  new truth (background, the window's pattern rows, the sprite). The
  golden's windowed beats: the display read three ways at every
  parked beat — the pixels outside the two windows are the background
  with the sprite where the hand left it, each window's rectangle
  folds to the digest the hosted twin's file names for that frame
  ([`fb/win/golden/`](../fb/win/golden), nine lines, the session's
  presents in order), and a covered rectangle folds to someone else's
  frame — the stack's order on the display. **Found on the way, fixed
  the same day, the compiler track's** (CHECK.md): the image's shared
  static memory can only park values every pass's table maps for the
  machine's life, and the const thunks' memos parked arena pointers —
  the machine's second consumer of the font's memo (this pass, the
  first consumer's screen pass gone) read a dead pass's heap and the
  fault was the load page fault that named it; the fix is the const
  region (the heap's top 64 KiB, the root's arena ending below it),
  `emo_alloc_const` and the const twins of the string, boxing and
  concat helpers, the const bodies always dynamic so their numerics
  stay static cells; the region's blocks 32-aligned (the tagged
  words' low bits are the tag's — the first boot's index-out-of-bounds
  named it); and the user profile's `emo_fail` crossed the gate at
  last (A7.2's silence: the message rides the write verb whole, then
  the heap-death route — which is what said why, when the first
  const-region boot died before its first frame). **Found on the
  way, fixed, EmoOS T8.13's**: the display service's rect transfer
  posted offset 0 — the fullscreen transfers it had only ever served
  were correct by coincidence, the cursor plane's rect flushes copied
  the carve's top-left bytes into the host canvas at the sprite's
  rectangle, and the uniform backgrounds every earlier golden had
  composited over hid it until the windowed desktop's first drag
  (`offset = (y * width + x) * 4` now). **The pins**: the fb gate 73
  ok (the windows' package type-checked, its targets built, the
  window golden's nine lines byte-identical from the interpreter and
  all five hosted targets, the probe painting a window for the
  metal); `run.sh` green under both timer transports, three
  consecutive rounds byte-identical on both, the ledger `frames 90
  54`; `dune runtest` and `@fmt` green. **Standing**: the shell is
  one process owning two windows — the kill-and-restart acceptance
  (A9.2) is where separate clients make the stack's reclamation
  earn its place; the surfaces' other roles are refused by name
  until a milestone gives them substance (A9.3's increments).
- [x] **A9.2** — The kill-and-restart acceptance: a window stack that
  survives a client's death and rebirth with the machine whole.
  **Landed 2026-11-03** (the kernel side is EmoOS T8.14: the
  dead-owner cell, the reclaim inside the service). The clients are
  branches of the user image's program, the parent block's spawns
  gated by its `read()` yields so every era waits for this run's
  byte: the first client opens a toplevel at (96, 320), declares it,
  paints its own pattern, presents — the composition `comp 96 320`
  carries the client's frame alone — and dies without closing: a
  store to an address its table maps nothing, the fault that is the
  death, `client up <grant>` the last thing it ever said. The
  machine continues: the compositor reclaims the dead owner's frames
  and surfaces at its next composition (`comp reclaim <pid>` on the
  wire), the hand opens the rebirth — a fresh pass, a fresh grant, a
  different place (512, 320) and a different pattern, `client up`
  again, its composition carrying the reborn frame alone, which is
  the reclaim's arithmetic proof: a stuck surface would double the
  carried sum — and the parent's `wait` answering the clean exit is
  `client back`, the stack whole from one era to the next. The
  screendump is the visual half: the reborn window's rows where it
  stands, the dead client's old rect the background — the walk
  cleared the carve and the surface is off the stack — the pointer
  parked out of both rects. **Found on the way, fixed, EmoOS
  T8.14's**: the compositor's flush wait compared the Unknown
  binding against the reply before the op dispatch, and the
  pointer's notice — a raw `op << 32` word wearing the Int64 tag in
  its low bits — queuing while a flush was in flight was walked into
  as if it were a cell; the desk era's first composition died there
  until the dispatch went first. **The pins**: the wire — `client up
  2`, `user fault 26 cause 15`, `addr 0x20000000`, `comp reclaim
  26`, `client up 3`, `comp 512 320 4174893056`, `client back`;
  `run.sh` green under both timer transports, three consecutive
  rounds byte-identical on both, the ledger `frames 104 66`; `dune
  runtest` and `@fmt` green.
- [x] **A9.3** — The five M9 increments the growth contract adds
  (with the assessment's seams as the spec). **Landed 2026-11-03**
  (the kernel side is EmoOS T8.15; with it M9 is complete on both
  sides of the gate). The five, each an addition under a new verb:
  **the roles' substance** (the third seam grown — A9.1's standing
  note cashed in): popup, subsurface and panel implemented, verb 19
  `win_parent(grant, parent)` binding the first two to the toplevel
  they hang from — the coordinates the parent's from the binding on,
  the walk painting each immediately above its parent, a move of the
  parent carrying it, the parent's death taking it (the prune
  cascades), a panel standing alone as the walk's topmost strip and
  refusing a parent by its role; **format is a field** (the fourth
  seam): verb 20 `win_format(grant, format)`, XRGB8888 (0) the first
  accepted value, the rest refused by their number; **scale is a
  field** (the fourth seam's other half): verb 21
  `win_scale(grant, scale)`, 1 accepted first; **the frame callback**
  (the fifth seam): verb 22 `win_frame()`, the caller parked and the
  compositor's answer the tick — the next composition's completion,
  a ring of four full the resource refusal; **the stream's version**
  (the fifth seam's other half): verb 23 `desktop_version()`, the
  gate's own answer, 1. The pass asks for every one knowing the
  answer: the popup presented at its parent's offset and carried by
  the parent's move (the composition naming the absolute place, the
  screendump's model doing the binding's arithmetic), the fields
  answered and refused, the callback's `cb ok` landing inside the
  client era — the pass parks past its own marker now, the parent's
  inline wait retired, the exit code the machine's to keep. **Found
  on the way, fixed, EmoOS T8.15's**: the console's one write stage
  buffer printed the last stager's bytes for two writers parked at
  once — the callback's beat parked two for the first time in the
  machine's life — and the console grew the fs's request-slot shape
  (four slots on the console's own page, the slot's index in a
  per-pid cell); and the dead-owner cell held one death, the parked
  pass's exit overwriting the client's fault before the next
  composition — the dead owners now sit in per-pid cells, one write
  per pid ever, the service's clear unable to race it. **The pins**:
  the wire — `role toplevel r4`, `format 0 ok`, `format 1 r4`,
  `scale 1 ok`, `scale 2 r4`, `protocol 1`, `comp 48 32 2619455488`,
  `popup up`, `comp 400 32 1177728000`, `sub up`, `parent panel r4`,
  `comp 0 736 3644232704`, `panel up`, `parent gone r4`, `cb ok`,
  `client up 5`, `client up 6`; the moved window's composition read
  against the model of all five surfaces; `run.sh` green under both
  timer transports, three consecutive rounds byte-identical on both,
  the ledger `frames 108 70`; `dune runtest` and `@fmt` green.
  **With this M9 is complete on both sides of the gate.**

## M10 — the desktop (the desktop side)

- [x] **A10.1** — The EmoUI fb backend whole: `emo/ui_fb` as the
  sixth backend family, the Elm loop unchanged. **Landed 2026-11-03**:
  the family's proof of membership is the convergence corpus — the
  shared application the other five runtime families run (the counter,
  the form, the scrolled list, the image, the spacer, the events),
  required whole from `emo/ui_corpus` in the fb family's own entry
  ([`fb/corpus/`](../fb/corpus), `emo/ui_fb_corpus_golden`), never
  copied, and run through `ui.run` on the pixel surface — a canvas at
  the baseline mode, the frame golden's Eye on it, the script `0,0,1,2`
  the tui and the debug entries feed. The whole node vocabulary the
  counter never touched — `TextInput`, `Scroll`, `Image`, `Spacer`,
  a column's padding and a row's gap — lays out and paints under the
  loop; every frame's digest prints beside `update`'s state
  transitions (`inc 1` … `submit 1`, five frames, `dec 1` and
  `submit 1` landing on the same count and the same digest as
  `inc 1`), the interpreter's bytes are `expected.txt`, and all five
  hosted targets produce them exactly — the fb gate checks the family
  beside its siblings (staging `emo/ui_corpus` into its registry, the
  checks 73 → 90 ok). The metal's leg is the one it has run since
  A8.3: the same loop, the same backend interface, the carve for the
  surface — `run.sh`'s screen pass and the corpus file the family's
  digests live in. The EmoUI README names the family (EN + zh).
- [x] **A10.2** — The dock and the desktop shell (`emo_desktop`).
  **Landed 2026-11-03**: the shell's chrome is a package of its own —
  [`fb/desktop/`](../fb/desktop), `emo_desktop` (the flat name the
  placement round decided), targets all six, deps `emo/ui_fb` alone —
  the dock painted direct, fills and glyphs through the `Surface`, no
  tree, the window package's shape and reason (the shell repaints the
  dock per focus change; a tree's nodes are arena KiB per repaint on
  the metal). The dock is a **panel surface** at the display's bottom
  edge — the walk's topmost strip, no window over it, the role A9.3
  gave substance — one tile per app the shell runs, the tile in the
  steel a focused window's bar wears when its app holds the focus,
  the one visible fact a focus changes, the app's initial in the
  bitmap font on it. The press policy is a pure def (`press(x, y, w,
  h, count)` → the tile or −1): the shell's pointer handler asks it
  before the window hit test, a strip press names a tile, the tile
  names its app, `win_focus` raises it and the dock repaints with the
  tile lit — a strip press never starts a drag, and no window beneath
  is consulted. The hosted twin ([`fb/desktop/golden/`](../fb/desktop/golden))
  paints the strip onto a canvas the dock buffer's own size (1024×40)
  in its three states — none focused, alpha lit, beta — and probes
  the policy (`tile -1` above the strip, `tile 0`, `tile 1`), the
  interpreter's bytes `expected.txt`, all five hosted targets the
  same; the fb gate stages `emo_desktop` and checks the family (90 →
  107 ok). The metal's desk pass wears the dock: the panel surface
  beside its two windows, its digest lines the corpus file pins (the
  check seeded past the desk era's start, positioned like the
  windows'), `desk_is` growing the strip's own rectangle — skipped in
  the walk, folded to the corpus's digest — and the beta focus beat
  moved from a press inside the window to a press on beta's tile.
  The ledger `frames 111 73` (the dock's three blocks, taken at its
  `win_new`, home at its close); `run.sh` green under both timer
  transports, three consecutive rounds byte-identical on both; `dune
  runtest` (the smoke staging `emo_desktop`, `DOCK_EXPECTED` pointed
  at the repository's file) and `@fmt` green; `fb/check.sh` 107 ok.
- [x] **A10.3** — The first apps: a counter, a file browser, an
  editor — each a corpus package, dual-run where hosted.
  **Landed 2026-11-03**: one family package,
  [`fb/apps/`](../fb/apps) — `emo/ui_apps`, targets all six, deps
  `emo/ui` alone — whose front door (`ui_apps.emo`) names the
  discipline and whose three submodules are the apps: `counter`, the
  Elm architecture's own example (the count, the two buttons); `files`,
  the browser (the listing the model's data — the seed names the
  desktop's own three sources — the selection down and up, `open`
  announcing); `editor`, the two-row buffer (the puts typing into the
  cursor's row, `newline` moving it). Each is a corpus package in
  `emo/ui_corpus`'s discipline: portable defs, nothing platform-naming,
  a pure `update` that says each transition, tags registered in the
  view's own order — add/sub, down/up/open, put_a/put_b/newline, fixed
  on every run. The trees are the metal's measured budget (A8.3's
  per-event count): the sessions sized to the pass's 128 KiB arena.
  The hosted twin ([`fb/apps/golden/`](../fb/apps/golden)) runs the
  three on canvases the app window's own size (384×128, the window
  shell's), each through `ui.run` with a script in the input's seat —
  the sessions the metal's passes run byte for byte — every frame's
  digest and every transition one line, `app <name> 0` closing each
  block; the interpreter's bytes `expected.txt`, all five hosted
  targets the same; the fb gate stages `emo/ui_apps`, checks the three
  apps, pins each one's riscv64 lowering (107 → 130 ok). The metal's
  leg: three passes in the boot image, each a window of its own by
  `win_new`, declared a toplevel, placed, and the Elm loop run over the
  window buffer's surface (the desk pass's `Win`) with the app's defs
  as values and the merged stream in the input's seat — `AppKeys`, the
  byte table whose tag is an index, `q` the loop's end. Spawned after
  the shell's quit, one at a time, the exit answering the parent's
  wait (`app <name> 0`, the golden's own closing line). The wire's
  transitions are `println`'s — which is the round's find: **the user
  profile's print was silent**, `println` lowered for riscv64 since
  ever but a user pass's bytes falling into the legacy SBI ecall whose
  `a0` the gate reads as a buffer address and refuses — the silence
  A7.2's first frame found and left (`emo_fail`'s announce unheard
  since). The user boot stub now parks the console hook (T3.5's own
  mechanism): every byte the runtime prints rides the gate's write
  verb from a one-byte scratch in the image's .bss — the cells page
  refused by the gate's `check_write` (the first park's byte died at
  the range check; the gate admits only the caller's own segments),
  the .bss the writable segment it admits, the copy interrupt-masked
  so no other pass's byte lands between the store and the read. And a
  second find left to its track: **`ArrayBuilder` is not lowered on
  riscv64** — the browser's and editor's first drafts grew their
  arrays with it and the emitter refuses by name; the apps went to
  literals of their own fixed shapes, the lowering itself the compiler
  track's. `run.sh` grows the apps' eras: the three passes' frames the
  corpus file pins (ten digests, the seeded scan ending before the
  editor's exit — the repeated number the counter's sub returning its
  mount's frame, the search past the last), the transitions and exits
  in the ordered list, the comp echoes at the apps' own places, and a
  new eye (`app_is`) folding each app's rectangle at the mount and the
  session's last frame, the pointer parked off every app's place.
  The ledger `frames 132 91` (the three passes: each spawn's stack and
  arena run and table, each window's block at `win_new`, home at the
  closes and exits); `run.sh` green under both timer transports, three
  consecutive rounds byte-identical on both; `dune runtest` (the smoke
  staging `emo/ui_apps`, `APPS_EXPECTED` pointed at the repository's
  file) and `@fmt` green; `fb/check.sh` 130 ok. **With this M10 is
  complete.**

## M11 — honest multi-app (the desktop side)

- [x] **A11.1** — The corpus apps become disk ELFs in place: loaded
  by the filesystem, per-image segment tables, per-process gate
  checks (the kernel-side record is EmoOS's T8.16).
  **Landed 2026-11-04**: the three corpus apps left the boot image —
  each a program of its own, a disk ELF the machine installs and
  execs. **The packages**: one program tree per app
  ([`fb/apps/counter/`](../fb/apps/counter),
  [`fb/apps/files/`](../fb/apps/files),
  [`fb/apps/editor/`](../fb/apps/editor)) — a `main.emo` whose whole
  body is the session the boot image's token branch ran (A10.3):
  `win_new`'s window of its own, declared a toplevel, placed, the Elm
  loop over the window buffer's surface, `win_close` behind the quit
  key, the exit answering the parent's wait — plus one shared package,
  [`fb/winbuf/`](../fb/winbuf) (`emo/ui_fb_winbuf`, riscv64 alone):
  the window buffer's metal side — the raw pixel defs over a
  `win_new` run, the byte table in the merged stream's seat, the
  digest line (`frame <n>`, the corpus's own) the present says first —
  the constructors defs, a riscv64 program naming no other module's
  class in value position. The apps' sources of truth are unchanged:
  `emo/ui_apps` still owns every model, update, and view; the golden's
  bytes are the sessions' bytes. **The flow**: the parent (the boot
  image's top level) execs each by name after the shell's quit, one
  at a time — `syscall.exec("counter.elf")`, `wait`, the answer line
  `app counter 0`, the golden's own closing line — the kernel reads
  the volume, loads the image, and the window is the only one up, the
  mount's frame on the wire the moment the loop mounts. **The disk is
  their home**: the first boot installs the three images onto the
  volume it formats (`installed <name> <size>`), the boots after find
  them (`kept <name> <size>`) — the execs always load off the disk,
  nothing of the apps remains embedded in the boot image (its
  `package.emo` dropped `emo/ui_apps`, the image 18 KiB lighter). The
  wire's sessions are the hosted twin's byte for byte: the counter's
  mount, add, sub (the sub returning its mount's frame), the
  browser's down and open, the editor's puts and newline, the
  screendumps folding to the corpus's digests at the mount and the
  session's last frame. **The pins**: `run.sh` green under both timer
  transports, three consecutive rounds byte-identical on both; the
  install/kept/image lines pinned by shape and place (the sizes are
  the build's); `dune runtest` green (the smoke builds the three
  program trees and winbuf into its registry); `@fmt` green;
  `fb/check.sh` 134 ok (the winbuf and program lowerings pinned). The
  kernel-side record — the verb, the loader, the per-image tables and
  the per-process checks — is EmoOS's T8.16. **A11.2's two-image
  desktop is the next acceptance.**
- [x] **A11.2** — The multi-image acceptance: two apps, two images,
  one desktop, the golden's hands (`sendkey`/`mouse_move`) driving
  both. **Landed 2026-11-04**: the duo — the browser's image and the
  counter's exec'd in sequence, both resident, both windows
  composited side by side. The focus routing is the keystone: each
  app focuses itself at its mount, the click raises through the
  compositor's press cell and the walk's topmost hit, and the
  stream's bytes and keys are the focused surface's owner's — the
  input service holds a read the focus does not name (four seats on
  the handoff page's tail), judges by the focus's grant row's owner,
  and re-judges at the kicks (the display's close and the comp's
  reclaim `gate_post` the input service; the gate_post wake reaches a
  device-waiting service too). The golden drives both sessions — the
  counter's keys on the serial's bytes, the click the other hand, the
  exits answering the parent's waits in the waits' own order (`app
  counter 0`, `app files 0`, the hosted twin's closing lines) — and
  the editor's era runs alone after. The kernel side is EmoOS T8.16's
  growth (the private handoff page per image, the shim's arena hand
  per-pid through the record, `exec.entry_for`, the exec page's
  layout shift). **The round's find — the ghost rows**: the
  compositor's staging cells (`comp_svc_cell`, `comp_args`, the
  pointer cells, `input_args`) sat inside the grant table's span (the
  table's eight 112-byte rows end at +0x2e80; the cells started at
  +0x2e00) — every compositor verb staged its arguments into rows 6
  and 7, and the judge's `grant_row_of` matched a staged present's
  grant as a live row owned by nobody, holding the unfocused
  reader's read forever after the real row's close. The routing
  cells moved past the table's true end (+0x80; trap.S's two
  hardcoded routes with them), and run.sh's wire-order check learned
  the frames' rule (each line searched past the previous match — the
  desk era's beta and the duo's counter share `comp 576 384`). The
  pins: `run.sh` green under both timer transports, three consecutive
  rounds byte-identical on both; the ledger `frames 795 734`
  unchanged; `dune runtest` 340 green; `@fmt` green; the fb gate 134
  ok. **With this M11 is complete on both sides of the gate.**

## M12 — the desktop shell era (opened 2026-11-05)

A12.1 served this milestone before the section existed — the app
image profile, the sizing the exec world's structure asked for — and
the era the archived prototype carries is the desktop's own: the
dock's tiles launching the disk ELFs, the exits lighting the tiles
out. The README's milestone rows wait for completion (the trackers'
rule); CHECK.md's "remaining work" list (2026-11-05) mirrors what
follows beside the kernel's and the compiler's.

- [x] **A12.1** — The app image profile: the disk ELF's own image
  shape — the user world's stub, load address and linker script over
  a 2 MiB heap, `--profile app` at the three build sites — the
  counter's span 12.24 → 6.24 MiB, the image run 196 → 100 blocks of
  the region's ~500, three residents fitting beside the desktop's
  own surfaces; the ledger 795 734 → 507 446. Landed 2026-11-05
  (`9f7eaa4`), the golden byte-identical under both timer transports
  across three consecutive runs and `dune runtest` 340 green; the
  decision record — including the next lever parked there (the
  process world's 64 slots and 4 MiB per-process stacks, ten asm
  sites) — is CHECK.md's (2026-11-05).
- [x] **A12.2** — The desktop shell era, the desktop side's
  acceptance: three tiles on the dock launching the three disk ELFs
  by the click, the exit event ring lighting each tile while its app
  runs and extinguishing it at the exit, the shell's REPL growing
  the feed/exec commands, and `run.sh` carrying the era's golden —
  the tile click → `up` → session → exit lines. Landed 2026-11-06
  from the archived prototype (2026-11-05,
  `protected/tmp/20261105-a12-prototype/`) beside EmoOS T8.19, the
  kernel-side half of the same era: the desktop takes the foreground
  for its life after the desk pass's exit — the banner and the
  prompt its own face, the dock's three tiles the whole launcher, a
  tile's click the counter's session, the REPL's `exec` the other
  two, each `up` line and dot on the wire, the exits
  `desktop <name> exit 0` riding the merged stream to a shell that
  never waits. The dock learned residency: `paint`'s running mask,
  a 4×4 ink dot at a running tile's foot (the hosted twin's seven
  residency digests beside the desk era's three), and the press
  policy widened to three tiles. The shell's line assembly became
  the feed — the byte-at-a-time shape the blocking read rode, driven
  by the desktop loop's stream events now, the echo included. The
  landing's finds on the desktop's side: the editor's window kept
  the duo's place (the launcher's is `48, 272`), and the shell's
  text cells overlapped once `exec` grew the help line past the
  prompt's seat (every text from the prompt on moved eight up, and
  `m_badarg`'s first byte was a typo in the archived table). The
  pins: `run.sh` green under both timer transports, three
  consecutive rounds byte-identical on both, the trio and the
  empty-dock screendumps folded against the corpus; the ledger
  `frames 510 446`; `dune runtest` green with the smoke (352);
  `@fmt` green; the fb gate green (112). **With this M12 is
  complete.** Decision record: CHECK.md, 2026-11-06.

## A13 — the macOS face: wallpaper, header bar, desktop icons (opened 2026-11-06)

The desktop after boot looks like a desktop: a header bar at the top
edge, the dock at the foot, a wallpaper with the desktop's icons on it
— the volume's own files as documents, a name's `/` prefix as the
folder that prefix names, entered by a press and left by the `..` cell
the view grows. The kernel's half is EmoOS's T8.27 (role 4, the
background press's focus).

- [x] **A13** — The desktop's own canvas: the wallpaper (role 4, the
  walk's undermost layer — the gradient and the ribbons the package
  paints, the icons over it), the header bar (a second panel, the
  wordmark in the boot banner's cyan, the running count its one live
  fact), and the icon view whole: the volume's listing parsed into
  documents and prefix-folders, `.elf` never on the desktop (the dock
  names apps), a press selecting a document, entering a folder, or
  leaving by `..`, the listing refolded after every volume-touching
  command with an unchanged fold costing one list and one fold. The
  round's find: the first icon press died the second repaint — the
  `Surface`'s methods are class bodies, and a class body's boxes stay
  in the arena for good ("left in the arena per repaint" was the
  dock's own warning); the metal's painting moved to typed top-level
  defs stamping the buffer's bytes through the carve's own primitives,
  and a repaint costs no arena at all. A folder entered at the root
  wrote its prefix one byte past the buffer's head — the separator's
  slot taken when no prefix stood there — and the child view matched
  nothing; the separator writes only when a prefix separates. The
  golden grew the package's new painters (wallpaper, header, icons,
  the byte-name walk, the square root, the cell layout and the hit
  test) on the hosted canvas; `run.sh`'s display model grew the same
  arithmetic — the gradient, the ribbons (the metal's division
  truncates, the model divides the metal's way), the header, the
  shapes and the names from the font's own table — and the folder
  beats drive the entered state's screendump. The fb gate green (134,
  untouched); the golden byte-identical across every hosted target.

## M14 — the HD desktop (opened 2026-11-06)

The pixel era's face becomes a modern one: antialiased type from real
typefaces, rounded and shaded surfaces, translucent chrome, at
1920×1080. A13 took the ladder's thirteenth rung as a single task, so
the milestone is the fourteenth. The kernel's half is
[EmoOS Step 9](../../emo-os/docs/TASKS.md). The tasks run in order,
each leaving the tree green and every golden re-pinned to its own
pixels; the reasoning behind the decisions is CHECK.md's (2026-11-06).

The decisions (2026-11-06):

- [x] **D6** — The mode: 1920×1080 XRGB8888, superseding D5. The
  carve is sized to it, and every size the desktop paints derives from
  the mode — never a constant.
- [x] **D7** — The type: real typefaces rasterized at generation time
  into 8-bit coverage tables — Inter (SIL OFL 1.1) for the interface,
  an OFL-licensed monospace face where the cell arithmetic lives (the
  shell, the editor). Pillow's FreeType is the rasterizer and the
  rasterizer's dependency alone: it writes a reviewable coverage grid,
  the stdlib generator writes the tables from the grid, and the gate's
  drift check never needs Pillow.
- [x] **D8** — Translucency without blur: chrome over the wallpaper
  computes the wallpaper's own formula under a scrim. No blur pass
  anywhere; the wallpaper stays procedural.
- [x] **D9** — Motion deferred: stills first. Animation is a milestone
  of its own once a 1080p repaint's cost is measured.

- [x] **A14.1** — The primitives — **complete 2026-11-07**. The
  `Surface` grows three verbs over one shape, the rounded rectangle (a
  plain rectangle at radius 0, a pill at half its height, a circle when
  square at half its side): `rounded` composites one graded from `top`
  down to `bottom`, `stroke` the ring `width` pixels deep inside one's
  edge, `shadow` one whose edge fades over `soft` pixels — colors
  carrying their opacity in the top byte, as `blend`'s do. `ui_fb`'s
  shapes section holds the arithmetic every surface asks per pixel:
  the signed distance from a pixel's center to the edge in 256ths
  (`shape_sd`, the corners' arcs through an integer square root), a
  fill's one-pixel ramp, a stroke as the fill less the fill pulled in
  by its width, a shadow's smoothstep (its position in 4096ths, so the
  cube fits 64 bits at any softness), the per-channel grade. Each
  surface walks a row in from both ends while its pixels are partly
  covered and stores the whole ones between as one span — the hosted
  canvas over its `Bytes`, the window buffer package over raw words
  (`ui_fb_winbuf.carve_rounded` and kin, two coordinates packed to a
  word under the target's eight-word call). The boot image's `Carve`
  and `Win` call the package's walks rather than copying them — the
  first metal code the boot image shares instead of mirroring; it
  gains the dependency the launcher's registry and the dune smoke
  already staged. Two pieces moved: the coverage blit to A14.2 (its
  data's layout is the glyph tables'), and the general ellipse out —
  the circle and the pill are the rounded rectangle, and every shape
  is four copies (the canvas, the carve, `run.sh`'s model, the
  compositor's own for T9.2). The acceptance: `fb/shapes/`, one card
  painted in eight stages — plain, graded, translucent, fading, the
  title bar's three circles, three strokes, two shadows, every clipped
  edge and the degenerate shapes — the same eight `shapes <digest>`
  lines from the interpreter and all five hosted targets; the core's
  assertions 39 → 69 and the canvas's 35 → 57, every expected value
  worked by hand; and on the metal, a scratch tree whose counter ELF
  painted the card through `Win`, exec'd from the desktop's REPL,
  printed the golden's eight lines byte for byte. The cost on the
  metal (QEMU's TCG on the development Mac, ten passes over 1024×512
  per verb): opaque fills about 15–19 ms a megapixel, translucent
  compositing about 290 — `over`'s three divisions by 255 per pixel;
  the chrome that wants to be cheap is opaque (D8), and the lever is
  on record in CHECK.md. The round's finds: the beam emitter let an
  `if` arm's or a `receive` branch's bindings into its siblings' loops
  (fixed and pinned — `examples/branch_var`, a beam receive test), and
  `win_close` leaves the closed run mapped (EmoOS T9.3). The pins: the
  fb gate 151 ok (134 before); `dune runtest` 371 green with the
  smoke; `@fmt` green; `run.sh` green under both timer transports in
  three consecutive rounds, the serial logs identical line for line
  with the unchanged tree's but for the apps' image sizes and where
  the REPL's prompt lands against the editor's `comp 48 272` line — a
  race the unchanged tree shows across its own rounds (CHECK.md); the
  ledger `frames 666 551` unchanged. Decision record: CHECK.md,
  2026-11-07.
- [x] **A14.2** — The type — **complete 2026-11-07**. D7's pipeline
  whole: Inter 4.1's static Regular and JetBrains Mono 2.304's Regular
  vendored in `fb/fonts/` beside their SIL OFL 1.1 texts and pinned by
  SHA-256; `glyphs/rasterize.py` (Pillow's FreeType, run as
  `uv run --with pillow`, never by the gate) renders three strikes —
  `ui16`, `ui24`, `mono16` — into `glyphs/coverage.txt`, one character
  a pixel at sixteen levels (`.` and `1`–`f`), the reviewable grid the
  hand-drawn `glyphs.txt` was (retired with the cell it drew); and
  `glyphs/gen.py`, the standard library alone, writes `font.emo` whole
  from the grid — one meta word per glyph (advance, ink offsets, ink
  size, base), the coverage two pixels a byte and eight a word, in
  chunks of 448 words because a const array's elements spill through
  one frame on the metal — with `--check` the gate's drift check. The
  coverage blit landed as the `Surface`'s `ink(x, y, strike, glyph,
  color)` in place of `glyph`: the glyph at the pen (the line box's
  top-left), each pixel composited at its own coverage, the color's top
  byte unread (opaque ink); the metal's walk takes a coverage word at a
  time (`ui_fb_winbuf.carve_ink`, the boot image's surfaces delegating
  as they do the shapes). The box model measures a label in its
  glyphs' advances and the strike's line box (20 at `ui16`); the
  desktop's tiles center their initials by the measure, the header
  centers its text in the bar by the line box, the count sums its
  digits' advances, and the names walk by advance. The acceptance:
  the core's assertions 69 → 76 and the canvas's rewritten from the
  grid (a capital `A` advancing 11 with its ink 11×12 four rows down,
  a partial pixel composited to `0x877E75`), every value worked by
  hand and passing on the first run; the fb gate 151 ok on all six
  families; `run.sh`'s display model inks the same tables at the same
  coverage over what each pixel already shows, and three rounds under
  both transports are green, the screendumps modeled to the pixel; the
  ledger `frames 666 551` → `688 572`. Finds and costs (CHECK.md,
  2026-11-07): two of the compositor's old sum pins split and were
  remapped by place; the tables lower as code and static cells, ~288
  KiB an image — the compiler lever is on record.
- [x] **A14.3** — The mode, the desktop's side — **complete
  2026-11-07** (the kernel's half is EmoOS T9.1). Every mode-shaped
  size the desktop paints derives from the mode now: the wallpaper's
  ribbons are fractions of w and h whose 256ths and 128ths reproduce
  the 1024×768 drawing they were tuned at exactly (the slopes stay the
  art's own), the same formula in the metal's typed mirror and
  `run.sh`'s model; the panel proof's strip is the mode's own width at
  the display's bottom edge; and the apps place their windows from
  `output_info` — the counter dead center, the browser and the editor
  its upper-left and lower-left quadrants. The chrome's own sizes (the
  24px header, the 40px dock, the 96×76 icon cells) stay the face's
  design sizes — A14.4 redraws them; the desk pass's two demo windows
  keep their absolute places, and the drag targets with them. The
  goldens re-pinned at 1920×1080: the frame golden and the corpus's
  canvases, the dock's strip, the wallpaper's digest, the cell and hit
  probes — the frame digests the metal prints still come off the same
  files. The finds: the bare pins (`comp 576 384`) had been
  prefix-matching the compositor's summed lines all along, so the
  remap split the desk window's and the counter's by position; the
  screendump header grew a byte (`P6\n1920 1080\n` — offset 16 → 17).
  The acceptance: `run.sh` at the mode green under both transports
  three rounds, the launch-era and desktop-era screendumps modeled to
  the pixel, the fb gate green, the ledger `frames 771 573`. Decision
  record: CHECK.md, 2026-11-07.
- [x] **A14.4** — The chrome — **complete 2026-11-07** (the kernel's
  half is EmoOS T9.2, with T9.3 beside it). The header bar and the
  dock are translucent material over the wallpaper by D8's formula:
  the chrome recomputes the wallpaper's own art at its rows — the
  gradient and every ribbon whose span reaches it — under a scrim
  (the header's 0xB41E1E26, the dock's 0xB424242C), sampling the
  formula and never the pixels behind it, so a window that slides
  under the chrome shows the wallpaper the chrome always believed was
  there. The dock is a rounded shelf with its shadow: a translucent
  slab (6, 3, w−12, 34) at radius 12 floating on the material, its
  soft shadow beneath, the tiles drawn icons on it — rounded squares
  graded top to bottom (the focused app's lit steel, the rest quiet
  slate) carrying the app's initial in the interface face, the
  running dot at the foot — no image assets anywhere. The desktop's
  document and folder icons are drawn the same way (the page a graded
  rounded square with its folded corner and line pills, the folder's
  tab and graded body), the selection a rounded translucent card. The
  wallpaper stays the art it was (its digest unchanged); the chrome
  can recompute it, and does. The metal's painting moved to typed
  twins of the package's painters (`desk_chrome_row`, `desk_bar_paint`,
  `desk_dock_paint`, `desk_strip_paint` — the material's rows, the
  shelf, the tiles, all through the carve's own primitives, no
  interface call in a repaint), and the corpus's window digests became
  the round fold (`round_digest`, the corner squares the walk masks
  set aside). The pins: the dock's strip, the bar, the icons' goldens
  re-pinned on the interpreter and all five hosted targets; the fb
  gate green; `run.sh` under both transports three rounds — the
  strip's fold matching the corpus's bytes on the metal's screen. The
  finds (CHECK.md, 2026-11-07): the boot image's own `Win` predates
  the winbuf package, its present's digest a site of its own; the
  quadrant windows yield their shadows ten pixels of clearance.
- [x] **A14.5** — The windows — **complete 2026-11-07** (the kernel's
  half was EmoOS T9.2, landed with A14.4). The shared title bar: the
  three traffic-light buttons (the shapes' card's own circles, full
  color when the window holds the focus — 0xFFFF5F57, 0xFFFEBC2E,
  0xFF28C840 — one quiet gray 0xFFC0C0C6 when it does not), the title
  in the interface face centered on the bar, the bar's papers
  0xFFF4F4F6 and 0xFFE6E6EA, the hairline at the foot — the two states
  the shell's windows live in, both pinned by the window corpus's
  session. The counter, the browser and the editor are reskinned onto
  it through the `Chrome` — the content surface under the bar, every
  paint of the app's landing `bar_height()` lower, the bar painted
  once at the mounting, the Elm loop seeing a surface of the content's
  own size; the state the apps' bars wear is the launch's (the machine
  focuses the new window's reader — the keys reach it before any
  click — and no wire yet tells it when the focus moves on, the dock's
  lit tile's own gap). The pointer is redrawn as an antialiased
  sprite: the grid speaks the font's sixteen levels of coverage, the
  partial cells the outline's ink at its own coverage, the upload
  writes `(coverage << 24) | ink` and the compositor's plane blends
  (T9.2's arithmetic), the model of the display blending the same
  words over its background arithmetic — the pixel walks verify the
  partial cells at every beat. The finds (CHECK.md, 2026-11-07): the
  upload's shift is the coverage's own, not the alpha's (`0xFF000000 +
  coverage` put the coverage in the blue lane); the `apps_is` model's
  sprite blends over what the pixel would show without it, shadow
  rings included. The acceptance: the window and apps corpora
  re-pinned on the interpreter and all five hosted targets, the fb
  gate green, `run.sh` under both transports three rounds. M14
  complete.

## M15 — motion (opened 2026-11-08)

D9's deferral cashes in: the tick (EmoOS T8.18) and the frame callback
(verb 22) are the rhythm an animation rides, and A14.1 put the app
side's painting costs on record — but the number an animation actually
lives on is the composition's own, and that was not measured. The
milestone opens with the measurement; the first animation's subject and
the damage question wait for it. The kernel's half, if the numbers name
one, is [EmoOS Step 10](../../emo-os/docs/TASKS.md) — unopened until
they do. The reasoning is CHECK.md's (2026-11-08).

The decisions (2026-11-08):

- [x] **D10** — The budget measured before anything moves: the
  per-composition cost at 1080p is what every animation and every
  compositor mechanism rides, and neither an animation's subject nor a
  kernel mechanism is chosen before it is on record. A15.1 measured
  it; whether the compositor grows damage rectangles, and what moves
  first, are the decisions the number now informs.
- [x] **D11** — The compositor grows the damage rectangle (EmoOS
  [T10.1](../../emo-os/docs/TASKS.md), landed 2026-11-08): the number
  named it and nothing else — a whole-screen recomposition at ~230 ms
  carries no motion, and a window-sized one at 27–44 ms (median ~36)
  does. The kernel's half is [EmoOS Step 10](../../emo-os/docs/TASKS.md);
  the desktop's half — what moves first — is the milestone's remaining
  decision.

- [x] **D12** — The animation's pacing is the present's own reply:
  the composition's completion is what the reply waits for, the frame
  budget the damage rectangle measured (~36 ms a window-sized frame).
  The frame callback cannot pace a solo animation — its park answers
  at the next composition's completion, and the only composer is the
  parked client itself: a park before the first present waits on
  itself. The callback's seat stays what T8.15 proved (a client that
  has already presented reads the next completion); the rise rides the
  reply.

- [x] **A15.1** — The composition's cost, measured; the blend's
  division retired — **complete 2026-11-08**. The measurement is the
  machine's own beats, host-timestamped the way A14.1's probe was: a
  scratch windowed pass (installed the disk ELFs' way — T8.21's path,
  the blob beside the boot image, the handoff page's free tail at
  `0x87002210`, the install line, `exec probe.elf` from the REPL)
  brackets its work in serial markers — `m pre`/`m post` around a
  `win_move` (state alone, op 16, the mailbox's own round trip) and
  `pre`/`post` around a `present` (op 17, whose reply lands only after
  the compositor has walked the stack and flushed) — and a watcher
  stamps every serial line as it lands. The beats ran on the desktop's
  own stack (wallpaper, header, dock, the probe's 384×256 window at
  the mode's center), ten compositions and ten moves. **The numbers**:
  a whole-screen composition costs **about 230 ms** (226–274 across
  the ten beats, median 230.4) — a full present round trip median
  235 ms, the client's own digest of its buffer about 4 ms, and the
  mailbox round trip 6–17 µs (the parity-refused odd move about
  130 µs) — three to four orders below the walk, so the composition's
  cost is the walk and the flush, not the messaging. The arithmetic
  the number implies: about 2.2 M words walked in about 220 ms of
  bracket, **about 100 ns a word** under QEMU's TCG — so a whole-screen
  recomposition is ~4 fps and carries no motion, while a 384×256
  window's own damage (two rects a step, about 0.2 M words) projects
  about 20 ms plus a rect flush — roughly 30 fps within reach of
  damage rectangles (the projection is arithmetic on the measured
  per-word cost, not a measurement). **The blend's division retired**:
  the lever CHECK.md has carried since A14.1 —
  `(v + 127) / 255 == ((v + 128) + ((v + 128) >> 8)) >> 8` for every
  `v` the mixers see — adopted at the four sites that still divided
  (`ui_fb.mix`, `ui_fb.cover`, the kernel's `comp_mix`, `comp_cover`):
  `+128` **replaces** the `+127`, the shifts stand in its place, every
  consumer's lock regenerated (sixteen, the T8.20 lesson's shape).
  **The find that caught the first application**: the identity's `v`
  is the value *before* the `+127` — the first edit kept the `+127`
  and added the `+128` beside it, a bias of half a step on most
  blended pixels, and the goldens named it — the fb corpus's bytes
  differ on every hosted target (the gate's FAIL lines were lost to a
  truncated pipe read and the round misread the gate as green), and
  `run.sh`'s first-frame digest made it unmissable: the metal's frame
  2525495889 against the corpus's 511863226. The diagnostic instrument
  is a scratch bare-metal probe that computes both forms over the
  domain and counts the mismatches: the standalone identity 0
  mismatches at 65,026 values, the misapplied mix 2,432 at the sampled
  lattice (first at s=0, d=15, a=15 — division 14, misapplied 15),
  the corrected mix 0 across the lattice, cover 0 beside it. **Found
  on the way, fixed**: `start.sh`'s auto-ride still waits for
  `pointer 512 384` — the 1024×768-era center, stale since T9.1's
  mode — and stalls the ride at the pointer beat on every 1080p boot;
  the beat waits for `pointer 960 540` now, the mode's own center.
  The pins: the fb gate green (151, sixteen locks regenerated),
  `run.sh` green under both timer transports three consecutive rounds
  byte-identical on both, the full `dune runtest` green, `@fmt` green.
  The scratch instruments (the probe package, the install lines, the
  driver, the stamps) are not committed; the numbers are the record's.

- [x] **A15.2** — The first animation — **complete 2026-11-08**. The
  three apps' windows rise into place on open and sink on close: the
  window mounts a quarter of itself low, the landing frame the app's
  own hand paints (the mount's tree through a throwaway registry —
  the same walk, the corpus's digest unchanged), and the Win's own
  `rise` eases it home across eight frames, the offset's square
  decaying (the metal's division truncating the model's way), the
  last move landing the final seat unpainted for the loop's mount;
  `sink` is the mirror easing in, every frame on the wire, the window
  a quarter low when the close takes it and the desktop's next
  composition gives its rect to the wallpaper's. The rise is the
  window's own height by four — the mode's arithmetic, never a
  constant; the steps eight. The pacing is D12's: move, present, the
  reply — each frame's composition the damage rectangle's own budget,
  the machine's tick keeping the residents live under it. **The
  golden's shape**: the slide's comp lines pinned with their sums —
  single-client beats, identical across the transports — and the
  launch-era dock and header re-presents pinned by position alone:
  they race the rise's marks (the scheduler interleaves a client's
  move into another's pending box), so their sums are the scheduler's
  own, varying across rounds exactly there — A14.1's recorded race's
  shape, the assertions indifferent. The mid-flight screendump was
  tried and retired: the await's tenth-of-a-second poll and the
  monitor's hundred-millisecond dump against frames ten to forty
  milliseconds apart — the dump lands frames late, the wire's comp
  lines are the intermediate frames' record. The finds (CHECK.md,
  2026-11-08): the throwaway registry's tags register in the view's
  own order, the indices the loop's registry agrees with; the launch
  era's comps are the box's words, whoever's marks are pending. The
  pins: `run.sh` green under both timer transports three consecutive
  rounds (the slide's sums identical across both; the variance only
  at the unpinned launch-era pair), the full `dune runtest` green,
  `@fmt` green, the fb gate green (the winbuf's five consumer locks
  regenerated). Decision record: CHECK.md, 2026-11-08. M15 complete.

## M16 — the window's own menu (opened 2026-11-08)

The bar the A14.5 shared title bar painted wore three traffic lights
painted by no one's hand and hit-tested by no one's code — decoration.
The milestone makes the bar's chrome live: one round button, and the
dropdown it opens — Maximize, Minimize, Quit — the window manager's
verbs the app's own grant may call, on a wire the protocol grew for
exactly this. The kernel's half is [EmoOS Step 10](../../emo-os/docs/TASKS.md)
(T10.2 the press-at, T10.3 the minimize and the desktop's open, T10.4
the scale's values). The reasoning is CHECK.md's (2026-11-08).

The decisions (2026-11-08):

- [x] **D13** — The menu belongs to the app, once, in the seat: the
  gate's owner checks make the window's grant the only legal caller of
  its own verbs, so a shell-side menu could raise the verbs it named
  but never call them; the seat the three apps share writes the menu
  once and every window wears it. The button lives at the bar's left
  where the lights were; the menu's words are English (the system's
  own face is ASCII — a Chinese menu is six new 16×16 glyphs and the
  font pipeline's regen, decidable later); Maximize is the scale
  seam's own growth (the largest whole multiple the work area holds,
  the move beside it — never a stretch, never a fake), Minimize is the
  kernel's hidden entry with the dock tile for the way back, and Quit
  is the session's own end the `q` byte already spoke.

- [x] **A16.1** — The one-button bar — **complete 2026-11-08**. The
  three lights' colors and their loop retire from `paint_bar`; one
  round button takes the bar's left, the bar's own ink (dark when the
  window holds the focus, quiet gray when it does not), and the
  button's rectangle is four defs the paint and the seat's hit test
  read together — one place, no drift. The shapes' card keeps its own
  three circles (the primitives' card follows nothing).

- [x] **A16.2** — The menu, the press-at, the seat — **complete
  2026-11-08**. The pointer driver pushes a second word behind every
  left-button press: the **press-at** (type 4, the position the axes
  last named, packed raw), served to the focused window's reader by
  the focus's own verdict — no pointer-move fanout, no race with the
  panel's exemption. The seat grows the menu: a popup surface hung
  from the window by the roles' own binding (role 1, `win_parent`),
  moved to the button's side, the paper and hairline and three items
  inked, the commit raw (no frame line — the menu's frames are the
  compositor's comp lines). An item's press acts; the menu's pads and
  the world outside dismiss; the kernel folds a losing window's
  popups at every focus move (a menu whose reader's attention moved
  has no one left to dismiss it). The seat's mutable state rides the
  image's writable segment as cells (a class's fields are its init's
  alone) — the discipline the boot image's shell has kept since A12.
  The apps change one constructor call; no app writes a line of menu.

- [x] **A16.3** — Minimize, and the dock tile's way back — **complete
  2026-11-08**. The minimize hides the toplevel: the compositor's
  hidden word rides the stack beside the painted records, the walk
  skips the entry and everything hanging from it, the press's raise
  never hits what it cannot show, the entry stays (the position and
  the grant are the restore's own memory), the focus falls to the
  window beside it, and the composition the minimize's own reply
  carries lands the disappearance whole before the answer. The dock
  tile's click on a live app is the desktop's open now (`win_desk_open`,
  by pid, the panel the authority): the window raised, focused, the
  hidden one unhidden first — the `desktop <name> running` line stays
  the answer only for a pid whose window is not on the stack yet.

- [x] **A16.4** — Maximize, the scale's own multiple — **complete
  2026-11-08**. `win_scale` accepts the whole numbers (the seam's
  recorded shape, its values grown): the walk carries the buffer at
  the multiple, nearest neighbor, the scaled blit's word pairs never
  straddling a source pixel at even scales and gathered one-for-one
  across the boundary at odd ones, the mask's arcs at the carried
  size, the radius the walk's own design constant at screen scale.
  The seat computes the multiple from the work area (the mode over
  the header's and the dock's strips), pairs the scale with the move
  to its center (the even x the blit's word pairs keep), and the pair
  again restores — the repaint riding the present the pair ends on.
  The proof chain's strictness flips with the wire: scale 2 answers
  ok now, scale 0 is the refusal.

**The golden**: the menu's open, the maximize, the restore's menu at
the carried seat, the restore, the minimize's compose, the desktop
open's, and the menu-quit's session end — every comp line pinned with
its sum, identical across the timer transports; the click coordinates
the device's own 0..32767 axes named through the inverse of the
guest's scaling. **The finds** (CHECK.md, 2026-11-08): the exit
event's delivery waits for the machine's next input event when the
desktop goes silent — the golden's beat texture (the pointer back to
its park after every click) provides one, as every pre-A16 beat's
motion did; the desk_open's position print read the raised entry's
stale slot; `comp_stack_add` never cleared a reused slot's hidden
word. The pins: the fb gate green (151), `run.sh` green under both
timer transports three consecutive rounds byte-identical on both, the
full `dune runtest` green, `@fmt` green. Decision record: CHECK.md,
2026-11-08. M16 complete.

- [x] **A16.5** — The bar's drag — **complete 2026-11-09**. A press
  beside the button arms the hand: the offset the window keeps to the
  pointer (screen-space, the scale never in it — the maximized window
  drags as the block it is), and the driver's move-at steps move the
  window with the pointer — the seat's own `win_move` per step (the
  coordinates it keeps true for the menu and the maximize beside),
  the even x the blit's word pairs keep, the present the live frame,
  the release the disarm. The kernel's half is
  [EmoOS T10.5](../../emo-os/docs/TASKS.md). The golden drags the
  counter there and back — the two steps' comp lines pinned with
  their sums, the window standing at its landing seat again.

## M17 — the type at any size

The rasterization moves into the OS: the faces travel as quadratic
outlines in generated modules, a rasterizer in Emo strikes any glyph
at any pixel size on first use, and the strike the result lands in
lives as long as its app. The decisions are D7 through D12 in
[the design](typeface.md); the text below is the ladder.

- [x] **A17.1** — The outlines' generator: `glyphs/outlines.py` reads
  the pinned faces (Inter 4.1, JetBrains Mono 2.304, SHA-256 pinned as
  `rasterize.py` pins them), resolves what the OS-side parser should
  never see — the cmap (format 4 or 12, every ASCII code point
  present or refusal), the implied on-curve midpoints (floored, each
  contour rotated to start on one), composites (translation applied;
  scale or point-index anchor refused by name) — and writes
  `face_inter.emo` and `face_mono.emo`, the outlines as 448-word
  chunks behind the accessors the parser will call, 96 glyphs apiece
  (gid 0 the face's own `.notdef`). The advance cross-check against
  the grid FreeType rendered runs in both generator modes: exact
  rational round-half-up, a one-pixel difference is FreeType's own
  hinting (reported: `5` at 16, `T` at 24), two or more refuse. The
  gate gains the drift check. **Complete 2026-11-09** (the gate's
  full round green, 152) — the faces'
  outlines are 3,383 and 2,973 words where the three pixel strikes
  they will retire are 4,269; the fb gate's own findings on this run:
  its wasm goldens had been broken on develop since step 56's
  seventeen-import table landed (the emo-ui runner predates it and
  supplies three), and the gate now runs its wasm artifacts under the
  canonical host the compiler carries (`src/emo_codegen/wasm/
  wasm_host.mjs`), which cannot drift.

- [x] **A17.2** — The parser and the Strike, in `raster.emo`: a face
  module read whole into a `Face` (the outline words and bases copied
  once, at boot), metrics scaled by the pinned formulas (ascent and
  descent by ceiling — the one rounding the grid's three strikes
  confirm exactly; the advance half-up, the generator's own
  cross-check rounding), slots allocated dense over the ASCII table
  at `max_dim` (the line box rounded up to 8), meta two words per
  glyph. **Complete 2026-11-10** — with three findings on the way.
  The design's "first use rasterizes" amended to eager-at-
  construction: the language's arrays are immutable values and its
  mutable containers hold no indexed word storage a blit could read
  at `font.emo`'s shape. The strike's refusal is the error
  convention — `(R.ok, the strike)` or `(R.error, why)`, not a
  raise — because the riscv64 target does not lower raise and the
  compiler pulls every module of a package into its builds; and the
  constructor keeps to seven parameters, the metal refusing a wider
  one (`emo_riscv.ml`'s ceiling). The metal now lowers the package
  with the outlines and the Strike aboard — all eight riscv64 probe
  lines green. The golden (`fb/type/`) pins the metrics reproducing
  the grid's three strikes (Inter 16/4/20 and 24/6/30, JetBrains
  Mono 17/5/22), twelve sample advances matching the grid
  glyph-for-glyph, the parse slices (a space's empty drawing, an l's
  one contour, an o's forty-eight points in two, a B's three), the
  zero-size refusal, and two digests that pin the parse and the
  scaled advances whole — byte-identical on ocaml, c and typescript;
  the golden carries no surface, so wasm and beam refuse at build
  time and the gate pins those refusals. Every package lock under
  `fb/` regenerated (the package's content hash moved with the three
  new modules).

- [x] **A17.3** — The rasterizer: `glyphs/reference.py` first (stdlib
  only, the algorithm's source of truth), then the Emo port to match
  byte for byte — 26.6 throughout, de Casteljau flattening under the
  one-pixel second difference, the clamp's doubled antiderivative
  answering every column the piece's x-range touches in one closed
  form, the right-to-left sweep with the strip suffix. **Complete
  2026-11-10** — the type golden grows 288 raster lines (a glyph per
  strike: advance, ink box, and a rolling digest over the ink's
  coverage bytes), and `reference.py --check` recomputes all 288 from
  the generator's own outlines and matches the Emo strike byte for
  byte — two independent implementations, one set of integers (the
  reference reads `outlines.py`'s absolute coordinates; the Emo side
  reads the face modules' packed words, so the equivalence also proves
  the packed decode). The strike now rasterizes eagerly at
  construction and fills meta word B (the ink box). Three findings on
  the way:
  - **The generator's vertex fields were 26 bits, not the documented
    28** — `0x3FFFFFF` is 2²⁶ − 1, so negative deltas were two's-
    complemented at the wrong width and every face module carried
    corrupted vertices (the reference never saw it, reading Python
    objects; the Emo bbox exploded). The mask corrected to
    `0xFFFFFFF`, the faces regenerated, the advance cross-check still
    95/95-plus-hinting.
  - **A digest over slot words overflows Int64** — a word packs eight
    coverage bytes and reaches 2⁶⁴ − 1 — so the raster digest folds
    bytes, 0..255 on every target.
  - **The builder element-type pinning**: `ArrayBuilder[Int64]`
    annotations hold in parameter, field and return positions, but a
    local binding settles only through a static push on the binding
    itself — pushes made inside another def leave `get` answering
    Unknown, and the c target refuses bitwise operators on Unknown
    (the rasterizer's shifts died there). `glyph_edges` builds and
    `to_array`s its edges behind its own typed return, and the sweep
    indexes the plain array.
  The FreeType audit ran once, box-aligned: the shapes agree, the
  deltas are hinting's (ink boxes move a pixel, stems read a level or
  two heavier, ink mass −6..−12%), not the algorithm's.

- [x] **A17.4** — The seam migrates: `ink`'s strike widens to a
  `Strike`, `text` and `text_width` take the strike they draw in,
  `measure`/`place`/`paint` thread it, and the backend's `Fb` holds
  the strike its tree paints in (`backend(surface, input, strike)`).
  Every caller names its size: the goldens and the corpus build one
  interface strike each at their boot; the app images hold theirs in
  the session's locals; the desktop's carve pass threads the object
  through the desk defs' first parameter. `font.emo` and `gen.py`
  retire; **`coverage.txt` stays** (D11 amended 2026-11-10): the
  advance cross-check's other side and the audit's data, regenerable
  by `rasterize.py`, compiled into nothing. The metal carries the
  outlines (A17.3's lowering) and now the whole seam: the user image
  (hello's session, the desk pass, the menus), the three app images,
  and the probe all lower with the strikes aboard. The raise-free
  discipline reached the goldens too — their strike helpers answer
  the holder pattern (build, case, push, read), the bytecode targets
  build them whole. **Landed 2026-11-10.**

## M18 — the Wayland gate (opened 2026-11-11)

The desktop so far lives inside its own machine: the gate, the carve,
the comp lines — an EmoOS story. The other half of the lineage has
been waiting since the README's first position line ("Wayland/Quartz
shape, QNX Screen lineage"): the real Wayland world, the one the
[noctalia-dev](https://github.com/noctalia-dev) family lives in — the
Noctalia desktop shell, the Umbriel compositor (scrolling, dwindle,
master, stacking), the greeter — "a family of native Wayland projects
that feel like one desktop." M18 opens the gate onto that family from
the client's side: a pure-Emo Wayland wire-protocol package, so an
Emo program connects to a real compositor over its Unix socket,
binds its globals, shares pixels through `wl_shm`, and puts a first
frame on screen. The direction is decided (2026-11-11): the client
package is the foundation every later noctalia-track shape rides
(the fb face ported onto Wayland, a shell, a compositor — each
re-evaluated once the foundation stands); verification is byte-level
goldens against a mock compositor plus a Docker Linux leg running
headless sway with `grim` screenshots. The package declares
`targets = ["c"]` — the c runtime is where Unix sockets land, and the
interpreter's fd-passage stubs are a named follow-up, not a debt of
this milestone. This milestone is hosted-only by construction: **no
kernel-side half exists, deliberately** (no EmoOS row).

The tasks are sized for idle-time sittings: each is one self-contained
unit with its own files and its own acceptance (a golden, a digest,
a build), startable and finishable without the session that wrote the
list.

- [x] **A18.1** — The package's manifest and its opening words —
  `stdlib/registry/wayland/0.1.0/package.emo` (name `wayland`,
  version `0.1.0`, `targets = ["c"]`, `deps { "net" = "0.1.0" }`) and
  the doc-comment header of `wayland.emo`: what the package is (the
  Wayland wire protocol in pure Emo over `net`'s Unix socket), the
  error split (`(R.error, reason)` with reasons prefixed `wayland:`),
  and the strictness stance (a short read is a failure, never a
  silence; the fd placeholder word is the codec's, the real fd rides
  SCM_RIGHTS). **Accept:** the package resolves on `c` and refuses on
  every other target (E5007, the sqlite3 precedent); the registry's
  embedded data regenerates on `dune build` untouched.
  **complete 2026-11-11** — the manifest and the header landed; the
  package resolves on `c` and refuses on `wasm` with E5007 (the
  sqlite3 precedent's shape), the registry's embedded data
  regenerating on `dune build` untouched.

- [x] **A18.2** — The wire's write half: the message builder. The
  8-byte header (object id, opcode, size — little-endian words), the
  argument encodings (int32, uint32, fixed 24.8, string with its NUL
  and the pad to 4, new_id, array, the fd's placeholder word), and
  the builder hands back one `String` per message, fd arguments
  queued beside it for the sender to carry. **Accept:** the encodings
  byte-match hand-computed fixtures (a demo def prints digests).
  **complete 2026-11-11** — the `Message` builder landed; five
  hand-computed fixtures matched byte for byte (get_registry, sync,
  the bind with its padded string, the pool's fd placeholder, the
  fixed −1 as `00ffffff`), the strictness raising on the out-of-range
  word, the second fd, and the oversize message.

- [x] **A18.3** — The wire's read half: the event frame reader and
  the argument decoder. `read_exactly` the header, `read_exactly`
  the size says, decode the same types back; `wl_display.error`,
  `wl_callback.done` and `wl_registry.global` are the first events
  with named shapes. **Accept:** the decoder round-trips A18.2's
  fixtures and rejects a short frame with `wayland:` reasons.
  **complete 2026-11-11** — `next_event`'s framing and the `Args`
  cursor landed; the fixtures decoded back to their exact values
  (the bind's four arguments, fixed −1, i32 −7, the empty text, the
  fd's placeholder), and the cursor reading past a frame's end
  raised with the offset named — the loud failure the wire's
  corruption earns.

- [x] **A18.4** — The core tables and the handshake: `wl_display`
  (sync, get_registry, error), `wl_registry` (bind, global,
  globals remover), `wl_callback` (done); connect through
  `net.connect_unix`, get_registry, sync, collect the globals into a
  typed shape, bind by name at the advertised version. **Accept:**
  the handshake defs compile against the tables; correctness rides
  the goldens.

- [x] **A18.5** — `examples/wayland_wire`: the codec's golden. Build
  the handshake's requests, print their digests, parse a canned
  event stream, print what it saw — all pure function of the codec,
  no socket. `package.emo` + `package.lock` + `expected.txt` in the
  corpus discipline, registered in `c_goldens`
  (`test/emo_cli/emo_cli_test.ml`). **Accept:** the golden passes on
  the c target; `dune build` after `emo deps resolve` stays green.
  **complete 2026-11-12** — the golden landed and caught a real bug
  on its first run: `Globals.at`'s rotation was stateful across
  calls (at(1) answered the third global) and `find`'s early exit
  left the deque half-rotated; the walk now goes out and comes all
  the way home. The transcript pinned in `expected.txt`, registered
  in `c_goldens` beside httpd's.

- [x] **A18.6** — The c runtime's Unix sockets: `net_listen_unix` and
  `net_connect_unix` stop refusing on `c` — AF_UNIX bind/listen and
  connect in `emo_c_runtime.c` (the conn is the boxed fd int; the
  existing read/write/read_exactly/close work unchanged on the new
  family), no emitter changes beyond the two names. **Accept:** an
  in-process demo — a spawned process listens, the main process
  connects and round-trips bytes — builds and runs on macOS `cc`.
  **complete 2026-11-12** — AF_UNIX listen/connect in
  `emo_c_runtime.c` (a stale socket file replaced only when `stat`
  proves it a socket, never a regular file), the emitter's two arms,
  the probe's spawned server parking on accept while the client
  round-tripped bytes. The net docs' "refused on c" line for Unix
  sockets retired with it.

- [x] **A18.7** — The c runtime's fd passage and shm tier:
  `net_sendmsg_fd` / `net_recvmsg_fd` (sendmsg/recvmsg with
  SCM_RIGHTS, the fd queued with the message's own data),
  `os_shm_open` (POSIX `shm_open` + immediate unlink — macOS and
  Linux share it), `os_ftruncate`, `os_pwrite`. The emitter arms in
  `emo_c.ml`, the signatures in `emo_check.ml`, and the interpreter's
  honest refusal in `emo_eval.ml` ("the fd passage rides the c
  target" — a runtime failure, never a silence). **Accept:** the
  primitives compile into the c runtime; a demo sends one fd over a
  real unix socket and reads it back on the other end.
  **complete 2026-11-12** — sendmsg/recvmsg with SCM_RIGHTS landed
  (the probe watched fd 3 leave and fd 7 arrive, the pool's bytes
  readable at the far end), and three findings reshaped the road:
  the checker's `(R.error, why)` convention only knew the pair — the
  three-slot `(R, data, fd)` crashed `fold_left2` after the E4013
  report, and the convention now reads any `(R, ...)` shape; macOS
  hides the CMSG macros from a strict-ANSI unit without
  `_DARWIN_C_SOURCE`; and macOS's POSIX shm objects refuse read and
  pwrite outright (mmap-only), so `os_shm_open` became a private
  file at a path, unlinked at birth — seekable and mappable on both
  platforms, the shape the wl_shm pool accepts.

- [x] **A18.8** — `examples/wayland_handshake`: the mock compositor's
  golden. One program: a spawned process serves the socket as the
  canned compositor (registry advert, sync answers, byte-exact
  request assertions), the main process is the client riding A18.4's
  handshake — including the `wl_shm` pool fd round trip (the mock
  receives the fd, reads the pool's bytes back through it, asserts
  the pattern). The transcript lands in `expected.txt`, registered
  in `c_goldens`. **Accept:** the golden is byte-deterministic and
  green on macOS `cc`.

- [x] **A18.9** — The `xdg-shell` and `wl_shm` tables: `xdg_wm_base`
  (ping/pong, get_xdg_surface), `xdg_surface` (configure/ack,
  new_toplevel frame callbacks), `xdg_toplevel` (configure events,
  set_title, close), `wl_shm` (create_pool, formats — ARGB8888
  first), `wl_shm_pool` (create_buffer), `wl_buffer` (release). The
  configure-before-commit discipline the protocol demands, made
  structural in the package's API. **Accept:** the tables compile;
  the state machine's shape reads in the defs' signatures.
  **complete 2026-11-12** — the tables landed with their opcode
  numbers stated where they are used, plus the wl_compositor and
  wl_surface pair the window's tree grows from, and
  `wait_configure` — the state machine's heart, the def whose
  signature names the discipline (the serial out, the ping answered
  on the way, the toplevel's own configures set aside). The opcode
  numbers are the hand-written tables' honest risk: the smoke leg
  (A18.11) is where a real compositor grades them.

- [x] **A18.10** — `examples/wayland_paint`: the first frame. Open a
  toplevel, `os_pwrite` an ARGB8888 pattern into the pool, wait the
  configure, ack it, attach, commit — the demo prints its own
  progress lines and leaves the window up a beat for the screenshot
  leg. **Accept:** under a real compositor (the smoke leg) the
  window maps; the pattern's pixels are what `grim` captures.
  **complete 2026-11-12** — the demo landed and pulled `os.getenv`
  in with it (the socket path is `$XDG_RUNTIME_DIR`/`$WAYLAND_DISPLAY`,
  and no real client lives without the environment; the os package's
  digest moved and the six locks pinning it re-resolved). The
  sequence drives the whole ladder — handshake, the three binds at
  the advertised versions, surface, xdg surface, toplevel, title,
  the empty commit, the configure wait, the ack, the pool painted
  one pwrite a row, attach, damage, the second commit — then reads
  events until the compositor lets go. Two demo-shaped lessons: the
  void def takes no `return` (the loop became `handle_event`
  answering whether it lives on), and the generated C seeds module
  consts in the root entry, so a def that binds-but-never-uses them
  warns — the corpus's own pre-existing shape, recorded, not fixed
  here. **complete 2026-11-12** — and the demo graded the hand's
  opcode tables against the real compositor: `get_xdg_surface` is
  opcode **2** (`create_positioner` sits at 1 — the first smoke run
  silently minted a positioner@8 and the compositor's error named
  our get_toplevel as its `set_size`), `pong` is 3,
  `ack_configure` is 4 (`set_window_geometry` at 3), and the
  wl_surface family sits one higher than the codec had it
  (`destroy` at 0: attach 1, damage 2, commit 6). Sway graded
  every one of them, loudly, by name.

- [x] **A18.11** — The smoke leg: `devtools/wayland-smoke.Dockerfile`
  (cc, sway, grim — no OCaml in the image) and
  `devtools/wayland-smoke.sh`: the host emits the demo's C
  (`emo build --target c`), the container compiles and runs it
  under headless sway (`WLR_BACKENDS=headless`), `grim` captures,
  the script checks the pattern's pixels and exits nonzero with the
  capture beside it on any miss. **Accept:** the script exits 0 and
  the screenshot shows the pattern — the milestone's first frame on
  a real compositor.
  **complete 2026-11-12** — the leg runs on this desk's Docker
  Desktop (linux/arm64) and exits 0: `red pixels ~63900, blue
  pixels ~63900`, the 320×200 window's halves counted from grim's
  PPM. The leg's own lessons: sway refuses root ("unable to drop
  root" — the image runs as a non-root user), Debian's CDN answered
  502 for whole pools (the Dockerfile pins the TUNA mirror), and
  the run script keeps the client's and sway's logs beside the
  capture on every miss. The debugging it earned is the
  milestone's deepest finding, recorded in CHECK.md: **the wire's
  fd argument takes NO word in the argument stream** — the
  compositor read our spec-shaped placeholder as the next
  argument's value (the pool's size arrived as 0, then as the fd's
  own number when the placeholder carried it), and the codec's fd
  now rides the ancillary queue alone.

- [x] **A18.12** — The docs and the ledger: `docs/stdlib/wayland.md`
  and its `docs/zh-CN/stdlib/wayland.md` mirror, both `stdlib.md`
  index rows (English and Chinese), `plan/step-58-wayland-client.md`
  (the design record: the fd-passage decision, the c-target-first
  shape, the interpreter stubs as the named follow-up), and the
  CHECK.md entry carrying the milestone's findings. **Accept:** the
  docs land in both languages; the ledger entry states what was
  learned, not what was built.
  **complete 2026-11-12** — the reference landed in both languages,
  both `stdlib.md` indexes grew their row and section, the design
  record is `plan/step-58-wayland-client.md`, and the CHECK.md entry
  carries the wire's four graded decisions, the two found-not-fixed
  findings, and the smoke leg's exit 0. The milestone is closed:
  A18.1–A18.12 complete, the foundation standing.

## M19 — the seat: input on the gate (opened 2026-11-12)

M18's window paints but does not listen: the seat, the pointer, and
the keyboard are the wire's other half of interactivity. The milestone
adds the input tables to the wayland package — `wl_seat`
(capabilities, the pointer and keyboard it grants), `wl_pointer`
(enter/leave/motion/button/axis, the frame family since v5),
`wl_keyboard` (the keymap whose fd rides the event direction's own
ancillary queue, enter/leave/key/modifiers) — every opcode read from
the authoritative XML before it was written, the discipline M18's
smoke leg paid for. The smoke leg grades them the honest way: the
demo binds the `zwlr_virtual_pointer_manager_v1` and
`zwp_virtual_keyboard_manager_v1` globals sway advertises, injects
motion, a button press, and a key press against its own window, and
the transcript answers for what arrived. The seat binds at v5 — the
frame family and `repeat_info` included, `axis_value120` (v8)
deliberately out. Keycodes arrive raw; the keymap's bytes are read
and their shape asserted, but keysym decoding is the named
follow-up, not this milestone's debt.

- [x] **A19.1** — The input tables in the package: `wl_seat`
  (get_pointer 0, get_keyboard 1, release 3; capabilities 0, name 1;
  the capability bits pointer=1 keyboard=2), `wl_pointer` (set_cursor
  0, release 1; enter 0, leave 1, motion 2, button 3, axis 4, frame 5,
  axis_source 6, axis_stop 7, axis_discrete 8), `wl_keyboard`
  (release 0; keymap 0, enter 1, leave 2, key 3, modifiers 4,
  repeat_info 5); the defs pin the seat at v5 and the decode reads
  fixed 24.8 coordinates through `Args.fixed`. **Accept:** the tables
  compile; the opcodes state their source (the XML read, not the
  guess). **complete 2026-11-12** — the tables landed beside the
  virtual-device tables the injection would need
  (`zwlr_virtual_pointer_manager_v1` create 0/destroy 1, the pointer's
  motion 0 / motion_absolute 1 / button 2 / frame 4 / destroy 8;
  `zwp_virtual_keyboard_manager_v1` create 0, the keyboard's keymap
  0 / key 1 / modifiers 2 / destroy 3), all read from wayland.xml and
  the wlr protocol files before a line was written.

- [x] **A19.2** — `examples/wayland_input`: the mock leg. The mock
  compositor's canned stream carries a capabilities advert, pointer
  enter/motion/button, a keyboard keymap (its fd a real one the mock
  paints through `os_shm_open`, the client reading the keymap's bytes
  back through the passage), and key events; the client decodes each
  and prints. Registered in `c_goldens`. **Accept:** byte-deterministic
  on macOS `cc`; the keymap fd round-trips.

- [x] **A19.3** — The smoke leg's injection half: the demo binds the
  two virtual-device managers beside the seat, drives
  `motion_absolute` across its own window, presses and releases the
  left button, taps a key (the keymap a minimal xkb_v1 map painted
  through the shm tier), and the event loop's prints name what
  arrived. **Accept:** under headless sway the transcript shows the
  motion, the button, and the key — the seat's verdict on the tables.

- [x] **A19.4** — The smoke script asserts the injection: the
  capture leg stays, the client's transcript gains the input lines,
  and the script greps for them (motion seen, button pressed, key
  arrived) and exits nonzero on any miss. **Accept:** the leg exits 0
  with the input lines present. **complete 2026-11-12** — five
  assertions (enter, motion, the button press, the key, the keymap
  fd) and a new pass line: "the frame is on a real compositor and
  the input came back."

- [x] **A19.5** — The docs and the ledger: the input section in
  `docs/stdlib/wayland.md` and its zh mirror, the M19 notes in the
  CHECK.md entry, the TASKS ticks. **Accept:** both languages land;
  the ledger states what the seat taught. **complete 2026-11-12**
  — the input section landed in both languages (the limitation line
  shrank to keysyms alone), and the CHECK.md bullet carries the
  three grades sway handed down. M19 closed: the window now listens.

## M20 — the face rides Wayland (方案 2, opened 2026-11-12)

M18 opened the gate, M19 wired the seat — the face is the cargo. The
fb backend's hosted shape needs exactly two bridges to a real
compositor, both points the Elm loop already draws: a `Surface` whose
`present()` pushes the canvas's bytes through the shm tier into the
window (`pwrite` + attach + damage + commit — the canvas's XRGB8888
words are wl_shm XRGB8888 bytes verbatim), and an `Input` whose
`next()` blocks on Wayland events and translates them into the tags
`deliver` speaks (keys through an evdev-to-ASCII table with the shift
state tracked, clicks through a rect table hit-tested at the
pointer's last position). The demo is `ui_corpus`'s own application —
the counter, the form, the whole vocabulary — live on a real
compositor, driven by the injected keyboard. The packages ride the
staged-registry pattern the fb gate drew (the emo-ui core, the fb
packages, and the stdlib's wayland/net/os in one content-named
directory).

- [x] **A20.1** — The canvas's own bytes: `ui_fb_canvas.Canvas` grows
  `bytes()` — the hosted canvas's data is the frame the moment it is
  stored, and the present bridge reads exactly those words. The demo
  package `projects/emo-desktop/wayland/` with its staged-registry
  check script (the fb gate's pattern, plus the stdlib's
  wayland/net/os). **Accept:** the demo resolves and type-checks
  through the staged registry.

- [x] **A20.2** — The window bridge: `wayland_live.emo`'s
  `window_open` — the full M18/M19 dance (handshake, the seat grants
  gated on capabilities, surface, xdg surface, toplevel, the pool
  sized stride×height, the buffer in wl_shm XRGB8888, first frame)
  answering a handle the present bridge drives. **Accept:** under
  headless sway the window maps and the pattern lands.

- [x] **A20.3** — The bridges: `LiveEye` (a `ui_fb.Surface` over the
  canvas whose `present()` pushes the bytes and presents) and
  `LiveInput` (an `ui_fb.Input` whose `next()` consumes Wayland
  events — keyboard keys through the evdev table with the shift
  state, pointer button with the position the motion events keep —
  into the caller's tag and rect maps). **Accept:** the corpus demo
  driven by injected keys shows the state transitions the script
  once faked.

- [x] **A20.4** — The demo: `ui_corpus`'s application live —
  keyboard `i`/`d`/Enter mapped to its tags (inc, dec, submit), one
  frame digest per present in the transcript. **Accept:** under
  headless sway the injected keys change the model the way the
  script's tags did, and the digests agree with the corpus's
  sequence.

- [x] **A20.5** — The smoke leg grades it: headless sway, the
  virtual keyboard injects `i`, `i`, `d`, Enter, the transcript's
  digests and state lines are asserted, and the capture shows the
  frame the last present left. **Accept:** the leg exits 0 with the
  state lines present.

- [x] **A20.6** — The docs and the ledger: the ride section in
  `docs/stdlib/wayland.md` and its zh mirror (or the project's own
  README), the CHECK.md entry, the TASKS ticks. **Accept:** both
  languages land; the ledger states what the ride taught.
