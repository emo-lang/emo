# The Noctalia Desktop's Ladder

What the noctalia desktop already stands on, and the ladder of the
development it still needs before the desktop carries the polished
effect the name promises — the translucent panels, the wallpaper that
dresses the chrome in its own colors, the icons, the motion. The ladder
is organized by layer; every item names its ground (the decision it
answers to in
[`projects/emo-desktop/docs/assessment.md`](../projects/emo-desktop/docs/assessment.md)
or the milestone it extends in
[`projects/emo-desktop/docs/TASKS.md`](../projects/emo-desktop/docs/TASKS.md)),
and the order at the end is the recommendation, not a schedule.

The product host is the metal — EmoOS on riscv64, no Linux under the
effect (D13). The sway/Wayland track is the fast development loop
(hosted seconds, grim screenshots, injected keys against the metal's
591-second boot), not the product's ground; the skin layer lands
Emo-side (the fb package) and in the kernel's compositor, and takes
nothing from the harness. The layer-shell gap named in the harness's
notes is the harness's own bookkeeping, never the metal's.

## What is standing

The skeleton and the manners are already on the metal:

- **The HD face** (M14, the A14 line): 1080p, the chrome's materials,
  the wallpaper's color bands, the shared title bar, the shelf and the
  drawn icons, the antialiased pointer — and the round corners and the
  shadows, painted into the apps' own pixels. What is missing is the
  *skin*: the effect as a service every window shares, not a trick each
  app re-draws.
- **Motion's first vocabulary** (M15, EmoOS T10): the window's rise and
  sink, eight frames of ease; the damage rectangle (T10.1) — a
  window-level repaint at ~36 ms against the full composition's
  ~230 ms; and the frame callback (verb 22), the composition itself as
  the animation's pulse.
- **The system-data layer's five modules**: the notifications —
  the toast, the history, DND (M25, D16); the wall clock and the
  calendar (M26, D17); the workspaces (M27, D18 — the verbs, the
  walk's filter, the bar's pager, the metal's assignment beats all
  graded); the launcher's enumeration behind its search face (M28,
  D14's seam and the volume's own `.elf` names); and the lock (M28,
  D19 — the account file's digest, the session taken behind the
  opaque face).

So the remaining work is not structure. It is density: the skin and the
motion.

## The ladder

### 1. The visual language — the skin layer

The main lever for the polished effect, one milestone family in four
steps, each riding the last:

1. **Per-pixel alpha compositing.** The blit is a word copy today, and
   a card must paint opaque (A25.3's own note). `win_format`'s
   vocabulary grows ARGB8888; the compositor's walk grows the src-over
   blend. This is the ground the other three stand on — the
   translucent panels, the popovers, the soft shadows are alpha's
   consumers, not features of their own.
2. **The shadow and the round corner as a service.** They exist today
   painted into pixels; lifted to the compositor they become every
   window's — third-party apps included — at no app's effort, the walk
   drawing them around the buffer it already carries.
3. **The wallpaper's decode and the palette's extraction.** A PNG
   decoder (stdlib, or the desktop's own codec package) fills the
   wallpaper's surface; the palette's extraction feeds the chrome —
   the accent and the materials are fixed constants today, and
   Noctalia's coherence is the wallpaper's own colors answering for
   them. The honest cost: a pure-Emo inflate over a 1080p image takes
   seconds at boot on the metal; the alternative is the disk carrying
   the pre-converted raw (or RLE) form, the decoder's work done once
   off the machine.
4. **The icon family and the shell's re-dress.** A rasterized icon
   strike for the launcher, the dock and the notification center (the
   `outlines.py` font precedent, run again for icons), and the panels,
   the popovers and the toasts re-dressed in alpha, round corners and
   shadows.

### 2. The motion layer

All of it the shell's own work on the frame callback — the verbs are
already there: the workspace switch's transition (a slide or a
crossfade — the compositor grows a small support for it, or the cut
stays hard while the shell animates the chrome; a decision to make
when the item opens), the toast's slide-in, the popover's spring, the
dock's hover, the focus's move. The honest ceiling stands with them:
full-screen animation at 60 fps is not the TCG's to give, and the
animation walks window-sized rects, the damage discipline it already
lives by.

### 3. The seat's modifiers

The apps' byte table carries none — the editor's save rides the `s`
key, not Ctrl+S (A25.2's named follow-up). The workspace shortcut
(super and the number) is the first consumer; a small kernel piece and
the input service's tracking, and the keyboard joins the chrome's
vocabulary.

## Two decisions the ladder leaves open

- **Blur.** Noctalia's signature, and a per-frame gaussian over the
  software compositor is beyond the TCG's honest reach. The feasible
  form is the small panel's static blur — computed once at the
  panel's opening, cached until the pixels under it change. The scrim
  and the alpha carry most of the look; blur stays a stretch goal
  until the alpha layer lands and the cost can be measured, not
  guessed.
- **Audio.** The media controls, the volume and its OSD ride the audio
  OS track (D20), parked — a virtio-sound driver, a mixer service and
  a verb family are an OS project of their own. The polished effect's
  trunk does not lean on them, and absence stays visible (D15): no
  audio, no volume widget rendered.

## The order

The visual language family (the alpha, the wallpaper's palette, the
icons and the re-dress) → the motion layer → the modifiers. The audio track stands alone, revisited only when it
exists; the network has no place on the ladder at all (D21), and the
tray has retired (D22).
