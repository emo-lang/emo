# Step 48 — EmoUI

**Milestone:** M15 — EmoUI · **Prereq:** step 23 (the `c` target and
`foreign def`) and step 25 (target independence); the cross-module type
names (2026-10-14) and the C→Emo callback contract (2026-10-11) are
already in `develop`. · **Related:** `docs/emo-ui.md` (the assessment
and design direction), `docs/emo-ui-check.md` (the gate checklist),
`spike/components` (the two-platform component spike),
`spike/emo-ui-probe` (the language probes) · **Status:** planned — the
decisions are settled; nothing is implemented.

## Why this step exists

EmoUI is the declarative UI framework the language's syntax was shaped
to serve: UIs composed as trees of components that render from explicit
state, with no template language — the UI is plain Emo. The
2026-10-10 and 2026-10-14 decisions existed to unlock it (cross-module
types, module-qualified names), and the two GUI spikes proved the
native toolkits reachable through `foreign def`. What was missing is a
design that holds the same composition syntax across the four very
different platform runtimes — a retained toolkit loop, a browser event
loop, a blocking terminal read, and a server-side string renderer — and
an honest account of what the language does and does not give the tree
today.

`docs/emo-ui.md` is that design; this step schedules it. The EmoUI
packages live in their own repository (`github.com/emo-lang/emo-ui`,
linked from the README); the compiler-side gates the design identified
— the native packaging mechanism, the browser runtime path, and
terminal raw mode — land in this repository.

## Goal

One shared Emo application module (components, `update`, `view`,
written against the portable `ui` core) renders on a terminal, a
server-rendered page, a macOS/AppKit window, a GTK 4 window, and — once
the browser path lands — a browser DOM, each behind a thin per-platform
entry module. The composition syntax is identical everywhere; each
platform may ship its own component library; the portable core and the
pure-Emo backends answer byte-for-byte on all five hosted targets.

## Decisions settled here (2026-10-14)

Recorded in `docs/emo-ui.md` and carried by this step:

1. **EmoUI is a third-party project**, not a standard-library package.
   A later split that moves the portable core and the pure-Emo backends
   (TUI, SSR) into the stdlib is possible once they are stable; it is
   not v1.
2. **The tree type is a multi-module `ui.Node`** — an interface spine
   plus concrete classes with typed props — not a single stringly-tagged
   class, and not one class per platform with no portable core.
3. **Children are an explicit `Array[Node]`.** Trailing blocks are for
   callbacks and iteration and must `return` their value; there is no
   implicit child collection. The README's illustrative tree is revised
   to this spelling.
4. **Layout is a portable vocabulary mapped to each platform's native
   layout** (CSS flexbox, GTK boxes, AppKit stack views, a TUI cell
   grid), not a shared Emo layout engine. The TUI keeps a small Emo box
   model because it has no native engine.
5. **Style is a typed value with a factory and `with_*` copies** — no
   stringly map, no default parameters (which Emo refuses: E4009).
6. **State is Elm** (a model, `update`, `view`) over the language's
   explicit primitives (`Box`/`List`/`Map`); events are typed messages
   registered Emo-side and exposed to the backend as `Int64` tags, so
   `update` stays typed while the FFI only ever sees an integer.
7. **The backend is an Emo interface** (`mount`/`patch`/`run`); the
   spikes' nine-verb `ui_*` contract is the native implementation
   detail.
8. **Platform libraries share convergent names** for equivalent
   components; platform-specific components carry the platform package's
   name at the call site, so portability is visible rather than implied.
9. **Sequencing: TUI and SSR first, native toolkits next, the browser
   DOM last.**
10. **No new syntax.** The one language ask worth weighing later is a
    checked block/function type (`Block` is `Unknown` today); it is a
    convenience, not a gate.
11. **The probes are the evidence** (`spike/emo-ui-probe`): a `Block`
    parameter is `Unknown`; a Void block yields `void` (so children are
    lost); recursive node classes and self-naming interfaces now check;
    a bare def — local or module-qualified — is a value satisfying
    `Block`; default parameters are refused (E4009).

## Scope

### In

- **The portable `ui` core:** the node spine and the portable
  primitives (`column`, `row`, `text`, `button`, `text_input`, `image`,
  `spacer`, `scroll`), the typed `Style` with its factory and `with_*`
  copies, the layout vocabulary (`Align`/`Grow`, `padding`, `gap`,
  width/height), the `Backend` interface, and the Elm loop with the
  event-tag registry.
- **The pure-Emo backends:** TUI (cell-grid layout plus ANSI painting)
  and SSR (node tree to HTML/CSS), both byte-identical on all five
  hosted targets.
- **The native backends:** the nine-verb shim over AppKit (`c` target,
  Objective-C) and GTK 4 (`c` target, C plus `pkg-config`).
