# The console renderer — EmoUI on EmoOS

How the machine shows its first frame: the declarative renderer that
runs as a user pass between the proof chain and the shell, the node
vocabulary it renders, the loop that drives it, and the bounds it
states. Fixed as of T7.4 (2026-10-31). Around it: the shell
([`shell.md`](shell.md)) takes the console when the pass exits; the
verbs it speaks are [`syscalls.md`](syscalls.md)'s; the portable core
it mirrors is [`projects/emo-ui/`](../../../../projects/emo-ui/)
(the main tree's [`docs/emo-ui.md`](../../../../docs/emo-ui.md) is the
design's standing record — this note carries it to the machine the
language booted).

Chinese translation: [`ui.zh-CN.md`](ui.zh-CN.md).

## What it is

EmoUI's console backend on EmoOS. A user pass builds a declarative
node tree, the renderer lays it into a cell grid, and the grid rides
the gate's write verb to the console service — the same path the
kernel's `println` and the shell's every byte ride. Events ride the
read verb back: the console's keys are the loop's input, the model
changes, the tree rebuilds, the frame repaints. The pass is the
machine's third kind of resident — neither kernel nor service nor
shell, but an application — and the closure demo's last piece: the
kernel is Emo, the shell is Emo, and the UI is Emo, one language from
the trap shim to the frame on the wire.

## The currency

The console's text is raw bytes. The riscv64 backend's String surface
is equality only — every String method refuses by name — so the node
vocabulary carries addresses and lengths where the hosted core carries
Strings: a `Text`'s body is the address and length of bytes in the
image's read-write segment, poked there at start from byte-array
literals (the shell's discipline, `shell.emo`'s texts; the arrays are
read one element at a time into raw memory — no array-element
assignment anywhere, the target refuses it, and no String-to-bytes
path exists to reach for). The style measures in whole cells —
`Int64` — because the console's only unit is the character cell and
half a cell is nothing it can show.

## The spine

The hosted core's spine, carried to the console's currency:

- **`Node`** — the interface every node answers: `style()` and
  `children()`. One tree type, so nodes compose with nodes.
- **`Column`**, **`Row`** — the containers, an `Array[Node]` of
  children and a style. A tree known at write time is array literals;
  `ArrayBuilder` is not part of the walk (the target refuses its
  construction — `E2015`'s neighbor — so nothing in the spine may
  reach for it).
- **`Text`** — the leaf that shows bytes: an address, a length, a
  style.
- **`Button`** — the leaf that carries an event: a label, the event's
  tag, a style. A button is the event's carrier, never a closure —
  the hosted core's own contract, and on this backend the tag is a
  constant of the application's (the loop section says why).
- The four lowercase factories — `column`, `row`, `text`, `button` —
  so a tree reads as EmoUI trees read: nested calls, `.new` never in
  the tree.

What stayed hosted, on purpose: `Align`, `grow`, fixed widths and
heights, `Scroll`, `TextInput`, `Image`, `Spacer`. A carried value the
renderer would ignore is a silent fallback, and a node kind nothing
renders is a construct without its place; each joins when a frame
needs it and the golden proves it.

## The frame

The frame is a `width × height` grid of cells in raw memory,
`(width + 1)` bytes per row — the last byte of every row a newline,
poked once at start, so the whole frame is **one write** through the
gate (the staging bound is 2048; the frame fits with room to spare).
Each repaint clears the grid's cells to spaces (the newline column
excepted), walks the tree, and writes the grid: `height` lines of
exactly `width` bytes on the wire, the trailing spaces the frame's
own. A draw past the grid's edge is clipped — the renderer's job, the
frame's own bound, not a silent fallback.

## The layout

The TUI backend's box model, carried to the cells the console can
afford: a column stacks its children downward, a row lines them up to
the right, `padding` insets a container's children on every side,
`gap` separates them. Sizes are intrinsic — a leaf measures its
bytes (a button two more, for the brackets the renderer draws around
its label), a container its children plus its padding and gaps — and
the walk places what was measured. Nothing stretches, nothing centers,
nothing scrolls: the vocabulary above is what the frame uses, and the
arithmetic is the TUI's, minus the parts the console has no consumer
for.

## The loop

The Elm loop, typed. A model, a pure `update(model, tag)`, a pure
`view(model)` — the three functions, with the console's event source
in the loop's seat: one blocking byte from the read verb, mapped by
the application onto a tag, the tag through `update`, the model
through `view`, the tree through the renderer. The repaint is whole —
the TUI's own decision (a terminal never diffs, `patch`'s old tree is
an offer it never needs) — so the hosted loop's tag registry stays
hosted: a full repaint needs no tag stability, the tags are the
application's constants, and a button's event is one of them. The
console's keys map onto the tags by the application's own rule — the
app decides which bytes are its events, and **the unmapped byte is
dropped, never guessed at** (the shell's line discipline's rule,
carried). Nothing echoes: the frame is the answer.

The loop ends on its own tag — the application's quit — the way the
TUI's run loop ends when its input is exhausted. The pass's exit
follows: the boot-pass exit verb, answered by the parent's wait, the
REPL's prompt after it.

## The demo — the counter

The application the golden runs: a counter, the Elm architecture's
own example, at the console's scale. The frame is 32×8, the root
column padded one cell and gapped one:

    (blank — the padding)
     EmoUI on EmoOS
    (blank — the gap)
     count 000
    (blank — the gap)
     [a plus]  [b minus]  [q quit]
    (blank — the padding)
    (blank)

`a` and `b` are the model's events (plus and minus, the count clamped
at 0 and 999 — three digit cells, repoked before each frame, the tree
referencing the fixed cell), `q` is the loop's own. The keys ride the
read verb one at a time; the frames ride the write verb one per event.

## The bounds

- **The pass's arena is 64 KiB, and no collector exists.** The tree
  rebuilds per event and nothing reclaims; the demo's session is the
  golden's three keys against that arena, and a session that paints
  forever is the exhaustion kill — the lifetime bound every user pass
  lives under, stated here because the loop's whole job is rebuilding
  what nothing frees.
- **The renderer owns the console exclusively while it runs.** One
  reader at a time is the console service's oldest-request discipline
  (T3.7): the parent parks at the wait before the pass's first read,
  and the REPL starts when the pass has exited.
- **The frame clips at its edge.** The grid is the whole world the
  renderer draws in; a tree wider than the frame loses the excess
  bytes the frame's bound loses.
- **The kernel changes nothing.** The gate routes the read and write
  verbs it has routed since T4.2; the whole task is user-side,
  `run.sh`, and this note.

## The pins

`run.sh`'s chain grows the pass's exchange between the proof chain's
last line and the REPL's first prompt, under both timer transports:
the first frame on the wire the moment the pass is spawned — the
title line, the count's `000`, the buttons row — `count 001` after
the first key, the quit key ending the pass (its exit answering the
parent's wait, the second `count 000` unasserted — the first
occurrence already proves the frame), and the REPL's prompt after it,
the machine's foreground resuming. Three consecutive rounds
byte-identical on each leg; the frame ledger grows by the pass's
stack and arena — taken at the spawn, given back at the exit.
