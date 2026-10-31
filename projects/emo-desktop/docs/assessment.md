# The desktop assessment — the research record

This note is the full record of the desktop research and the three
discussion rounds behind the project (2026-10-31): the architecture,
the hard constraints the language and the machine impose, the phasing,
the scalability contract (what stays frozen as the desktop grows, what
may move, what may be added), and the project's own placement. The
decided outcomes live in the [README](../README.md); the decision
points — all decided 2026-10-31 — are recorded here and at the top of
the [tracker](TASKS.md).

## The shape: Wayland/Quartz, the QNX Screen lineage

A compositor owns the scanout, clients render into buffers the
compositor authorized, and presentation is an explicit act with a
damage rectangle. No client ever touches display hardware; no server
ever renders for a cooperative client it cannot preempt. This is the
microkernel's own discipline (EmoOS's README claims the QNX lineage)
applied to pixels — the same reason Wayland and Quartz look the way
they do.

The pieces, as researched:

- **The compositor is a service process in the kernel image** — the
  `fs.emo` lineage: a fixed page, a pid cell, request slots, negative
  route codes, the supervisor's restart. Not a generic IPC object;
  the message toll stays where the boundary pays.
- **The display is `virtio-gpu-device`** on QEMU's `virt` board
  (verified locally on QEMU 11.1.2: gpu/keyboard/tablet/mouse all
  attach on riscv64). The driver copies the `blk_service` shape:
  slot scan, modern-layout negotiation, DeviceID 16, polled
  completion first (the IRQ wiring later — the same stated bound).
  The 2D path is the whole need: `resource_create_2d` →
  `attach_backing` → `set_scanout` → `transfer_to_host_2d` (the
  damage rectangle) → `resource_flush`. The ramfb firmware device is
  rejected — it draws pixels but teaches nothing about virtqueues,
  and virtio-gpu is the path every later milestone rides.
- **Input is `virtio-input` (DeviceID 18)** — a driver plus an input
  service that merges the stream with the UART's bytes, so the shell
  and the desktop share one event world. Under `-nographic` the
  virtio keyboard never sees the host's keys: interactive runs use
  `-display cocoa`, and the serial line stays the shell's.
- **Clients render; the compositor composites.** An app paints into
  an authorized buffer and presents it with a damage rectangle. The
  M7 minimal shape: one full-screen pass, its buffer direct-mapped to
  the screen carve, `present` nothing but the flush.