- **The compiler-side gates:** the native packaging mechanism (the
  manifest's per-package native fields — settled direction, `CHECK.md`),
  terminal raw-mode/key input, and the browser runtime path (a
  browser-safe TypeScript runtime split or a `dom_*` family in the
  runtime, plus the bundling step).
- **The convergence corpus:** one sample application run on every
  backend, so a `row` means the same thing everywhere.

### Out

- A pixel-identical layout engine. Layout is the platform's; the
  portable vocabulary is the intersection the platforms share.
- Animation, a vector-canvas widget, and 3D. The canvas contract is a
  separate EmoUI direction (`docs/visualization.md`, decision 9).
- An application lifecycle beyond the Elm loop: packaging, app-store
  distribution, and window management beyond the one window the spikes
  opened.
- Accessibility beyond what the native widgets supply on their own.
- A UI process with a mailbox integrated with a toolkit loop. The
  synchronous Elm loop is v1; events as real process messages are a
  later integration (`docs/emo-ui.md`, open question 3).
- **Reclaiming the `c` target's value families.** A render's arena
  bytes and its identity leak are real and measured
  (`spike/arena-scope`), and the cheap fix — a region — was ruled out
  by that spike. Reclamation is its own milestone (step 49,
  `plan/step-49-value-reclamation.md`) and **not a prerequisite for
  this step**: the native backends ship at demo scale with the limit
  documented (`CHECK.md`).

## Tasks

- [ ] **T48.1** — The portable `ui` core package: the `Node` spine
      (interface plus `Column`/`Row`/`Text`/`Button`/`TextInput`/
      `Image`/`Spacer`/`Scroll`), the typed `Style` with `style()` and
      the `with_*` copies, the layout vocabulary, and the `Backend`
      interface. Pure Emo, declaring all five hosted targets — which
      makes the two codegen defects the spelling spike found part of
      this task, both fixed 2026-10-15: the `c` class metadata tables
      moved out of the `<cname>__<member>` namespace a method's symbol
      occupies (they are `vt_<cname>_fields` / `vt_<cname>_methods`
      now, joining `vt_<cname>` and `iface_<name>`), and the `ocaml`
      native `String` `+` (a `= Emo_check.String` branch emitting `(^)`
      in `emit_native_expr`). The two isolation fixtures stay in
      `spike/emo-ui-spelling/codegen/` as the regression.
- [ ] **T48.2** — The Elm loop: `App` (model/`update`/`view`), the
      `ui.on(msg)` tag registry and `ui.dispatch(tag)`, and
      `ui.run(view, update, model, backend)`. Tests for the tag
      round-trip and a retained `patch` versus a full rebuild.
- [ ] **T48.3** — The headless `debug` backend: renders the tree to a
      stable text form, the byte-identical golden harness the core and
      the other backends share.
- [ ] **T48.4** — `ui-tui`: the cell-grid layout (the small Emo box
      model) and ANSI painting; a scripted-input golden.
- [ ] **T48.5** — Terminal input: raw mode and key events — a `termios`
      `foreign def` (c/ocaml) or a terminal runtime implementation;
      line mode first, raw mode behind it.
- [ ] **T48.6** — `ui-ssr`: the node tree to HTML plus a stylesheet,
      byte-identical on all five hosted targets; forms and links as the
      interaction model.
- [ ] **T48.7** — The native packaging mechanism: per-package manifest
      fields (`pkg_config` and/or compile/link flags, plus whatever
      collects `.m`); the app-level build-script path is not the
      supported one. The gate for T48.8 and T48.9.
- [ ] **T48.8** — `ui-macos`: the nine-verb AppKit shim over the
      callback contract; the convergence corpus runs. Demo scale — the
      `c` target's long-running memory is step 49 (`CHECK.md`).
- [ ] **T48.9** — `ui-gtk`: the GTK 4 shim, built with `pkg-config`;
      the convergence corpus runs. Demo scale, as T48.8.
- [ ] **T48.10** — The browser runtime path: a browser-safe split of
      the TypeScript runtime (or a `dom_*` family in the runtime) plus the
      output-bundling step; the gate for T48.11.
- [ ] **T48.11** — `ui-browser`: the DOM backend over the browser path;
      the convergence corpus runs.
- [ ] **T48.12** — The convergence corpus: one sample application
      (state, a form, a list, an event) on every backend, with the same
      portable app module throughout.
- [ ] **T48.13** — Docs: the README's EmoUI section revised to the
      array-children spelling and the settled decisions; `docs/emo-ui.md`
      settled into decided design where README-eligible; the EmoUI
      package references in its own repository.

## Acceptance

- The shared portable app module is byte-identical on the debug and
  SSR backends across all five hosted targets — `c` and `ocaml`
  included, which the two T48.1 codegen fixes are what unblocked — and
  drives the TUI, macOS, GTK 4, and browser backends through their
  per-platform entries.
- The composition syntax is the same on every backend — a component
  tree is nested calls with `Array[Node]` children, and the only
  per-platform code is the backend package and a thin entry module.
- The native packaging mechanism is settled in direction — the manifest
  grows per-package native fields, not app-level build scripts
  (`CHECK.md`) — so `require`-ing a native UI backend is a supported
  story, not a hand-copied shim build.
- The native backends are **demo scale, and say so**: the `c` target
  does not yet reclaim the value families a render allocates, so the
  limit is documented rather than papered over and reclamation is
  scheduled as its own milestone (step 49).
- No language change was required.

## Open design items

Listed as open questions in `docs/emo-ui.md`:

1. **The native packaging mechanism** — direction settled to
   per-package manifest fields (2026-10-14, `CHECK.md`); the field
   surface is T48.7's own work. Gates T48.7–T48.9.
2. **Reconciliation** — when the retained backends get a keyed diff
   instead of a full rebuild, and whether the compiler's targeted
   refresh lands with it.
3. **The two-event-loop integration** — how a UI process and a toolkit
   loop coexist, and whether events become real process messages in v1
   or later.
4. **A checked block/function type** — whether the component API earns
   it after a first package shows the friction.
5. **The browser path boundary** — settled 2026-10-15 to a browser-safe
   subset of the existing TypeScript runtime plus a `dom_*` family,
   rather than a browser-specific runtime variant (`CHECK.md`, step 50).
   Where the bundling step lives in the toolchain stays T48.10's own
   work, the shape T48.7 already has for its field surface. Gates
   T48.10–T48.11, now unblocked.
