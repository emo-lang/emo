# unkernel and EmoOS — an assessment and a desktop roadmap

Written 2026-11-27. An assessment of the unkernel project and a
proposed roadmap for carrying its desktop UI's design language onto
EmoOS. This is not decided design: the roadmap below is opened as
planned rows in the projects' trackers (2026-11-27) — M37–M42 in the
desktop tracker, Step 18 in EmoOS's — and the measurements are the
tree's as of this date.

Chinese translation: [`zh-CN/unkernel.md`](zh-CN/unkernel.md).

## The project

unkernel is, in its own words, "a real Linux kernel, compiled to
WebAssembly. It boots to a shell in less than a second." It runs
unmodified aarch64 Linux binaries — Alpine and Debian packages as
they ship — on a kernel whose syscalls, scheduler, memory management,
ext4 and TCP/IP are compiled code rather than emulated hardware.

### The inversion

The README's own contrast is the clearest statement of what it is:

- **Whole-machine emulation** (v86, JSLinux, QEMU-in-wasm) is
  faithful but slow: every syscall and page fault goes through
  emulated hardware.
- **Syscall emulation** (WASIX, WebContainers) is fast but covers
  only as much Linux as the runtime implements.
- **Programs compiled to wasm on NOMMU kernels** (linux-wasm, LKL)
  are fast but require rebuilding, and fork and anything else that
  needs an MMU breaks or is approximated.
- **unkernel keeps the real Linux kernel**, runs it natively as
  wasm, and emulates only user space, under a real MMU.

The name is not "unikernel". unkernel removes the *emulated kernel
mode*, not the kernel: a syscall is a return from `kwemu` into the
kernel, which handles it as native wasm; there is no emulated trap
and no emulated kernel mode in between.

### The pieces

