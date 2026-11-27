# The unkernel roadmap's working checklist

Written 2026-11-27. A working development list derived from the
P0–P6 roadmap in [`unkernel.md`](unkernel.md), grounded in the tree's
code as of this date. It is the working list behind the planned
M37–M42 rows now standing in the desktop tracker and Step 18 in
EmoOS's (both opened 2026-11-27); a phase's detailed task sections
land in its tracker when the phase starts. The noctalia-specific
additions live in [`noctalia-v5.md`](noctalia-v5.md) and are folded
in here only where the roadmap names them (the dark/light pair, the
wallpaper picker).

Chinese translation:
[`zh-CN/unkernel-plan-list.md`](zh-CN/unkernel-plan-list.md).

## Grounding facts (2026-11-27)

- The display driver is `gpu_service` in `projects/emo-os/main.emo`
  (the boot's fourth spawn); `comp_supervisor` in the same file
  watches the compositor and holds the driver's pid — but the driver
  itself has no supervisor, and the compositor's flush wait has no
  timeout. Step 17's gap stands.
- The value-kind message leak is T8.7's documented leak: a message's
  copy lands in the receiving service's arena and the bump allocator
  never hands a boxed value kind back; an app dies at about 100
  presents.
- The `feat/emo-terminal` worktree is gone; its evaluation survives
  only in the record, so the conclusions restated here are the
  checklist's ground: approach B (the EmoUI loop over a mono cell
  grid, carve-drawn), three gaps (the key table, Style without
  color, the child process's output routing — the kernel's Tier C),
  and three open questions (the approach's confirmation, poweroff's
  semantics, the counter's way out).
- The desktop's packages live in `projects/emo-desktop/fb/`:
  `ui_fb.emo` (the core), `raster.emo` (the faces and strikes),
  `desktop/` (the shell), `win/`, `winbuf/`, `apps/` (counter,
  editor, files, spin), `glyphs/`, `fonts/`, `type/`, beside
  `pointer.emo`.

## P0 — the ground (hard prerequisite; runs beside P1)

| # | Task | Where | Done when |
| --- | --- | --- | --- |
| P0.1 | Fix the value-kind message leak (T8.7). Probe first: hosted, a process loops boxed values across the gate, the arena read each pass. Then fix the message copy path's accounting (the gate's `copy_to`, the mailbox copy). The fallback — porting the c target's frame-scoped pool to riscv64 — is the bigger road, taken only if the message path will not close. | `projects/emo-os` (`gate.emo`, the arena/space files); `src/` only if the fallback fires | The probe's 10k messages leave the arena flat; `run.sh` green |
| P0.2 | The display driver's supervisor and a flush timeout: grow `comp_supervisor`'s lineage onto `gpu_service` itself (the death hook, the restart into the same cache block); give the compositor's flush wait a timeout, so a dead driver's lost reply cannot park it forever. | `projects/emo-os/main.emo` (`gpu_service`, `comp_supervisor`), `gate.emo` | The golden grows a "kill the driver → it restarts → the screen recovers" beat; no wedge |
| P0.3 | The ten-minute soak: QEMU beats drive the loop — drag, open and close, the launcher, the editor, the clipboard — under both transports. | `projects/emo-os/run.sh` (or a soak script beside it) | Both transports green: no `heap gone`, no wedge, a flat frame ledger |

## P1 — the dark face (M37; hosted first)

