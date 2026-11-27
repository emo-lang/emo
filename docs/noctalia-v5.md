# Noctalia v5 and the Emo desktop — a research record

Written 2026-11-27. A research note against the noctalia.dev family as
it stands today — the v5 generation — asking what work remains before
the Emo desktop carries the Noctalia effect. It extends, and closes,
the older ladder in [`noctalia-desktop.md`](noctalia-desktop.md), which
was written against the shell's previous generation. This is not
decided design: the milestone numbers below are candidates, none is
opened, and M37–M42 stay reserved for the roadmap in
[`unkernel.md`](unkernel.md).

Chinese translation: [`zh-CN/noctalia-v5.md`](zh-CN/noctalia-v5.md).

## What noctalia is now

Noctalia is no longer one shell. The site presents **a family of
native Wayland projects that feel like one desktop**:

- **Noctalia Shell v5** (about 12.2k stars) — the bar, launcher,
  control center, lock screen, dock, and wallpaper-driven theming. v5
  is "a new generation of the shell, with a native runtime"; the
  Quickshell-based v4 this tree's older ladder tracked is archived
  upstream, kept for reference and receiving no updates.
- **Umbriel** (about 1.8k) — a Wayland compositor: scrolling, dwindle,
  master and stacking layouts, per-output workspaces, window rules,
  blur, shadows, fluid animations.
- **Luciole** (about 493) — a native Wayland file manager: grid, list
  and Miller views, tabs, split view, previews that never block the
  window, trash, undo and redo.
- **Greeter** — a greetd login screen mirroring the session's
  wallpaper, palette and font.

A plugin catalog the site counts at 382 entries (Luau), an IPC, event
hooks, and 105+ releases round it out. The shell runs on the major
Wayland compositors — Niri, Hyprland, Sway, MangoWC, labwc, and
Umbriel itself.

### The shell's inventory

The v5 docs' sections, which the gap analysis below walks:

- **Bars** on any edge, per-monitor overrides, and about thirty
  widgets: clock, workspaces, tray, volume, media, battery, bluetooth,
  brightness, network, weather, night light, taskbar, sysmon,
  clipboard, color picker, screenshot, session, theme mode, lock
  keys, keyboard layout, caffeine, power profile, privacy, audio
  visualizer, active window, and the control-center and launcher
  buttons.
- **Launcher** — application search, a calculator, an emoji picker, a
  wallpaper browser.
- **Control center** — home tab, sidebar, shortcuts, screen time.
- **Dock** — pinned and running apps, magnification near the pointer,
  instance badges and running dots, click to launch, focus, restore
  and minimize, per-window right-click actions, drag reordering,
  auto-hide and smart auto-hide (hide while the workspace has
  windows), an exclusive zone or an overlay layer, and a blur region
  published to compositors that take one.
- **Desktop widgets** — on-desktop widgets with an edit mode and a
  state file.
- **Wallpaper** — light and dark folders, fill modes, per-monitor
  choices, interval rotation, twelve transition effects (fade, wipe,
  disc, stripes, zoom, honeycomb, vortex, pixel, diamond, golden,
  melt, crt), favorites, and a blurred tinted backdrop copy for the
  overview.
- **Theme and palette** — built-in themes, wallpaper-color
  extraction, dark/light mode, palette color roles, custom palette
  files, terminal colors; generated app themes for terminals, editors
  and browsers.
- **Services** — audio, battery, bluetooth, brightness, calendar,
  idle, location, night light, notifications, system monitor,
  weather.
- **Desktop surfaces** — the OSD, screenshots, a session menu, the
  window switcher (Alt-Tab in four styles — carousel, compact, grid,
  icons — with MRU ordering and selectable minimized windows),
  clipboard, the lock screen.
- **Extension** — IPC commands, event hooks, Luau plugins.

### Umbriel, Luciole, Greeter