- **Kernel:** Linux 7.3.4 as one wasm module (`arch/wasm`, grown from
  Joel Severin's linux-wasm port), built wasm64 and lowered to a
  32-bit-memory module for the hosts.
- **User space:** unmodified aarch64 binaries on kwemu, an aarch64 CPU
  written in Zig and linked into the kernel (`src/`, contract
  `include/kw_emu.h`).
- **Task switches:** JSPI (`WebAssembly.Suspending`) gives the kernel
  real stacks it can suspend and resume.
- **MMU:** real, Sv48 page tables; kwemu walks the kernel's own tables.
- **Devices:** small paravirtual drivers to the JavaScript host —
  kwblk, kwnet (a JS user-mode TCP/IP stack), kwfb/kwinput/kwsnd,
  kwvsock, kwshm; GL through virglrenderer, Vulkan
  (`vk/PROTOCOL.md`), VA codecs; ext4, overlayfs, tmpfs, loop, FUSE
  and 9p.
- **Execution tiers:** blocks decoded into compact ops, a reference
  interpreter, and a JIT that compiles hot blocks to wasm with output
  matching the interpreter bit for bit; FP/AdvSIMD and rarely-run
  code stay interpreted.
- **Toolchain:** Zig 0.16, Node 24, LLVM/clang 22 with a patched
  wasm-ld, Binaryen 133; the kernel series applies on Linux v7.3.4.

### The numbers and the limits

- Boot to `/init` is about 70 ms; the Alpine prompt appears about
  0.3 s after node starts.
- `getppid` takes about 170 ns (against about 1.7 µs under
  qemu-system); fork + exit + wait is about 60 µs against about
  70 µs natively.
- The JIT makes shell loops 1.6× and sort 2.3× faster than the
  interpreter alone.
- CPU-heavy work still lags: `apk search` about 0.8 s and
  `apk add python3` about 3.4 s.
- Limits: one CPU by default in the SDK/CLI (the page boots several
  where possible; SMP snapshots resume only on the same CPU count),
  no IPv6, no UDP beyond DHCP/DNS, no inbound connections, no
  hardware breakpoints or watchpoints, FP/AdvSIMD interpreted, and a
  wasm trap in the kernel ends the session. Hosts are Node 24 and
  browsers with JSPI (the README lists Chrome/Edge 137+, Firefox
  153+, Safari 27+).

### The project's state

The repository was created 2026-11-12; as of 2026-11-27 it has about
1,950 stars and 107 forks and is actively pushed. The kernel and its
patches are GPL-2.0 (or later, per file); the SDK and the page are
MIT. The engineering is serious and dense — a patched wasm-ld, a
fake-LLVM Kbuild wrapper, UP and SMP kernels, distro images, a
profiler and a documented test matrix — but the project is young and
carries the long-term maintenance of a Linux 7.3.4 patch series.

## Why it is not EmoOS's implementation principle

The category is the first thing to get right: unkernel is a **hosted
compatibility runtime**, not an OS implementation principle. Its
machine is the browser or Node host and its devices are JavaScript;
its kernel is Linux. EmoOS's machine is QEMU `virt` or real RISC-V,
its devices are the 16550A, the PLIC and virtio, and its kernel is
Emo. The two projects agree on one sentence — "emulate only what must
be emulated" — and disagree on every term in it.

| Axis | unkernel | EmoOS |
| --- | --- | --- |
| Machine | browser / Node + JS devices | QEMU `virt` / real RISC-V; OpenSBI; the kernel owns its console |
| Kernel | real Linux (GPL-2.0) | a microkernel written in Emo (MIT) |
| Address space | wasm has no MMU; software Sv48 | hardware SV39, a trampoline, fault-to-kill |
| Scheduling | JSPI, cooperative, host-provided stacks | tick preemption, trap frames and kernel stacks |
| User space | emulated aarch64 binaries | Emo/C sources recompiled to native riscv64 (Plan B) |
| Devices | `kw*` to the JS host | drivers as processes over virtio and the PLIC's lines |
| Closure | Linux + Zig + TypeScript + JS | one compiler, one language, from power-on to prompt |

The three pillars, and where each collides:

1. **A native kernel with an emulated user space.** The native kernel
   is Linux. Adopting it would replace the Emo kernel, break the
   single-language closure and relicense the distribution under
   GPL-2.0. This alone decides the question.
2. **Reuse the existing kernel's semantics instead of reimplementing
   them.** That is unkernel's real efficiency: it does not
   reimplement Linux; it ships Linux and emulates only the CPU.
   EmoOS cannot have that without shipping Linux, which is the thing
   it is not. The road not taken is Plan A, the Linux personality —
   and [`EmoOS.TASKS.md`](../projects/emo-os/docs/EmoOS.TASKS.md) has
   already decided against it for the isolation reason.
3. **The host supplies devices and lifecycle.** EmoOS's "The machine"
   section is the opposite: profile A enters at `0x80200000`, one
   hart, the kernel's own putc in the runtime's console hook, the
   PLIC's line in the trap shim, virtio-gpu's 2D path. None of it has
   a host to lean on.

Two of unkernel's mechanisms are compensations, not lessons: the
software Sv48 walk exists because wasm has no MMU, and JSPI exists
because wasm stacks cannot otherwise be suspended. EmoOS gets the
first from SV39 and the second from its own trap frame and kernel
stack. The performance asymmetry points the same way: unkernel's
~60 µs fork is "native Linux + emulated user space"; EmoOS's fork is
native riscv64 instructions. On CPU-bound work EmoOS is on the native
side of the gap, not the emulated one.

## What is transferable

The boundary principle, and only that:

- **Emulate only what must be emulated.** EmoOS already applies it by
  another route: trust lives at the process boundary, Emo/C code is
  compiled native, and the gate is the only sanctioned crossing.
  Plan B is this principle with the compiler as the compatibility
  layer.
- **If Linux binaries ever matter**, the honest shape on EmoOS is a
  user-space Linux compatibility process — a CPU emulator plus a
  Linux syscall translator speaking the gate — not Linux in the
  kernel. That is a product decision that reopens Plan A, and the
  isolation cost is the one `EmoOS.TASKS.md` already priced.
- **If a browser-hosted EmoOS ever matters**, the `kw*` device ABI,
  JSPI scheduling and the host boundary are the reference; and Emo's
  `wasm` target means user code compiles to wasm directly, with no
  emulation layer at all. That is an additional deployment target,
  never the metal OS's principle.
- **Verification.** unkernel's interpreter/JIT bit-exactness and
  EmoOS's hosted/metal byte-exactness are the same discipline.
  Nothing new to import.

## The UI target

The desktop this question is about is the **host page** (`web/`), not
a guest GUI. unkernel's `.agents/web.md` describes it: a macOS-style
desktop drawn in the DOM — its own window manager, windows on a
wallpaper, a Dock, a transparent top bar (menus, resource meters, the
Control Center), a launcher with folders, Terminal windows with tabs
(wterm; more sessions over vsock), the guest display and preview,
Settings and System, an installer, the guest's Wayland apps as
windows, an Overview, snap previews, dialogs and toasts, and a key
bar for touch. It is React + Tailwind v4 (a dark theme after Geist),
Vite on the client and Nitro on the server.

Half of its polish is the browser compositor: GPU compositing, real
backdrop blur, 60 fps, full text shaping. EmoOS is a software
rasterizer on one TCG hart. So the work is **a re-creation of the
design language and the interaction model in Emo/EmoUI**, not a port
of the code; the only literal port would be a browser engine inside
EmoOS, which loses the closure and the performance at once.

EmoOS is not starting from zero. M13–M36 already stand: the macOS
face, the HD desktop with real typefaces, rounded and shadowed
shapes, translucent chrome, the RLE wallpaper and its palette, the
icon family, the dock, the launcher and the lock, notifications, the
clock and calendar, four workspaces, the editor/files/counter apps,
the clipboard and selection, Alt+1..4, and the motion vocabulary.
The work is density and frame rate, not structure.

Three bottlenecks order the work:

1. **Session stability.** Step 17's record: the boxed value-kind
   message leak (the documented T8.7 leak) kills an app's arena after
   about 100 presents; the display driver has no supervisor, and a
   lost flush reply parks the compositor forever. A beautiful desktop
   that dies in a session is not a desktop.
2. **The frame budget.** M15 measured about 230 ms for a whole-screen
   composition and about 36 ms for a 384×256 window's damage (about
   100 ns/word). Alpha and the RLE wallpaper have since added cost;
   the first task is to measure again, not to guess.
