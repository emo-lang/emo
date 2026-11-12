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
0 toplevel, 1 popup, 2 subsurface, 3 panel, 4 wallpaper (T8.27,
emo-desktop A13). Toplevel is the role the compositor implements; the
other three are refused with reason 4, by their number — the protocol
carries no text (the seventh seam), so the caller, who chose the role,
is the one to name what it asked for (`role popup r4` on the machine's
wire). A surface's role does not change; a second declaration is
refused. A surface's stack entry carries its grant, its position and
its role; `win_focus` raises it to the stack's top, `win_move` places
it, and the composition a window present posts is the whole stack
walked bottom to top over a carve cleared to the compositor's own
background — the last entry over the rest, a moved window's old place
the background again, every surface whose row is ready carried, and
the presenting client's answer after the flush (the sixth seam). The
wire carries each composition as `comp <x> <y> <sum>` — the
presenting surface's position and the words the walk carried. A
client's scale for the stream's absolute reports is the device's own
answer, verb 18, `input_info(index)` — the input side of the second
seam; the outputs' enumeration has its twin.

## The wallpaper (T8.27, emo-desktop A13)

The desktop's own canvas: role 4 names a surface the walk paints
under every window — the gradient and the desktop's icons ride it —
and the machine holds one. A second wallpaper declaration is the
argument refusal; `win_focus` on it is refused too (the wallpaper is
no client's to raise), and a press that lands on no window and no
panel names the wallpaper the focused surface — the background click
is the desktop's owner's, the way a click on bare desktop unfocuses
the windows. A ready wallpaper that covers the whole mode is the
clear's replacement: the walk lays it and nothing beneath it; until
then (the first present, a dead owner) the carve clears to the
compositor's background as before, so the slate stays what a machine
without a desktop paints.

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

## The window's own menu (emo-desktop A16, EmoOS T10.2–T10.4)

The bar's chrome grew a door and the protocol grew the wire under it.
**The press-at** (T10.2): a left-button press on the pointer's ring is
followed by a type-4 event — the button's code, the position the axes
last named packed raw, x in the value's high half and y in its low —
served to the focused window's reader by the focus's verdict (the
moves' panel exemption beside it, never instead of it). The title
bar's button is the app's to judge: the shared bar paints one round
button at the bar's left (the three the traffic lights wore are one),
the seat the fb family shares opens the window's menu — a popup hung
from the window by verb 19's binding at the button's side — and the
items are the window manager's verbs the app's own grant may call.
**The minimize** (T10.3): verb 25, `win_minimize(grant)` — the toplevel
off the walk's eye, the hidden word kept beside the stack (the walk
skips it and everything hanging from it, the press's raise never hits
what it cannot show), the entry kept (the position and the grant are
the restore's memory), the focus it held fallen to the window beside
it, the answer's own composition carrying the disappearance whole.
**The desktop's open** (T10.3): verb 26, `win_desk_open(pid)` — the
dock tile's word for a live app, the window of that pid raised and
focused, the hidden one unhidden first; the authority is the desktop's
(the caller owns a panel — the strip above the windows — for the
desktop names its apps by pid), never the window's owner's. **The
scale's values** (T10.4): verb 21 accepts the whole numbers now — the
walk carries the buffer at that multiple, nearest neighbor, the
maximize the desktop's windows speak; a scale below 1 stays the
argument refusal. **The drag** (emo-desktop A16.5, EmoOS T10.5):
while the hand holds the button, each report's end pushes the
move-at (type 5, the press-at's packing) beside the axes — the
window following the pointer by the seat's own `win_move`, the even
x the blit's word pairs keep, the release the disarm. And the fold:
a window that loses the focus loses
its popups with it — a menu whose reader's attention moved is the
next composition's wallpaper, never a latch left open on the screen.

## The notification family (emo-desktop M25, EmoOS T11)

The shell is the notification center by construction (D16): apps
raise through the gate's verb 27, the service keeps the pending queue
and nothing else, and the shell takes through verb 28 — the first
taker the center's owner, every later taker refused by pid. **The
raise** (`notify(title, title_len, body, body_len)`): the title 1 to
64 bytes at `title` and the body 0 to 192 at `body`, both copied into
a request slot inside the trap that checked them (the filesystem's
own shape, the slot's index riding the route −1027), and the answer
the notification's id — the service's monotonic number, 1 or more, 0
the empty sentinel a real raise never carries. A full queue is the
resource refusal and nothing is evicted: eight entries are what the
service holds, and the queue never lies by dropping. **The take**
(`notify_take(buf, cap)`): one packed entry lands at `buf` — the
24-byte head (the id at 0, the title's length at 8, the body's at 16)
then the bytes — and the answer is its packed size; 0 is the empty
queue (the cheap poll), a `cap` under 24 bytes the argument refusal,
and a `cap` under the first entry's packed size the argument refusal
*without consuming*, so the caller retries with a bigger buffer. The
first taker names the center's owner (the wallpaper's
first-declaration precedent) and every later taker's pid is the
permission refusal — the center is the shell's, by construction. The
service's state is nothing but the queue: the history and
do-not-disturb are the shell's memory and policy, no verb's business
(D16's split). A restart loses the pending queue (the abandoned
callers refused with reason 5, the slots and the stash cleared) and
keeps the owner's claim — the page outlives the instances, the
filesystem's own rule.

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
(M11's own work), and generic IPC (measured 2026-11-06: no path
demands it — the bulk already crosses shared memory behind six-word
control, and the desktop era's real contention was absorbed by the
verb protocol's slot staging; the rule stays standing law and a
portal-class service is the named trigger that reopens it). None of
these is a protocol change; all four are machine- and language-side
work, tracked in this project's Step 8.
