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