3. **Type and materials.** Inter and JetBrains Mono Regular only,
   whole-pixel advances, no kerning or hinting (the typeface note's
   D12 triggers); per-pixel alpha since M30, and blur still a
   stretch goal (the noctalia note). The browser has both without
   asking.

## The roadmap

Proposed numbering: `projects/emo-desktop` M37–M42, with the kernel
half as steps in
[`projects/emo-os/docs/TASKS.md`](../projects/emo-os/docs/TASKS.md).
The order is value per cost; P0 and P1 can run in parallel, and P2's
Terminal only needs the substrate already on the tree.

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| **P0 — The ground** (prerequisite) | Fix the value-kind message leak (T8.7) or give each app a reclaim path; a supervisor and a flush timeout for the display driver; a ten-minute soak (drag, open/close, launcher, editor, clipboard) | Both transports soak green; no `heap gone`, no wedge, flat memory |
| **P1 — The dark face** (M37) | Design tokens: a Geist-like neutral ramp, the wallpaper's accent, 8 px spacing, radii 6/10/16, shadow/opacity/motion recipes; Inter Semibold (the typeface note's named drop-in), kerning for the chrome's visible pairs, hinting below 14 px; a unified window chrome (title bar, controls, tab strip); dock and launcher geometry; the top bar's status area and the cursor family. Iterate on the hosted fb canvas first | A boot screenshot at the target resolution and a three-window scene match the design; goldens byte-identical; no new gate verb |
| **P2 — The Terminal** (M38) | A session over the existing pipes (verbs 55–60) and fork/exec's 0..2 inheritance; a terminal window with tabs, scrollback, selection, copy/paste, cursor blink and an ANSI subset; multiple sessions | Open Terminal from the dock, run `ls`/`cat`/`editor`, multiple tabs, copy and paste; a metal golden and beats |
| **P3 — The chrome's behavior** (M39) | `win_resize` and a resize event (Tier C; the compositor takes a new run, remaps, repaints; the app re-lays out); edge snap, snap preview, double-click maximize; dock stacks/popovers, context menus, launch bounce; a Control Center (DND, wallpaper, lock, display mode; volume absent until audio, brightness with no hardware, both under D15); `sys_stats` and the top bar's meters; an in-window menu primitive (no top-bar app menus in v1) | Drag/resize/snap/minimize/restore all pass; a dock stack opens; meters live; goldens |
| **P4 — The system apps** (M40) | Settings (appearance, accent, wallpaper, display, shortcuts, about, lock), System Info (CPU/memory/uptime/processes/disk), About; Files and Editor reskinned; a wallpaper picker | Every app a disk ELF launched from the launcher; providers behind the D14 seam with fixtures; no canned data in the running shell (D15) |
| **P5 — The motion budget** (M41) | Re-profile the composition (walk, blit, alpha, shadow, text, transfer, flush); optimize the opaque fast path, per-size mask/shadow caches, the glyph cache, damage-only repaint, coalescing, direct scanout for a full-screen opaque surface, and an `.S` blitter if the numbers ask; pace frames on the present reply (D12); land the parked M32 motions (the digest off by one, the off-mode seat hang), then minimize genie, dock hover/bounce, toast slide, Control Center spring; Overview (B7) and Alt-Tab (B8) | A 640×480 window drags at ≥30 fps (800×600 at ≥20) at 1280×800; every motion fits its budget; Overview ≥15 fps |
| **P6 — The materials** (M42, gated) | A cached blur (the wallpaper once at boot; a panel reuses the cache; a window moving under it invalidates; downsample-blur-upsample); glass tint, noise and edge light; if the budget refuses, record the absence under D15 and ship alpha plus scrim; GPU/virgl or multi-hart tile composition only as a measured research spike | Blur lands within budget, or is declined with the numbers |