| # | Task | Where |
| --- | --- | --- |
| P1.1 | The design tokens module: a Geist-like neutral ramp, the wallpaper's accent (M31's extraction, tokenized), 8 px spacing, radii 6/10/16, the shadow/opacity/motion recipes over `emo_motion`. | `fb/desktop/` (a new module, say `emo_skin.emo`) |
| P1.2 | The Inter Semibold face — the typeface note's named drop-in (`outlines.py` generates, the Strike machinery stands). | `fb/glyphs/`, `fb/fonts/` |
| P1.3 | Kerning for the chrome's visible pairs (hinting below 14 px stays behind the D12 trigger). | `fb/raster.emo` |
| P1.4 | The unified window chrome: the title bar, the controls, the tab strip's base (P2's ground). | `fb/desktop/`, `fb/win/` |
| P1.5 | The dock's and launcher's geometry re-laid. | `fb/desktop/` |
| P1.6 | The top bar's status area and the cursor family (I-beam, the resize pair — P3's users). | `fb/desktop/`, `fb/pointer.emo` |
| P1.7 | Optional: the dark/light palette pair and its toggle (noctalia-v5's fold-in). | the tokens module |

Done when: the boot screenshot at the target resolution and a
three-window scene match the design; goldens byte-identical; zero new
verbs.

## P2 — the terminal (M38)

| # | Task | Where |
| --- | --- | --- |
| P2.0 | Decide the terminal evaluation's three questions: approach B confirmed, poweroff's semantics, the counter's way out. Decided before code. | a decision, then the tracker |
| P2.1 | The session base: the pipes (verbs 55–60) and fork/exec's 0..2 inheritance, the shell as the child. | the standing gate |
| P2.2 | The terminal window: the mono cell grid, strike-drawn (approach B); tabs, the scrollback ring, selection over M35's mechanism, copy and paste over verbs 34/35, the blink on the frame callback (verb 22), the ANSI subset (SGR colors, cursor addressing). | `fb/apps/terminal/` (new) |
| P2.3 | Multiple sessions — the tabs. | `fb/apps/terminal/` |
| P2.4 | The child's output routing — the evaluation's kernel Tier C gap: check whether the pipe read-back suffices, and only then grow a verb. | `projects/emo-os/` (as needed) |

Done when: the dock opens the Terminal; `ls`, `cat` and the editor
run; tabs; copy and paste; a metal golden and beats.

## P3 — the chrome's behavior (M39)

| # | Task | Where |
| --- | --- | --- |
| P3.1 | `win_resize` and the resize event (a Tier C addition): the compositor takes a new run, remaps, repaints; the app re-lays out; the docs and the locks ride. | `projects/emo-os/gate.emo`, `space.emo`; `syscalls.md`, `desktop-abi.md` |
| P3.2 | Edge snap, the snap preview, double-click maximize (M16's base stands). | `fb/desktop/` |
| P3.3 | Dock stacks and popovers, context menus, the launch bounce (the behavior; the motions are P5's). | `fb/desktop/` |
| P3.4 | The Control Center's v1: DND, wallpaper, lock, display mode; volume and brightness render nothing (D15) until their tracks exist. | `fb/desktop/` |
| P3.5 | `sys_stats` (a Tier C addition) and the top bar's meters. | `projects/emo-os/gate.emo`; `fb/desktop/` |
| P3.6 | The in-window menu primitive (no top-bar app menus in v1). | `fb/desktop/`, `fb/win/` |

Done when: drag, resize, snap, minimize and restore all pass; a stack
opens; the meters live; goldens.

## P4 — the system apps (M40)

| # | Task | Where |
| --- | --- | --- |
| P4.1 | Settings: appearance, accent, wallpaper, display, shortcuts, about, lock — providers behind the D14 seam with fixtures. | `fb/apps/settings/` (new) |
| P4.2 | System Info: CPU, memory, uptime, processes, disk — on `sys_stats`. | `fb/apps/` (new) |
| P4.3 | About. | `fb/apps/` |
| P4.4 | The Files and Editor reskin; the wallpaper picker choosing among pre-rendered RLEs. | `fb/apps/files/`, `fb/apps/editor/` |

Done when: every app is a disk ELF launched from the launcher; no
canned data in the running shell (D15).

## P5 — the motion budget (M41; measurement first)

| # | Task | Where |
| --- | --- | --- |
| P5.1 | Re-profile the composition after alpha and the RLE wallpaper: the walk, blit, alpha, shadow, text, transfer and flush, each in the ledger. | the `run.sh` ledger, probes beside it |
| P5.2 | The optimizations the numbers name: the opaque fast path, per-size mask/shadow caches, the glyph cache, damage-only repaint, coalescing, direct scanout for a full-screen opaque surface; an `.S` blitter only on the numbers' word. | `fb/desktop/`, the compositor's walk |
| P5.3 | Land M32's parked pair: the walk's digest off by one; the off-mode toplevel hanging the walk. | `fb/desktop/` |
| P5.4 | The motions: the minimize genie, the dock's hover and bounce, the toast's slide, the Control Center's spring. | `emo_motion`, the shell |
| P5.5 | Overview (B7) and Alt-Tab (B8) — compact and icons first. | the shell, the input layer |

Done when: at 1280×800 a 640×480 window drags at ≥30 fps (800×600 at
≥20); every motion fits its budget; the overview at ≥15 fps.

## P6 — the materials (M42; the decision gate)

| # | Task |
| --- | --- |
| P6.1 | The cached blur: the wallpaper computed once at boot, the panels reusing the cache, a window moving underneath invalidating; downsample-blur-upsample. |
| P6.2 | The glass's tint, noise and edge light. |
| P6.3 | The decision: within budget it lands; otherwise D15 records the absence and alpha plus scrim ship. |

The GPU and multi-hart spikes wait for P5's numbers; they are not on
this list's schedule.

## Discipline (every task)

- Hosted first, metal acceptance; both transports byte-exact.
- A verb's content moving re-pins the locks.
- `@fmt` green before delivery.
- Metal verification runs this tree's own `_build` binary — the
  PATH's `emo` points at a parallel checkout's build.
- Commits land on develop, on the user's word.

## The starting order

P0.2 first — the smallest, and it retires the wedge at once. Then
P0.1's probe — the hard prerequisite, diagnosis first — with P1.1's
tokens on the hosted canvas in parallel. P2.0's decisions can ride
any idle moment; P3.1 is the trunk's first protocol growth and waits
for the dark face to be pinned.
