# emo-desktop

The desktop above the gate: a composited-window GUI for EmoOS, written in Emo — the screen, the pointer, the glyphs, the windows, the dock, and the apps on it, one language from power-on to the desktop. It is the continuation of EmoOS's single-language closure into the last layer the machine has: after the kernel, the services, the shell, and the console UI, the desktop is the proof's next mile.

emo-desktop is a project of its own beside [`projects/emo-os`](../emo-os) and [`projects/emo-ui`](../emo-ui), and the boundary between them is the machine's own: **the gate.** Everything below the gate — device drivers, the compositor's mechanism, gate verbs, address-space and frame plumbing, the ABI's stability contract, the smoke's display leg — is EmoOS's and lives in the EmoOS tree. Everything above the gate — the framebuffer backend, the fonts, the desktop shell, the apps, their hosted corpus — is this project's.

Chinese translation: [`README.zh-CN.md`](README.zh-CN.md).

## Position

- **Wayland/Quartz shape, QNX Screen lineage.** A compositor owns the scanout; clients render into authorized buffers and present them; input is a unified event stream. This is the same lineage EmoOS's microkernel already claims, applied to pixels.
- **A package collection, not a second image.** The kernel embeds exactly one user image; through M7–M10 the desktop rides that image as packages (`require`d by the boot image, the `syscall` stub package's precedent). At M11, when programs load as ELFs from the filesystem, the apps become disk ELFs in place — the structure does not change.
- **Hosted core, metal shell.** The fb backend's logic (measure, place, clip, blend against a buffer interface) is portable Emo that runs hosted in the corpus and on the metal; only the thin raw shim (`peek`/`poke`) is riscv64's alone. The dual-run discipline EmoOS proved carries up. The core is landed as [`fb/`](fb/) — the packages `emo/ui_fb` (the core, carrying the project's own bitmap font since A8.1 and its pointer sprite since A8.2), `emo/ui_fb_canvas` (the hosted surface), `emo/ui_fb_frame` (the first frame) and — since A9.1 — `emo/ui_fb_win` (the window shell's windows), with their tests, goldens and gate (`fb/check.sh`); beside them the first apps (`fb/apps/`, `emo/ui_apps` — the counter, the file browser and the editor, each a corpus package the desktop's own gate runs beside the family's), the apps' own program trees (`fb/apps/counter/` and its siblings — the disk ELFs' sources, one `main.emo` session each) and their shared metal package (`fb/winbuf/`, `emo/ui_fb_winbuf` — the window buffer's raw shim, the byte table in the input's seat), and the shell's chrome (`fb/desktop/`, `emo_desktop`); the carve surface behind the shim lives with EmoOS's user image, and the first frame the core paints through it is what the machine's screen shows at boot — one digest read off the carve, the hosted canvas and the display alike.

## Naming — decided

- The project directory: **`projects/emo-desktop`** (not `emo-gui` — two `ui`-headed top-level projects would be a chronic confusion; decided 2026-10-31).
- The framebuffer backend package: **`emo/ui_fb`** — EmoUI's sixth backend, joining the interpreter, TypeScript, wasm, BEAM, and console families.
- The desktop shell package: **`emo_desktop`** — a flat system name, the `emo_os` precedent.
- The first apps' package: **`emo/ui_apps`** — one family package, the three apps its submodules, each a corpus package in `emo/ui_corpus`'s discipline.
- The directory names the project; the package names name the family.

## The roadmap

| Milestone | Scope | Status |
| --- | --- | --- |
| M7 — The screen | the virtio-gpu path, the screen carve, the first full-screen frame, present | complete |
| M8 — Glyphs & pointer | bitmap fonts, the pointer sprite, the input merge, the Elm loop on metal | complete |
| M9 — Windows | the composited window loop, drag, focus, kill-and-restart, the growth contract's five increments | complete |
| M10 — The desktop | the EmoUI fb backend whole, the dock, the first apps | complete |
| M11 — Honest multi-app | ELFs from the filesystem, per-image segment tables, per-process gate checks | complete (one at a time; A11.2's two-image desktop is next) |

The compiler track (the literal-width fix, the N-block arena, the frame-scoped pool) runs beside the ladder, not inside it — its tasks are the Emo tree's and the EmoOS tracker's.

## What the experience is — and is not

Reachable: composited windows, drag, focus, the mouse, bitmap fonts, a dock, real apps (a counter, a file browser, an editor). Not reachable on this stack: GPU acceleration, antialiasing, animation-grade frame pacing, hard real time. The honest feel is an early-90s workstation with a Mac OS 9 temperament. The architecture's growth path beyond that is part of the record: [`docs/assessment.md`](docs/assessment.md) carries the scalability contract (what is frozen, what may move, what may be added) and the full research discussion, including the decision points, decided ahead of M7 (2026-10-31).

Per-task checklists live in [`docs/TASKS.md`](docs/TASKS.md). The kernel-side half of every milestone lives in [EmoOS's tracker](../emo-os/docs/TASKS.md); the ABI's stability contract is [EmoOS's document](../emo-os/docs/desktop-abi.md).