Umbriel's effect set (blur, shadows, animations) and its layout
family (scrolling, dwindle, master, stacking; window rules) are
compositor mechanism. On EmoOS the compositor is the kernel service,
so Umbriel is a reference for what the effect wants, never a port.
Luciole and the Greeter have Emo analogues already standing — the
files app, the lock — see the inventory below.

## Where the older ladder stands

[`noctalia-desktop.md`](noctalia-desktop.md) was written 2026-11-12
against the Quickshell-era shell. Its three items have since landed:

1. **The visual language** — M30 (the alpha ground: `win_format`'s
   ARGB8888 beside the word copy, the walk's source-over; the shape
   service: radius and softness per surface) and M31 (the wallpaper's
   RLE art, the palette extraction feeding the chrome its accent and
   materials, the icon family dressing the dock, the launcher and the
   notifications).
2. **The motion layer** — M32 (`emo_motion.emo`: the square's decay,
   the mirror, the spring; the focus's sweep, the launcher's spring,
   the pager's slide; D13 keeps the desk switch a hard cut). Two
   motions are parked found-not-fixed: the dock's hover and the
   toast's slide-in (the walk's digest off by one; the off-mode
   toplevel hangs the walk).
3. **The modifiers** — M33's modifier cells and the US layout's upper
   level (the editor's Ctrl+S and Ctrl+Q), and M36's Alt layer
   beneath every app (Alt+1..4 to the panel owner).

Blur stayed the stretch goal and audio its own track (D20). The
ladder that note defined is essentially complete; the remaining work
is against the v5 inventory, which has grown past it.

## The Emo baseline

M13–M36 stand complete on the metal: the HD face with real typefaces,
the rounded-and-shadowed translucent chrome, the dock, the launcher's
enumeration and the lock (M28), notifications with toast, history and
do-not-disturb (M25), the clock and calendar (M26), four workspaces
and the pager (M27), the skin's ground (M30), the motion vocabulary
(M32), the editor's caret and modifiers (M33), the clipboard (M34),
the selection (M35), the global shortcut layer (M36). Open: B7 (the
overview), B8 (Alt-Tab), the two parked motions, blur, the audio
track (D20), the network (D21, out of scope), the tray (D22,
retired). Step 17 gave the display driver its own 2 MiB run — its
arena death no longer wedges the compositor — but the driver still
has no supervisor and no flush timeout, and an app still dies of its
~200 KiB arena after a long session until the value-kind message
leak (T8.7) is fixed.

[`unkernel.md`](unkernel.md) reserves M37–M42 for its P0–P6 roadmap:
the stability ground, the dark face, the Terminal, the chrome's
behavior, the system apps, the motion budget, the materials.

## The gap inventory

### Already tracked — the P0–P6 lanes

| Noctalia effect | Where it lives |
| --- | --- |
| A session that does not die | P0 (the leak, the driver's supervisor and timeout, the soak) |
| The dark face, Semibold, kerning | P1 / M37 |
| A terminal | P2 / M38 — its colors ride the palette for free |
| Resize, snap, a control center, the top bar's meters (`sys_stats`) | P3 / M39 |
| Settings, System Info, About | P4 / M40 |
| The dock's hover and bounce, the toast's slide (M32's parked pair) | P5 / M41 |
| The window switcher (B8) and the overview (B7) | P5 / M41 — of the four styles, compact and icons first |
| The motion budget behind every animation | P5 / M41 — re-profile, then D12's pacing |
| Blur and the glass materials | P6 / M42 — the cached blur |

### New candidates — M43 and later, none opened

Ordered by value per cost:

1. **Dark/light mode.** M31's palette module is the seam: a second
   palette set, the toggle, the chrome's re-dress. Cheap; folds into
   P1 naturally.
2. **The wallpaper picker and rotation.** The wallpaper is one RLE
   file decoded at boot; `list_dir` enumerates, the picker chooses
   among pre-rendered RLEs, an interval rotates them, and a crossfade
   is the one transition inside the frame budget. PNG and JPEG
   decoding is a codec track of its own — not opened for this.
3. **Desktop widgets.** The panel role and the shell's surfaces are
   the ground; widgets with an edit mode are shell work, no new verb.
4. **The launcher's calculator and the clipboard history.** Pure Emo
   over the standing verbs (34 and 35); nearly free.
5. **The session menu.** Poweroff exists in the shell; logout and
   restart are the panel around it.
6. **A screenshot verb.** The compositor writes the carve's region
   through the filesystem service; the QEMU monitor's `screendump`
   has proven the pipeline's other half.
7. **Night light.** A per-channel integer temperature multiply at
   composition; a small compositor feature.
8. **Idle and blank.** virtio-gpu has no DPMS; an overlay surface or
   a stopped scanout plus a timer — a small kernel piece.
9. **Files v2**, the Luciole analogue — grid and list views, tabs,
   trash; an app package of its own, optional.
10. **The boot lock**, the Greeter's analogue — the lock's account
    file and face exist (M28); entering it at boot instead of the
    shell is a boot-flow change, optional.

### Gated by another track

- **Audio's whole family** — the volume and media widgets, the OSD's
  volume half, the audio visualizer — waits on the audio OS track
  (D20): a virtio-sound driver, a mixer service, a verb family. This
  is the largest single absence against Noctalia's inventory.
- **Brightness** — no backlight on QEMU `virt`; absent under D15.
- **Weather, network, bluetooth, battery** — the network is out of
  scope (D21); the rest have no hardware. Absent, visibly (D15).

### Non-goals

- **The Luau plugin system.** EmoOS's extension story already exists:
  apps are disk ELFs speaking the gate and mailboxes. No in-shell
  script runtime.
- **Umbriel's layouts and window rules** (scrolling, dwindle, master,
  stacking). Compositor mechanism, not effect; EmoOS's compositor is
  floating by design. A positioning question for another day.
- **The emoji picker** — glyph coverage is a font-track cost out of
  proportion to the widget.
- **Multi-output and per-monitor everything** — one output; an OS
  track.
- **Fractional scale** — `win_scale` takes whole multiples and an
  ARGB row refuses it (the blend and the scaling are not yet one
  walk). Tier B growth, later.
- **App-theming templates** (gtk, emacs, and their kind) — no
  third-party toolkit on EmoOS; the palette feeding the chrome is the
  analogue, and the Terminal's colors ride it through P2.

## The order

P0 first, as everywhere. Fold the dark/light pair into P1. Give P3's
control center the D15 placeholders — volume and brightness render
nothing until their tracks exist. Take B7, B8 and the parked motions
in P5, and blur in P6. Bundle the cheap M43 candidates — the picker,
the desktop widgets, the calculator, the clipboard history, the
session menu — into one desktop-richness milestone; the screenshot,
night light and idle follow as small pieces. Audio is the one
OS-side family worth opening, and only when the desktop's face is
standing on P0's ground. The tiling question, multi-output and
fractional scale stay closed until the effect is carried.

## References

- <https://noctalia.dev> — the family's page;
  <https://docs.noctalia.dev> — the v5 docs (`noctalia/`, `umbriel/`,
  `greeter/`, `luciole/`).
- [`noctalia-desktop.md`](noctalia-desktop.md) — the older ladder;
  its items landed, its note now carries a v5 update.
- [`unkernel.md`](unkernel.md) — the P0–P6 roadmap; M37–M42 reserved.
- The desktop:
  [`README.md`](../projects/emo-desktop/README.md),
  [`docs/TASKS.md`](../projects/emo-desktop/docs/TASKS.md) — M13–M36,
  B7, B8, M32's parked pair;
  [`docs/typeface.md`](../projects/emo-desktop/docs/typeface.md) — the
  Semibold drop-in, the D12 triggers.
- The machine:
  [`docs/TASKS.md`](../projects/emo-os/docs/TASKS.md) — Step 17's
  stability record;
  [`docs/syscalls.md`](../projects/emo-os/docs/syscalls.md) — verbs
  10–35 and 55–60.
