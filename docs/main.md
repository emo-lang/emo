## What Emo is

Emo is a general-purpose programming language with three design axes:
**Go's simplicity, C's speed, Ruby's elegance**.

### Go's simplicity

Emo borrows Go's *mechanisms* and keeps its own *surface*. The
mechanics that make a language small and predictable are here:

- **One way to declare things.** `def` for functions and methods,
  `class` for types, `interface` for contracts, `enum` for closed sets,
  and `emo` for stateless function groups. Every call has parentheses.
- **Structural interfaces, no inheritance.** A class satisfies an
  interface by having the methods; there is no `implements` clause, no
  superclass, and no method promotion. Reuse comes from composition and
  duck-typed functions.
- **One module system.** The directory tree is the module tree; a
  package is a module prefix; `internal/` is the one privacy rule.
  There are no import lists, no export lists, and no visibility
  keywords.
- **No generics machinery.** Parameterized types (`Array[T]`,
  `Map[K, V]`, `Box[T]`) are type-declaration vocabulary the checker
  knows; applications rely on inference and rarely spell a type.
- **A small toolchain.** One `emo` binary carries the standard library
  and the compilers. `emo build` needs only the system C compiler;
  `emo new`, `emo run`, `emo check`, `emo test`, `emo doctor`, `emo
  docs`, and `emo man` complete the command set. There is no install
  step for libraries.

What Emo does not take from Go is the look: the syntax, the keywords,
and the tooling names are its own. Mechanisms may be borrowed from any
language; a recognizable single-source fingerprint is not.

### C's speed

The default build target emits C and compiles it with the system `cc`,
so a program is a standalone native binary with no OCaml runtime and no
interpreter beside it:

- **Native code by default.** `emo build` targets `c`; `ocaml`,
  `typescript`, `wasm`, `beam`, `browser`, and a freestanding
  `riscv64` image are the other targets.
- **Guaranteed tail calls.** Loops and tail recursion keep the native
  stack flat; the trampoline is part of the target, not a hint.
- **A direct C ABI.** `foreign def` calls a C symbol through the C ABI
  on `c`, with no wrapper generator; the `ocaml` target marshals
  through a generated wrapper.
- **Bare metal.** The `riscv64` target assumes no OS, no libc, and no
  default runtime — the language reaches the kernel, which is what
  EmoOS is built on.

The numbers live in [`benchmarks/results.md`](../benchmarks/results.md);
the recorded run (2026-11-09) has `fib(30)` at 26 ms on the `c` target
against 980 ms on the interpreter, and a 10-million-iteration tail loop
at 37 ms against 6.2 s. The same sources still build for WebAssembly,
TypeScript, and the BEAM.

### Ruby's elegance

Expressiveness is a design axis, not decoration:

- **Strings interpolate any expression** (`"hello, ${name}"`), and calls
  take a trailing block as their final argument — the single notation
  behind callbacks, iteration, and UI trees.
- **Predicates read as predicates.** A method whose name ends in `?`
  answers a `Bool`: `user.is_older?()`, `ticket.available?()`.
- **Value types are values.** Instances are immutable; a method that
  "changes" one returns a new instance, and equality is structural.
- **`case` is a pattern language.** Enum members, literals, tuples, and
  `_` match by shape, with `when` guards; the sugar forms (`:chain`,
  `:foreach`, `:when`, `:raise`) shorten the shapes ordinary code
  already writes.
- **Configuration is Emo, and so is the UI.** A config file is an Emo
  expression; an EmoUI tree is plain Emo calls. There is no template
  language, no stringly map, and no separate DSL to learn.

The elegance is in the shape of the code, not in borrowed syntax: the
surface is Emo's own, and the composition note
([`emo-ui-composition.md`](emo-ui-composition.md)) records where the
Ruby-style tree idea stopped and Emo's own array children began.

## How the documentation is organized

The documentation is one tree under `docs/`, mirrored in Chinese under
`docs/zh-CN/`. Every page is plain Markdown; two sets are also embedded
in the compiler binary.

