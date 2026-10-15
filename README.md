# Emo

Emo is a general-purpose programming language, implemented in OCaml 5.

Repository: <https://github.com/emo-lang/emo>

## What is Emo?

Emo is **clean, explicit, and intuitive**. It draws on three decades of open-source programming languages — their strengths and their missteps — and is designed around three core principles:

- **Highly expressive syntax.** Code should read naturally and say what it means.
- **Principle of least surprise.** The language rules should match programmer intuition; things should work the way you expect them to.
- **Multiple compilation targets.** Emo compiles to native executables, to WebAssembly, to other languages such as TypeScript, to the BEAM virtual machine, and to bare metal (the `riscv64` target — see EmoOS).

## Install

One line, on macOS or Linux (WSL2 included) — the script detects the platform, downloads the latest release, verifies its SHA256, and installs to `~/.emo/bin`:

```console
curl -fsSL https://raw.githubusercontent.com/emo-lang/emo/develop/scripts/install.sh | sh
```

Prebuilt archives work too. The binary carries the standard library inside it — nothing else to install (a C compiler joins the picture when you build with `emo build`, the default target). Grab the archive for your platform from [GitHub Releases](https://github.com/emo-lang/emo/releases), then:

```console
$ unzip emo-<version>-macos-arm64.zip
$ ./emo-<version>-macos-arm64/bin/emo run hello.emo
```

Homebrew, from the project's own tap:

```console
$ brew install emo-lang/tap/emo
```

opam builds from source and additionally brings the `ocaml` compilation target:

```console
$ opam install emo
```

Windows: WSL2 is the supported path — install inside WSL as you would on Linux; a native Windows build is pending the runtime port (see `docs/toolchain-distribution.md`).

Wherever you installed from, `emo doctor` checks the environment per target and names what is missing.

## Design in detail

Each area of the design has its own document:

- [`docs/intro/syntax.md`](docs/intro/syntax.md) — the language syntax: calls and their trailing blocks, `def` and bindings, control flow, values, and the type-definition constructs.
- [`docs/intro/type-system.md`](docs/intro/type-system.md) — gradual typing, width-explicit numeric types, structural narrowing.
- [`docs/intro/modules-and-visibility.md`](docs/intro/modules-and-visibility.md) — the directory tree as the module tree, `internal/` privacy, explicit dependencies.
- [`docs/intro/package-management.md`](docs/intro/package-management.md) — packages as module prefixes, exact versions resolved by MVS, publishing.
- [`docs/intro/concurrency.md`](docs/intro/concurrency.md) — processes and message passing: `do`, `<-`, `receive`.
- [`docs/intro/networking.md`](docs/intro/networking.md) — the direct-style async networking API over the `net` and `http` packages.
- [`docs/intro/native-builds.md`](docs/intro/native-builds.md) — `emo build`, the runtime inside the binary, and the `foreign def` C interop.
- [`docs/intro/testing.md`](docs/intro/testing.md) — `emo test`, the `test/` convention, and the `expect_*` assertions.
- [`docs/intro/configuration.md`](docs/intro/configuration.md) — config as an Emo expression, evaluated in the restricted profile.

## EmoUI

[EmoUI](projects/emo-ui) is the component-based UI framework written in Emo: UIs composed as trees of components that render from reactive state. Emo's syntax is shaped to serve it, and the principle is **no template language — the UI is plain Emo code**, the same philosophy as configuration. A component tree is nested calls with blocks (illustrative syntax):

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user User) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}
```

Everything here is ordinary syntax (see [`docs/intro/syntax.md`](docs/intro/syntax.md)): calls with explicit parentheses, single-form blocks, named arguments. A component tree consists of plain function calls — components are defined as functions (`def card(user User) Component { ... }`), or as classes exposed through a same-named lowercase factory function (`def card(user User) Component { return Card.new(user) }`). From the caller's side, every component is a lowercase function; capitalized types are never invoked, and `.new` never appears in a tree. One rule specific to this domain: structured literals are immutable, so props and component trees are plain immutable data.

Reactivity is explicit rather than implicit:

- Reactivity primitives live in the standard library with explicit, predictable semantics — no hidden dependency graphs.
- Compiler awareness optimizes them: statically decidable updates compile into targeted refreshes instead of runtime diffing.

These decisions interlock with the core design: props are checked by the built-in type checker (gradual typing), UI events are process messages (a UI process plus its mailbox yields the Elm architecture on top of Emo's concurrency), and platform backends only consume the component tree and its reactive updates — the language layer knows no platform details.

## EmoOS

Emo's reach extends down to the operating system layer: the language is capable of writing a kernel, so that an Emo kernel plus an Emo shell — with EmoUI on top — forms a complete OS, EmoOS.

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
- [`docs/toolchain.md`](docs/toolchain.md) — building and installing the `emo` CLI: why dune is the one OCaml step, and the justfile automation.
- [`docs/toolchain-distribution.md`](docs/toolchain-distribution.md) — how the toolchain is distributed: the OCaml requirement, `emo doctor`, and deferring the `c` backend.
- [`docs/runtime-and-freestanding.md`](docs/runtime-and-freestanding.md) — what "runtime" and "freestanding" mean, and how they map to Emo's targets.
- [`docs/numeric-width.md`](docs/numeric-width.md) — width-explicit numeric types on every target.
- [`docs/var-escape.md`](docs/var-escape.md) — the `var`-escape rule.
- [`docs/stdlib.md`](docs/stdlib.md) — a tour of the standard library: every package, what it is for, and the surface it exposes.
- [`docs/stdlib/`](docs/stdlib/) — the standard-library API references (`file`, `os`, `bufio`, `net`, `http`, `json`, `yaml`, `xml`, `base64`, `csv`, `float`, `math`, `plot`, `slog`, `sync`, `sql`, `sqlite3`).
- [`docs/lsp.md`](docs/lsp.md) — the language server and the VS Code extension.
- [`docs/emo-ui.md`](docs/emo-ui.md) — the EmoUI assessment and design direction: one declarative tree for Web, TUI, macOS, and GTK 4.
- [`docs/emo-ui-composition.md`](docs/emo-ui-composition.md) — how an EmoUI tree gets written: why components return children instead of emitting them, and the one spelling question left open.
- [`docs/industrial-software.md`](docs/industrial-software.md), [`docs/sql-database.md`](docs/sql-database.md), [`docs/rtos-assessment.md`](docs/rtos-assessment.md), [`docs/xv6.md`](docs/xv6.md), [`docs/visualization.md`](docs/visualization.md) — feasibility and market assessments.
- [`docs/TASKS.md`](docs/TASKS.md) — the implementation task checklist.

## License

Emo is released under the [MIT License](LICENSE).