- **The gate grows a desktop verb segment, 10..16**: `present`,
  `output_info` (the outputs list's verb — the second seam's),
  `input_read`, `win_new`, `win_close`, `win_focus`, `win_move`. The
  numbering rule (frozen once assigned, only additions) is
  [`syscalls.md`'s](../../emo-os/docs/syscalls.md); the stability
  contract around the whole protocol is
  [`desktop-abi.md`'s](../../emo-os/docs/desktop-abi.md).
- **The screen carve**: a fixed 4–8 MiB cut at the top of the frame
  allocator's region (1024×768 XRGB8888 is the recommended baseline),
  `frames.emo`'s `region_end` moving down — display memory is the
  kernel's to hand out, and the carve is the one allocation bigger
  than a block.
- **Window buffers**: `frames.take_run(n)` (a contiguous run of
  blocks), `space.build` mapping them incrementally into the owner's
  table, the gate checking every present against the authorization
  table — a buffer is a capability object, not a bare address.
- **The EmoUI fb backend is the tui backend's pixel twin** — the Elm
  loop unchanged, the backend interface the same family. And the
  blit must be `Int64`-word (or 32-bit) stores: a bytewise copy loop
  cannot survive TCG at frame scale.

## The three hard constraints

1. **No reclamation on riscv64.** An Elm loop rebuilds its tree per
   event; on a 64 KiB arena that dies within a screenful of events.
   The countermeasures: an N-block arena (immediately doable — the
   arena is already the allocator's blocks) and, deeper, porting the
   c target's frame-scoped autorelease pool to riscv64 with Stage B
   escape analysis refusing what escapes — a language-deep piece, on
   the compiler track.
2. **Array literals beyond ~253 elements fail to assemble** (CHECK.md
   155 — the 12-bit immediate; the boot banner hit it). This blocks
   embedded fonts, whose glyph tables are kilobytes. The
   recommendations: fix the codegen (register + `addi`, or chunked
   stores) — or carry fonts on the disk, which M7's filesystem makes
   possible. The literal fix is the recommended route; the disk is
   the fallback.
3. **Cooperative, one hart, no tick preemption.** A busy app freezes
   the desktop. The pool and preemption together are what make an
   honest multi-app M11; until then the discipline is the one the
   shell already keeps.

## The phasing

The compiler track (literal fix, N-block arena, pool) runs beside the
milestones, not inside them.

- **M7 — the screen**: the driver, the carve, the first full-screen
  frame, `present` as flush.
- **M8 — glyphs & pointer**: bitmap fonts, the pointer sprite, the
  input merge.
- **M9 — windows**: the composited loop, drag, focus, and the
  acceptance test that matters — a killed and restarted window stack.
- **M10 — the desktop**: the EmoUI fb backend whole, the dock, the
  first apps (a counter, a file browser, an editor).
- **M11 — honest multi-app**: ELFs from the filesystem, per-image
  segment tables, per-process gate checks, generic IPC if a measured
  path demands it.

**Test discipline** (EmoOS's, extended): QEMU monitor `screendump`
PPM checksums as the golden's eyes, `sendkey`/`mouse_move` as its
hands, and `run.sh` growing a display leg (`-display none` for the
golden, `-display cocoa` for the hand-driven ride).

## The experience boundary

Reachable: composited multi-window, drag, focus, the mouse, bitmap
fonts, a dock, real apps. Not reachable: GPU acceleration,
antialiasing, animation, hard real time. The honest feel: an
early-90s workstation with a Mac OS 9 temperament. Everything past
that is the growth contract below.

## The decision points, decided (2026-10-31)

1. **The compositor's home** — decided: a service process in the
   kernel image (the `fs.emo` lineage).
2. **M7's present shape** — decided: the client direct-mapped to
   the carve, `present` only the flush.
3. **The font route** — decided: fix the codegen's wide literals;
   the disk is the fallback.
4. **The pool's scheduling** — decided: beside M7, not after it —
   M8's Elm loops need it.
5. **The resolution baseline** — decided: 1024×768 XRGB8888.

## The growth contract: what it takes to stay honest to a modern desktop

"Architecture unchanged" splits into three tiers:

- **Tier A — protocol ABI, frozen.** Verb numbers, the event stream's
  shape, the capability model. Breaking these breaks every app ever
  written; the numbering-freeze rule in `syscalls.md` is the
  versioning mechanism, and versioning is itself the contract.
- **Tier B — implementations, relocatable.** Fonts may become
  TrueType, the blit may become GPU work, the compositor may leave
  the kernel image for a user process — without a verb or an event
  changing shape.
- **Tier C — additions.** IME, clipboard, screenshots, notifications,
  accessibility: new verbs and new events, added, never rewritten.

**The eight seams to get right now** (each grows through B or C,
never by breaking A):

1. **A buffer is a capability object**, never a bare physical
   address — the IOSurface/DMA-BUF shape; the precondition for GPU
   paths, zero-copy, and sandboxing.
2. **The outputs list is not a constant** — `frame_w`/`frame_h`
   constants are the honest trap; enumerate outputs.
3. **Surfaces carry a role** — toplevel/popup/subsurface/panel;
   implement toplevel first, refuse the rest by name.
4. **Formats and scale are fields** — accept XRGB8888 first, carry
   the negotiation anyway.
5. **One versioned event stream, with frame callbacks** — virtio-gpu
   has no vblank; the compositor composites on the tick and the
   frame callback is the animation story's hinge.
6. **Present is an atomic commit** — a frame's state lands whole.
7. **Text never enters the protocol** — keys and glyphs are the
   endpoints'; the compositor carries bytes and rectangles, never
   strings.
8. **Mechanism separated from policy, the compositor retractable** —
   win32k.sys is the counterexample, DWM's migration the story; the
   grant objects attach into any authorized process table from day
   one.

**The honest four** — what the protocol cannot save on its own: the
no-reclaim arena (the pool is a precondition, not a parallel), the
cooperative single hart (preemption must land; `-smp` is parked, not
impossible), the single image with many passes (M11), and generic IPC
(portal-class services will want it; build it when a measured path
demands it).

M7 and M9's specs take five increments each from this contract —
recorded with their tasks in the trackers.

## The placement round: this project's own shape

- **The boundary is the gate.** Kernel-side mechanism (drivers, the
  compositor service, the verbs, `space.build` and `frames` plumbing,
  the N-block arena, the ABI documents, the smoke's display leg, the
  M7–M9 mechanism tasks) stays in [emo-os](../../emo-os); the fb
  backend, fonts, shell, apps, corpus, and this project's README and
  tracker are here.
- **A package collection, not a second image** — the kernel embeds
  one image (`user.S` embeds `hello.elf`); through M7–M10 the
  desktop's code rides it as packages. The mechanism precedent: the
  `syscall` stub package consumed by `hello/package.emo`'s deps, and
  `projects/emo-ui`'s `check.sh` consuming a filesystem registry
  across directories. At M11 the corpus apps become disk ELFs in
  place — zero structural change.
- **The fb backend splits inside itself**: pure logic (measure,
  place, clip, blend against a buffer interface) runs hosted in the
  corpus and dual-runs on the metal; the raw shim (`peek`/`poke`) is
  riscv64's.
- **Names, decided**: `emo/ui_fb` for the backend (EmoUI's sixth),
  `emo_desktop` for the shell (the `emo_os` flat-name precedent);
  the directory names the project.
- **The first batch is documents and the hosted corpus** — no empty
  scaffolding; code arrives when M7's first task does.