| Where | What lives there |
| --- | --- |
| [`README.md`](../README.md) | the project overview, install, and the complete documentation index |
| `docs/main.md` | this map and the reading paths |
| [`docs/intro/`](intro/) | the language: syntax, types, modules, packages, concurrency, networking, configuration, testing, native builds, macros, and the tour; `emo docs` renders these pages |
| [`docs/stdlib.md`](stdlib.md), [`docs/stdlib/`](stdlib/) | the standard library: the tour of every package, then one API reference per package; `emo man` renders these pages |
| `docs/*-guide.md` | task-oriented guides: [`httpd-guide`](httpd-guide.md), [`emosh-guide`](emosh-guide.md), [`plot-guide`](plot-guide.md), [`playwright-guide`](playwright-guide.md), [`macro-guide`](macro-guide.md), [`emo-testing-guide`](emo-testing-guide.md) |
| [`docs/emo-ui/intro.md`](emo-ui/intro.md) | the EmoUI getting-started guide |
| [`docs/c-backend.md`](c-backend.md), [`ocaml-backend.md`](ocaml-backend.md), [`demo-targets.md`](demo-targets.md), [`runtime-and-freestanding.md`](runtime-and-freestanding.md), [`toolchain.md`](toolchain.md), [`toolchain-distribution.md`](toolchain-distribution.md), [`lsp.md`](lsp.md), [`gc-heap.md`](gc-heap.md) | targets, runtime, toolchain, editor support, and the GC heap |
| [`docs/reserved_words.md`](reserved_words.md), [`numeric-width.md`](numeric-width.md), [`var-escape.md`](var-escape.md), [`raw-memory.md`](raw-memory.md), [`atomics.md`](atomics.md) | the language's reference footnotes |
| [`projects/`](../projects/) | project documentation beside the code: [EmoUI](../projects/emo-ui/docs/README.md), [EmoOS](../projects/emo-os/README.md), [Emo desktop](../projects/emo-desktop/README.md), [EmoDB](../projects/emo-db/README.md), [Emo shell](../projects/emo-shell/), [the playground](../projects/emo-playground/README.md) |
| [`docs/emo-ui.md`](emo-ui.md), [`emo-db.md`](emo-db.md), [`unkernel.md`](unkernel.md), [`industrial-software.md`](industrial-software.md), [`sql-database.md`](sql-database.md), [`rtos-assessment.md`](rtos-assessment.md), [`xv6.md`](xv6.md), [`visualization.md`](visualization.md), [`math-netlib.md`](math-netlib.md), [`esp32.md`](esp32.md), [`lua-backend.md`](lua-backend.md), [`zig-backend.md`](zig-backend.md), [`noctalia-desktop.md`](noctalia-desktop.md), [`noctalia-v5.md`](noctalia-v5.md) | design records and feasibility assessments — the reasoning behind the decisions |
| [`docs/TASKS.md`](TASKS.md), [`plan/`](../plan/README.md), [`CHECK.md`](../CHECK.md) | the implementation trackers and the settled design decisions |
| [`docs/zh-CN/`](zh-CN/README.md) | the Chinese mirrors, same structure as `docs/`; a handful of internal pages stay English-only |

Two channels read the same pages:

- **In the terminal.** `emo docs` lists the introduction pages and
  `emo docs <page>` prints one; `emo man` does the same for the standard
  library (`emo man`, `emo man json`, `emo man stdlib`). The binary
  carries the pages, so an installed compiler answers with nothing
  beside it.
- **On the web.** <https://docs.emo-lang.cn/> serves the guides built
  from this tree: the language tour at
  <https://docs.emo-lang.cn/guides/tour/> and the EmoUI guide at
  <https://docs.emo-lang.cn/guides/emo-ui/intro>, with `/zh/` prefixes
  for the Chinese pages.

## Start with the language tour

[`docs/intro/tour.md`](intro/tour.md) is the shortest path from "I have
heard of Emo" to "I can write a program". It is a program you can read
and run: every `run` block is compiled to Wasm and its output compared
byte for byte by `just tour`, so the prose cannot drift from the
language.

It opens with a ten-minute quick start, then ten short chapters:

- values, bindings, and strings;
- control flow;
- functions, arrow blocks, and tuples;
- classes and structural interfaces;
- enums and `case`;
- collections (`Array`, `ArrayBuilder`, `Map`);
- errors as `(R.ok, ...)` / `(R.error, ...)` values;
- modules, packages, and the standard library's `json`;
- processes and message passing;
- a small business slice that combines them.

Read it three ways: in the editor at
[`docs/intro/tour.md`](intro/tour.md), in the terminal with `emo docs
tour`, or on the web at
<https://docs.emo-lang.cn/guides/tour/> (Chinese:
<https://docs.emo-lang.cn/zh/guides/tour/>).

## Then build a UI with EmoUI

[`docs/emo-ui/intro.md`](emo-ui/intro.md) is the EmoUI getting-started
guide. It builds two applications from scratch, complete code included:

1. **Hello, World** — an empty window with one line of text, showing
   the smallest application: a `view`, an `update`, and `ui.run`.
2. **Counter** — a number and two buttons, showing the loop's event
   tags, `update` returning a new model, and a row of grown buttons.

Both run on a macOS/AppKit window in the guide; the same `view` and
`update` move to a GTK 4 window, a terminal, a server-rendered page, or
the browser by changing the backend — that seam is explained in the
guide and in [`projects/emo-ui/README.md`](../projects/emo-ui/README.md).
The complete worked application, with seven backend entries sharing one
app module, is
[`projects/emo-ui/apps/calculator/`](../projects/emo-ui/apps/calculator/).

Read it at [`docs/emo-ui/intro.md`](emo-ui/intro.md) or on the web at
<https://docs.emo-lang.cn/guides/emo-ui/intro> (Chinese:
<https://docs.emo-lang.cn/zh/guides/emo-ui/intro>).

## Reading paths

| If you want to… | Read |
| --- | --- |
| get started with the language | [`docs/intro/tour.md`](intro/tour.md), then [`docs/intro/syntax.md`](intro/syntax.md) |
| build a user interface | [`docs/emo-ui/intro.md`](emo-ui/intro.md), then the calculator, then [`projects/emo-ui/docs/ui.md`](../projects/emo-ui/docs/ui.md) |
| use the standard library | [`docs/stdlib.md`](stdlib.md) and `emo man <package>` |
| work on targets and systems | [`docs/c-backend.md`](c-backend.md), [`docs/runtime-and-freestanding.md`](runtime-and-freestanding.md), [`docs/demo-targets.md`](demo-targets.md), and the EmoOS project |
| understand a design decision | the records under `docs/` — [`emo-ui.md`](emo-ui.md), [`emo-db.md`](emo-db.md), [`unkernel.md`](unkernel.md) |
| follow the implementation | [`docs/TASKS.md`](TASKS.md) and the step plans under [`plan/`](../plan/README.md) |
