# Emo

Emo is a general-purpose programming language, implemented in OCaml 5.

Repository: <https://github.com/emo-lang/emo>

## What is Emo?

Emo is **clean, explicit, and intuitive**. It draws on three decades of open-source programming languages — their strengths and their missteps — and is designed around three core principles:

- **Highly expressive syntax.** Code should read naturally and say what it means.
- **Principle of least surprise.** The language rules should match programmer intuition; things should work the way you expect them to.
- **Multiple compilation targets.** Emo compiles to native executables, to WebAssembly, to other languages such as TypeScript, to browser-ready bundles, to the BEAM virtual machine, and to bare metal (the `riscv64` target — see EmoOS). The interpreter runs a program directly, no artifact needed; [`docs/demo-targets.md`](docs/demo-targets.md) walks one project through all seven build targets.

## Install

One line, on macOS or Linux (WSL2 included) — the script detects the platform, downloads the latest release, verifies its SHA256, and installs to `~/.emo/bin`:

```console
curl -fsSL https://www.emo-lang.cn/cdn/install.sh | sh
```

Prebuilt archives work too. They cover Apple Silicon Macs and Linux on x86_64 and aarch64 — Intel Macs are not a shipping target. The binary carries the standard library inside it — nothing else to install (a C compiler joins the picture when you build with `emo build`, the default target). Grab the archive for your platform from the [download site](https://www.emo-lang.cn/cdn/dist/releases.json), then:

```console
$ unzip emo-<version>-macos-arm64.zip
$ ./emo-<version>-macos-arm64/bin/emo run hello.emo
```

Windows: WSL2 is the supported path — install inside WSL as you would on Linux; a native Windows build is pending the runtime port (see `docs/toolchain-distribution.md`).

Wherever you installed from, `emo doctor` checks the environment per target and names what is missing.

## Design in detail

Each area of the design has its own document:

- [`docs/intro/syntax.md`](docs/intro/syntax.md) — the language syntax: calls and their trailing blocks, `def` and bindings, control flow, values, and the type-definition constructs.
- [`docs/reserved_words.md`](docs/reserved_words.md) — the complete list of reserved words, reserved literals, and built-in names the compiler holds back.
- [`docs/intro/type-system.md`](docs/intro/type-system.md) — gradual typing, width-explicit numeric types, structural narrowing.
- [`docs/protocols.md`](docs/protocols.md) — the language protocol registry: `emo.to_string` and `emo.length`, contract enforcement at the definition, and what earns an entry.
- [`docs/intro/modules-and-visibility.md`](docs/intro/modules-and-visibility.md) — the directory tree as the module tree, `internal/` privacy, explicit dependencies.
- [`docs/intro/package-management.md`](docs/intro/package-management.md) — packages as module prefixes, exact versions resolved by MVS, publishing.
- [`docs/intro/concurrency.md`](docs/intro/concurrency.md) — processes and message passing: `do`, `<-`, `receive`.
- [`docs/intro/networking.md`](docs/intro/networking.md) — the direct-style async networking API over the `net` and `http` packages.
- [`docs/intro/native-builds.md`](docs/intro/native-builds.md) — `emo build`, the runtime inside the binary, and the `foreign def` C interop.
- [`docs/intro/testing.md`](docs/intro/testing.md) — `emo test`, the `test/` convention, and the `expect_*` assertions.
- [`docs/emo-testing-guide.md`](docs/emo-testing-guide.md) — the detailed testing guide: discovery, the four assertion builtins, reporting, and isolation.
- [`docs/intro/configuration.md`](docs/intro/configuration.md) — config as an Emo expression, evaluated in the restricted profile.

## EmoUI

[EmoUI](projects/emo-ui) is the component-based UI framework written in Emo: one declarative tree of components rendering on a terminal, a server-rendered page, a macOS/AppKit window, a GTK 4 window, and the browser DOM. Emo's syntax is shaped to serve it, and the principle is **no template language — the UI is plain Emo code**, the same philosophy as configuration. A component tree is nested calls over an explicit `Array[ui.Node]`:

```emo
def card(user User) ui.Node {
  return ui.row([
    ui.image(user.avatar(), ui.style().with_width(32.0)),
    ui.text(user.name(), ui.style())
  ], ui.style().with_gap(8.0))
}

def inbox(users Array[User]) ui.Node {
  const rows = ArrayBuilder.new()
  for var i = 0; i < users.length(); i = i + 1 {
    rows.push(card(users[i]))
  }
  return ui.column([
    ui.text("Inbox", ui.style()),
    ui.column(rows.to_array(), ui.style().with_padding(12.0))
  ], ui.style())
}
```

Everything here is ordinary syntax (see [`docs/intro/syntax.md`](docs/intro/syntax.md)): calls with explicit parentheses, named arguments, immutable data. Children are an argument, never a block: a trailing block is for callbacks and iteration, and where it produces a value it returns it. A child list that is not known until it is walked is built with the language's `ArrayBuilder` and handed over as `to_array()`. There is no implicit child collection, and components are ordinary functions — capitalized types are never invoked, and `.new` never appears in a tree.

The framework is settled design:

- **One tree type.** `ui.Node` is an interface; `Column`, `Row`, `Text`, `Button`, `TextInput`, `Image`, `Spacer` and `Scroll` are classes with typed props, reached through lowercase constructors (`ui.column`, `ui.text`, `ui.button`, …). A name means the same component on every backend.
- **Typed styles.** `ui.Style` is a typed value built by `ui.style()` and copied with `with_padding`, `with_gap`, `with_align`, `with_grow`, `with_width` and `with_height` — no stringly map and no default parameters. Its properties are the portable layout vocabulary each backend maps onto its platform's own layout engine.
- **Elm state.** An application is a model, a pure `update`, a pure `view`, and a backend: `ui.run(view, update, model, backend)`. `view` receives the loop's `Registry`, registers each typed message with `reg.on(msg)`, and gets back the `Int64` tag the backend delivers — the application's types never cross the backend seam.
- **One backend seam.** A backend implements `ui.Backend` — `mount(root, events)`, `patch(old, new)`, `run()` — and knows an event as one integer. The backend packages are `ui_tui`, `ui_ssr`, `ui_macos`, `ui_gtk` and `ui_browser`, plus the headless `ui.debug`.
- **One app, every backend.** `emo/ui_corpus` is a shared application the gates run unchanged on every backend; its debug and SSR entries produce identical bytes on the five hosted targets `c`, `ocaml`, `typescript`, `wasm`, and `beam`.

EmoUI is a project of its own under [`projects/emo-ui/`](projects/emo-ui), not a standard-library package, because its native backends carry per-platform shims and manifest fields (`.m`, `frameworks`, `pkg_config`) the standard library does not use. The package references live there: [`ui`](projects/emo-ui/docs/ui.md), [`debug`](projects/emo-ui/docs/debug.md), [`ui_tui`](projects/emo-ui/docs/ui_tui.md), [`ui_ssr`](projects/emo-ui/docs/ui_ssr.md), [`ui_macos`](projects/emo-ui/docs/ui_macos.md), [`ui_gtk`](projects/emo-ui/docs/ui_gtk.md), [`ui_browser`](projects/emo-ui/docs/ui_browser.md), [`ui_corpus`](projects/emo-ui/docs/ui_corpus.md).

## EmoOS

Emo's reach extends down to the operating system layer: the language is capable of writing a kernel, so that an Emo kernel plus an Emo shell — with EmoUI on top — forms a complete OS, EmoOS.

EmoOS is a project of its own under [`projects/emo-os/`](projects/emo-os) — its [README](projects/emo-os/README.md) holds the decided design and the [task tracker](projects/emo-os/docs/TASKS.md).

The `riscv64` compilation target is the bare-metal target. It assumes no OS, no libc, and no default runtime; it builds freestanding RISC-V images — the kernel development loop is compile, boot, debug, with no hardware required. QEMU is the target's default runner for that loop, not part of the target itself; the same image runs on real RISC-V hardware.

Writing a kernel shapes the language in four ways:

- **Layered core library.** `core` (integers, strings, tuples, control flow) has zero runtime dependencies and is the only layer available to kernel code; the standard library requires the runtime.
- **Explicit memory primitives.** Raw memory access (`peek`/`poke` and friends) is provided as explicitly named library functions — dangerous operations are visibly dangerous.
- **Pluggable runtime.** The GC, allocator, and scheduler are replaceable components on the bare-metal target, not injected defaults — a kernel may choose a minimal GC, arenas, or static allocation.
- **Single-language closure.** The kernel builds with the `riscv64` target while the shell and user programs build as ordinary native binaries — one language spanning both sides of the system.

## Implementation

The reference implementation of Emo is written in OCaml 5. Self-hosting is explicitly not a goal: Emo's reference implementation stays in OCaml.

Emo interoperates with C through `foreign def`: the `c` backend calls the symbol directly through the C ABI, while the `ocaml` backend marshals through a generated C wrapper.

## Documentation

Documentation lives under `docs/`. The Chinese translation of this README is [`docs/zh-CN/README.zh-CN.md`](docs/zh-CN/README.zh-CN.md).

- [`docs/c-backend.md`](docs/c-backend.md) — the default target: emitted C, the C runtime, and the C FFI.
- [`docs/ocaml-backend.md`](docs/ocaml-backend.md) — the emit-OCaml backend, and the OCaml toolchain requirement.
- [`docs/demo-targets.md`](docs/demo-targets.md) — running one scaffolded project on every target, including how `beam` and `wasm` artifacts are executed.
- [`docs/toolchain.md`](docs/toolchain.md) — building and installing the `emo` CLI: why dune is the one OCaml step, and the justfile automation.
- [`docs/toolchain-distribution.md`](docs/toolchain-distribution.md) — how the toolchain is distributed: the OCaml requirement, `emo doctor`, and deferring the `c` backend.
- [`docs/runtime-and-freestanding.md`](docs/runtime-and-freestanding.md) — what "runtime" and "freestanding" mean, and how they map to Emo's targets.
- [`docs/numeric-width.md`](docs/numeric-width.md) — width-explicit numeric types on every target.
- [`docs/var-escape.md`](docs/var-escape.md) — the `var`-escape rule.
- [`docs/stdlib.md`](docs/stdlib.md) — a tour of the standard library: every package, what it is for, and the surface it exposes.
- [`docs/stdlib/`](docs/stdlib/) — the standard-library API references (`file`, `os`, `bufio`, `net`, `http`, `json`, `yaml`, `xml`, `base64`, `csv`, `float`, `math`, `plot`, `slog`, `sync`, `sql`, `sqlite3`, `term`).
- [`docs/lsp.md`](docs/lsp.md) — the language server and the VS Code extension.
- [`docs/emo-ui.md`](docs/emo-ui.md) — the EmoUI assessment and the evidence: why one declarative tree works across TUI, server-rendered HTML, macOS, GTK 4, and the DOM, and what remains open.
- [`docs/emo-ui-composition.md`](docs/emo-ui-composition.md) — how an EmoUI tree gets written: why children are an array rather than a block form, and whether the array form earns a literal spelling.
- [`docs/industrial-software.md`](docs/industrial-software.md), [`docs/sql-database.md`](docs/sql-database.md), [`docs/rtos-assessment.md`](docs/rtos-assessment.md), [`docs/xv6.md`](docs/xv6.md), [`docs/visualization.md`](docs/visualization.md) — feasibility and market assessments.
- [`docs/TASKS.md`](docs/TASKS.md) — the implementation task checklist.

## License

Emo is released under the [MIT License](LICENSE).