### Phase notes

- **P0's leak is the one hard prerequisite.** The static skin can be
  built on the hosted canvas while it is fixed; metal acceptance
  waits.
- **P2 is cheaper than it looks.** Pipes (55–60), fork and exec's
  low-fd inheritance are already in the gate; the shell is the
  machine's REPL today (emosh's branch is the richer line editor when
  it lands), and the terminal is the desktop-side window and cell
  renderer over them. It is the most visible piece per unit of work.
- **P3 carries the trunk's two Tier C additions.** `win_resize` with
  its resize event, and `sys_stats`: both additions under the
  numbering-freeze rule, and the eight seams hold. If resize slips,
  snap and maximize can land on moved windows only.
- **P5 starts with a measurement, not an optimization.** The M15
  numbers predate alpha and the RLE wallpaper; the new profile is the
  input to every later choice, including whether a GPU or SMP track
  is justified.
- **P6 is a decision gate, not a promise.** The browser's blur is
  free; the metal's is not. Alpha, scrim and a cached blur are the
  honest version.

## The fidelity ceiling

The software path's realistic target is **1280×800 or 1440×900,
window-sized motion at about 30 fps, hard cuts for full-screen
transitions (D13's decision), and a static cached blur**. That
carries unkernel's static look and most of its interaction; it does
not carry 60 fps full-screen motion or a live backdrop blur.

The two routes past that ceiling are both tracks of their own:

- **GPU.** The growth contract's Tier B already allows "the blit may
  become GPU work"; the eight seams (among them buffer as capability,
  formats and scale as fields, the frame callback, atomic commit) were
  built for it. But it needs a GPU path that QEMU on macOS can actually
  serve (virgl support has to be verified first), and real RISC-V
  boards have no such path at all.
- **Multi-hart composition.** `-smp` is parked, not impossible; tile
  parallelism could cut a full-screen walk by the hart count. It is
  an SMP kernel milestone, not a desktop one.

Neither should be opened before P5's numbers exist. The
recommendation is the software path first.

Type is the second-largest lever and the cheapest: a Semibold face,
kerning for the visible pairs, and hinting only below 14 px (the
typeface note's named triggers). The browser's shaping engine is
still ahead; at UI sizes the gap is small, and it is paid once per
glyph.

## Non-goals

- No React/Tailwind/DOM port and no browser engine inside EmoOS.
- No unkernel kernel, wasm or GPL code; the page is MIT, which
  settles the assets, and the design language is the reference.
- No Tier A ABI break for beauty: resize and stats are Tier C
  additions, and the numbering freeze holds.
- No guest display, installer or Wayland-app windows: EmoOS is the
  machine, and its analogue is a native app. The guest preview in
  unkernel exists because unkernel hosts a Linux it did not write.

## References

- unkernel: <https://github.com/pithings/unkernel> — `README.md`,
  `kernel/README.md`, `.agents/web.md`, `.agents/status.md`.
- The desktop:
  [`projects/emo-desktop/README.md`](../projects/emo-desktop/README.md),
  [`docs/assessment.md`](../projects/emo-desktop/docs/assessment.md),
  [`docs/typeface.md`](../projects/emo-desktop/docs/typeface.md),
  [`docs/TASKS.md`](../projects/emo-desktop/docs/TASKS.md).
- The machine: [`projects/emo-os/README.md`](../projects/emo-os/README.md),
  [`docs/TASKS.md`](../projects/emo-os/docs/TASKS.md) (Step 17),
  [`docs/syscalls.md`](../projects/emo-os/docs/syscalls.md) (verbs
  10–35 and 55–60).
- The skin's ladder and the language boundary:
  [`noctalia-desktop.md`](noctalia-desktop.md), [`xv6.md`](xv6.md),
  [`rtos-assessment.md`](rtos-assessment.md),
  [`runtime-and-freestanding.md`](runtime-and-freestanding.md).
