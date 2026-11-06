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

## The surfaces and their roles (T8.13, emo-desktop A9.1)

The third seam's landing: a buffer becomes a surface when its client
declares a role for it — verb 17, `win_role(grant, role)` — and the
compositor's stack acts on surfaces alone. The vocabulary is frozen:
0 toplevel, 1 popup, 2 subsurface, 3 panel. Toplevel is the role the
compositor implements; the other three are refused with reason 4, by
their number — the protocol carries no text (the seventh seam), so
the caller, who chose the role, is the one to name what it asked for
(`role popup r4` on the machine's wire). A surface's role does not
change; a second declaration is refused. A surface's stack entry
carries its grant, its position and its role; `win_focus` raises it
to the stack's top, `win_move` places it, and the composition a
window present posts is the whole stack walked bottom to top over a
carve cleared to the compositor's own background — the last entry
over the rest, a moved window's old place the background again, every
surface whose row is ready carried, and the presenting client's
answer after the flush (the sixth seam). The wire carries each
composition as `comp <x> <y> <sum>` — the presenting surface's
position and the words the walk carried. A client's scale for the
stream's absolute reports is the device's own answer, verb 18,
`input_info(index)` — the input side of the second seam; the outputs'
enumeration has its twin.

## The growth contract's increments (T8.15, emo-desktop A9.3)

M9's five increments, each an addition under a new verb, each the
assessment's seams made concrete. **The roles' substance** (the third
seam grown): popup, subsurface and panel are implemented, not refused —
verb 19, `win_parent(grant, parent)`, binds a popup or a subsurface to
the toplevel it hangs from; its coordinates are the parent's from the
binding on, the walk paints it immediately above its parent, a move of
the parent carries it, and the parent's death takes it too (the stack's
prune cascades). A panel stands alone as the walk's topmost strip —
the shell's chrome no window covers — and refuses a parent by its role.
The by-number refusal survives on the wire as the second declaration's
(`role toplevel r4`) and the parent-binding's mismatches (`parent panel
r4`, `parent gone r4`). **Format and scale are fields** (the fourth
seam): verb 20, `win_format(grant, format)`, and verb 21,
`win_scale(grant, scale)`, record the negotiation's words on the
buffer's row — XRGB8888 (0) and scale 1 the first accepted values, the
rest refused by their number; the shape exists, the values grow under
it. **The frame callback** (the fifth seam): verb 22, `win_frame()`,
parks the caller, and the compositor's answer is the tick — the next
composition's completion, the flush that put a frame on the display; a
ring of four parks full is the resource refusal. **The stream's
version** (the fifth seam's other half): verb 23, `desktop_version()`,
answers 1 — the gate's own answer, the negotiation's anchor. The proof
chain runs all five on the wire (the popup riding its parent's move,
the fields answered and refused, the callback's `cb ok` inside the
client era, `protocol 1`), and the display model of the moved window's
composition grew the four surfaces the walk now carries.

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
the next piece), the cooperative single hart (tick preemption landed
2026-11-06 — the boot stub assigns the root's slice and every process
inherits it; `-smp` is parked, not impossible), the single image with
many passes
(M11's own work), and generic IPC (portal-class services will want
it; it is built when a measured path demands it). None of these is a
protocol change; all four are machine- and language-side work,
tracked in this project's Step 8.
