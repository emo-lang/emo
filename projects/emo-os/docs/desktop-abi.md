# The desktop protocol's stability contract

The gate's verb numbering is already frozen by rule
([`syscalls.md`](syscalls.md)): a number, once assigned, never
changes meaning — additions only, versioning carries the rest. The
desktop segment (**verbs 10..16, reserved: `present`, `output_info`,
`input_read`, `win_new`, `win_close`, `win_focus`, `win_move`**)
extends that rule
from numbers to the whole protocol surface, because a desktop's
protocol outlives every implementation of it — Wayland and Quartz are
the proofs, win32k.sys the counterexample.

This document is the contract the desktop
([`projects/emo-desktop`](../../emo-desktop)) grows inside. The full
research record, with the reasoning behind each seam, is the
[desktop assessment](../../emo-desktop/docs/assessment.md).

## The three tiers

- **Tier A — protocol ABI, frozen.** Verb numbers, the event stream's
  shape, the capability model. These break every app ever written
  when they break; the frozen-numbering rule is the mechanism, and
  versioning is itself part of the contract.
- **Tier B — implementations, relocatable.** Fonts may become
  TrueType, the blit may become GPU work, the compositor may leave
  the kernel image for a user process — without a verb or an event
  changing shape. An implementation that cannot move is an
  implementation the protocol was designed around, which is the
  win32k.sys disease.
- **Tier C — additions.** IME, clipboard, screenshots, notifications,
  accessibility: new verbs and new events, added under new numbers,
  never rewrites of old ones.

## The eight seams — right from the first verb

1. **A buffer is a capability object**, never a bare physical
   address — the IOSurface/DMA-BUF shape. The gate's authorization
   table names buffers by grant, not by address; this is the
   precondition for GPU paths, zero-copy, and sandboxing, and it
   cannot be retrofitted.
2. **The outputs list is not a constant.** `frame_w`/`frame_h`
   constants are the honest trap; the protocol enumerates outputs —
   `output_info` is the enumeration's verb — and one display is the
   first answer, not the only shape.
3. **Surfaces carry a role** — toplevel/popup/subsurface/panel.
   Toplevel is implemented first; the rest are refused by name, not
   by silence.
4. **Format and scale are fields** — XRGB8888 is the first accepted
   value, and the negotiation's shape exists from the first day.
5. **One versioned event stream, with frame callbacks.** virtio-gpu
   has no vblank; the compositor composites on the tick, and the
   frame callback is the animation story's hinge — the seam that
   keeps pacing honest when real hardware arrives.
6. **Present is an atomic commit.** A frame's state lands whole; no
   verb observes a half-presented frame.
7. **Text never enters the protocol.** Keys and glyphs are the
   endpoints' business; the compositor carries bytes and rectangles,
   never strings — the seam that keeps IME (Tier C) addable instead
   of a rewrite.
8. **Mechanism separated from policy, the compositor retractable.**
   The grant objects attach into any authorized process table from
   day one, so the compositor can leave the kernel image (Tier B)
   without the protocol noticing.

## The cursor plane's sprite memory (T8.11, emo-desktop A8.2)

The pointer's sprite is the desktop's — a Wayland client's cursor is
the client's, and so is this one: the compositor carries pixels and
rectangles, never a drawing. The contract is memory, not a verb. The
screen carve's last 64 KiB is the cursor plane's sprite memory; past
the block's first line — the screen pass's proof pattern pokes the
first word of every 64 KiB of the carve, this block's included — the
desktop (the full-screen pass, which has the carve mapped) writes:

- `+64` the header, four 32-bit words: the width, the height, the
  hotspot's x and y, in sprite pixels;
- `+80` the pixels, width × height ARGB8888 words, row-major, a top
  byte of 0xFF an opaque pixel and 0 a clear one, at most 64 × 64;

and the header last, so a torn read sees no sprite: a zero width is
the compositor's no-sprite-yet, and the plane composites nothing until
the desktop has drawn one. The save-under — the carve's words under
the drawn sprite, the compositor's own half of the block at `+0x8000` —
is kernel-private and no part of the contract. The compositor reads
the header at each composition, hides the sprite around every window
blit so its save-under never holds stale words, moves it by the
pointer's position, and presents the rectangle both places lie in.
A cursor verb may yet join the desktop segment (Tier C, additions
only); the memory contract stands under it either way.

## What the contract cannot save — the honest four

The arena's residue (the autorelease pool landed as the Elm loop's
precondition and the loop runs on it, emo-desktop A8.3 — what bounds
a session now is the dynamic convention's boxed numbers, about 3 KiB
a node and 600 bytes a glyph per frame, and typed method bodies are
the next piece), the cooperative single hart (preemption must land;
`-smp` is parked, not impossible), the single image with many passes
(M11's own work), and generic IPC (portal-class services will want
it; it is built when a measured path demands it). None of these is a
protocol change; all four are machine- and language-side work,
tracked in this project's Step 8.
