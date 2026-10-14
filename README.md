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

## Syntax

Emo's syntax favors explicitness: everything is visibly what it is — a call looks like a call, a return is written out, a block has one shape.

The full reference is [`SYNTAX.md`](SYNTAX.md): calls and their trailing blocks, `def` and bindings, postfix type declarations, `if` and the one-line `if` expression, `case`, `for` and `while`, tuples, maps, naming, strings, output — and the class, interface, function group, enum, exception, and mutability constructs.

## Type System

Emo is gradually typed: **types are dynamic at runtime, but statically checked at compile time**.

- Runtime semantics are dynamically typed — every value carries a type tag. This aligns natively with BEAM and keeps everyday code free of type ceremony.
- **Integer types are width-explicit: the default integer type is `Int64`.** It is 64-bit two's complement with wrap-around — arithmetic is performed modulo 2⁶⁴, so overflow behaves identically whether a program runs natively, on Wasm, on the BEAM, or on bare metal. Integer literals without type declarations are `Int64`; there is no width-less `Int` spelling (see `docs/numeric-width.md`).
- **Float types are width-explicit: the default float type is `Float64`.** It is IEEE 754 binary64 on every target, so floating-point behavior is identical everywhere. Float literals without type declarations are `Float64`; there is no width-less `Float` spelling.
- **Numeric literals** are decimal, hexadecimal (`0xFF`), binary (`0b1010_1010`), or octal (`0o755`), with `_` as a digit separator (`1_000_000`). There is no leading-zero octal and no width suffix — bare literals stay `Int64`/`Float64`.
- The compiler has a built-in type-checking pass. Type declarations are optional across the language — except on function signatures, where parameter types are explicit and an omitted return type declares Void — and code without them is still inferred and checked, reporting only errors that are certain; code with them is checked strictly.
- Typing is structural, and an `is` test narrows — after `if user.is(Admin)`, `user` is an `Admin` inside the branch, and never past it — matching duck-typing intuition.
- There is no generics machinery: no generic definition syntax and no type-constraint system. Parameterized types exist only as type-declaration vocabulary (e.g. `Array[User]`, `Map[String, Int64]`, `Box[Int64]`) serving the checker and library signatures; application code relies on inference and rarely sees any type spelling at all. A parameter that receives a block is declared `Block`.
- The container types also take a bare spelling — `List`, `Box`, `Map` — meaning "any elements": a `Map` parameter accepts a `Map[String, Int64]` as readily as a `Map[Int64, User]`, and values read back from it are checked progressively.
- Strictness defaults high and can be relaxed explicitly.
- Type information feeds back into performance: modules with sufficiently complete type knowledge can be specialized (unboxed representations, direct dispatch) on the `ocaml` and `c` backends.

## Modules and Visibility

Emo's module system is fully structural: no `import`, no `export`, no visibility keywords, and no naming conventions carrying visibility. **The directory tree is the module tree:**

```
shop/
  order.emo           # module shop.order
  pricing.emo         # module shop.pricing
  internal/
    discounts.emo     # module shop.internal.discounts — subtree-private
  checkout.emo        # module shop.checkout
```

- **The path is the module.** A file automatically becomes the module at its path — no registration, no declaration.
- **References are qualified paths.** Nothing is imported; paths are used directly, like URLs. When a path is long, an ordinary `const` binding aliases it — no new syntax, since an import statement was only ever an alias assignment:

  ```emo
  const order = shop.order

  def checkout(cart Cart) Decimal {
    const total = order.total(cart)
    return total
  }
  ```

- **Visibility is structural.** Definitions inside functions and blocks are private by scoping; module-level definitions are public (addressable by their qualified paths); and an `internal/` directory is subtree-private, enforced by the compiler — everything under `shop/internal/` is usable within `shop` and its descendants, and a compile error anywhere else.
- **Type names are module-qualified paths, exactly like values.** A type reference is a path: `ui.VNode` names `ui.emo`'s `VNode` from another module, a bare `Order` names the current module's own type, and package-relative forms work as they do for values (`internal.svg.Renderer` inside a package). `is()` narrows across the boundary, and construction follows the same rule — `sync.WaitGroup.new(2)`, `ui.Point.new(...)` — the declaring module loading on first use. Two modules may therefore declare the same type name: they are two distinct types, each addressed by its module. The privacy rule reaches types as it reaches values: a type declared under `internal/` resolves only within its subtree.
- **The dependency graph is explicit.** Path references are the dependency declarations, giving automatic module discovery, incremental compilation, and compile-time cycle detection.

## Package Management

Packages slot directly into the module system: a package name becomes a top-level module path prefix. There is no `install` step for libraries — dependency resolution is a side effect of building. Using a package is `require`:

```emo
require "acme/json_tools"

def parse_config(text String) json_tools.Json {
  return json_tools.parse(text)
}
```

- **`require` is a file-level statement that brings the package's short name into scope.** It needs no counterpart on the package side — a package's public surface is simply its module tree. Fully qualified paths are always available.
- **A package's module tree is mounted under its short name.** The package root's `<short>.emo` is the module `<short>` a `require` binds; every other file or directory is a child of it — `plot/internal/svg.emo` is `plot.internal.svg`, `plot/mark.emo` is `plot.mark` — so two packages' `internal` and `mark` never collide. Inside the package, references are written against the package root (`internal.scale` in `plot.emo` means `plot.internal.scale`), so a package compiles the same whether built alone or mounted under its prefix.
- **The standard library needs no manifest entry; a third-party package does.** The official standard library owns the top-level short names (`json.decode()`, `http.get(url)`) and ships with the compiler, so `require "json"` resolves implicitly — including the standard-library packages that dependency pulls in. A scoped package (`acme/json_tools`) must be pinned in `deps`: requiring one that is missing is a compile error — strictness comes first, and the manifest changes only by explicit action.

- **Central registry, with configurable endpoints.** Packages are addressed by `name@version` through a central registry, backed by a global content-addressed cache shared across projects — no per-project dependency copies. The registry endpoint is read from the `EMO_REGISTRY` environment variable — set it globally or per project — serving private and on-premises distribution; unset, the standard library's bundled registry ships with the compiler and serves by default.
- **Scoped package names.** Third-party packages are named under a scope prefix, so ownership is explicit and name squatting has no ground to stand on; the scope prefix becomes the module path prefix. The official standard library alone owns the top-level short names (`json.decode()`, `http.get(url)`).
- **The manifest is an Emo config file**, written in the restricted profile (terminating, hermetic, side-effect free). **Dependencies are exact versions** — the version a package is developed and tested against — and **targets declare which compilation targets the package supports**. A package that binds native code also names the system libraries it links in the optional `link` field:

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["ocaml", "wasm"]
    link = ["sqlite3"]

    deps {
      json = "2.3.1"
      http = "1.4.2"
    }
  }
  ```

- **A package may carry native code.** `.c` and `.h` files in a package's tree are part of the package — collected, checksummed, and published beside its `.emo` modules. The `c` target compiles a dependency's C sources into the program and links the libraries its `link` field names, so consuming a native-binding package like `sqlite3` is just `require` — no `--cclib`, no manual shims. The `link` field takes bare library names only. Only the `c` target honors a package's native inputs; every other target refuses such a dependency at build time, and the manifest's `targets` refuses it at resolution.

- **Versions are semantic (major.minor.patch), resolved by Minimal Version Selection (MVS).** When different packages require different versions of the same dependency, the smallest version satisfying every requirement wins — for exact requirements, the highest one named. Upgrades are always explicit actions. The lockfile (`package.lock`) records the resolution with checksums and belongs in version control; `emo deps resolve` writes it, `emo deps update` regenerates it after a pin changes, `emo deps list` reads it — building never rewrites it silently. A checksum is the SHA-256 over the package's collected sources (`.emo`, plus any `.c`/`.h`), sorted by path and fed as `path \0 content \0` — the same digest the registry recomputes on publish. (Checksums were MD5 before the registry protocol froze; a lockfile written by an older compiler should simply be deleted and re-resolved.)
- **Target compatibility is checked at resolution time.** A dependency that does not support the target being built fails resolution with a clear error, not midway through compilation.
- **Publishing is `emo publish`, run from the package root.** The command validates the manifest (an `owner/name` name, a well-formed version), packs every collected source — `.emo` and any `.c`/`.h`, subdirectories included — plus an optional root `README.md` into a deterministic `.emoji` archive (gzip tar, sorted paths, zeroed metadata: the same input always packs to the same bytes), and POSTs it to the registry. The endpoint comes from `--registry`, `EMO_REGISTRY`, or the most recent `emo emoji login`; the API token from `--token`, `EMO_TOKEN`, or the stored login for that registry — a stored token is only ever sent to the registry it was minted for. `--dry-run` validates and packs locally, printing the archive name, size, checksum, and file list without uploading. Versions are immutable: publishing an existing version is rejected — bump `version` in the manifest.
- **The shared-package lifecycle is `emo emoji`** — the group named after the archive format itself. `emo emoji new acme/string_tools` scaffolds a publishable package (an `owner/name` manifest, the public module named after the package, a README); `emo emoji build` compiles the package's entry module under every declared target — the pre-publish gate; `emo emoji login` verifies your account against a registry and stores a push/yank/read API token in `~/.config/emo/credentials` (0600, one block per registry, the expiry recorded alongside it — `--expires-in-days` bounds the token's life), so publishing afterwards needs neither flags nor environment — with a terminal it asks for the email and password (the password read with the echo off), otherwise it reads them as two lines from stdin; when a stored token has expired, the registry refuses it with a dedicated code and `emo publish` points back to `emo emoji login`; `emo emoji publish` is the same upload as `emo publish`.

## Concurrency

Emo ships with a native concurrency model built around **processes and message passing**, in the spirit of the actor model. This choice is deliberate: it maps natively onto BEAM processes, while the `ocaml` backend implements it with a scheduler built on OCaml 5 effects — the same foundation proven by runtimes such as Eio.

The concurrency semantics are shaped by the following decisions:

- **`do` starts a process and yields its pid.** `do work(item)` runs the call in a new process; the value of the `do`-expression is the new process's pid, and the call's own result is discarded.
- **`pid <- message` sends.** `<-` delivers a message to a process's mailbox, and is always written with a space on each side — a juxtaposed `a<-b` is a syntax error rather than a guess, and comparison against a negated value is `a < -b`.
- **`receive` takes the same branches as `case`.** `receive { ... }` scans the mailbox for the first message matching any branch; non-matching messages stay queued, and the process blocks while nothing matches — selective receive comes from ordinary patterns, with no separate mechanism.
- **A process learns its own pid with `self_pid()`.** The idiomatic reply pattern is one line — `sender <- (self_pid(), request)` — with the tuple destructured right in the receiver's branch pattern. Pids are opaque values of type `Pid` that compare by identity and render as `<pid 3>`.
- **`halt()` stops the current process.** So does an unhandled error, and either kills only the offending process; core provides the process-exit signal a supervisor needs and nothing more — kill, wait, and restart policies are library territory.
- **The root process is the program.** When it ends — normally, by `halt()`, or by an uncaught raise — the program ends with it, and processes still runnable or parked are dropped. A program that waits for spawned work keeps its root alive, normally parked in `receive`; the rule holds on every target, including BEAM.
- Message passing is the core concurrency primitive; shared-memory primitives are not part of the core semantics.
- Data is immutable by default, so messages can be passed by copying on BEAM and by reference on the `ocaml` and `c` backends while keeping identical observable semantics.
- Tail calls are guaranteed; recursion is the idiomatic shape of a receive loop.
- Crash isolation and supervision are library-level on both backends: an unhandled error kills only the offending process.

## Networking

Networking is a first-class citizen: nearly every modern program talks over the network. Emo provides a unified asynchronous networking API. On the `ocaml` backend it runs on the same effects-based scheduler as the concurrency runtime — non-blocking sockets parked and woken by the scheduler, with TLS provided by OpenSSL bindings; on the TypeScript target it runs on Node's event loop, the emitted `await`s settling each call. The `net` and `http` packages declare `targets = ["ocaml", "c", "typescript"]`, and dependency resolution refuses them on every other target; the `c` target implements TCP only.

The API is **direct style**: network calls look like ordinary blocking calls, and the scheduler switches processes under the hood. There is no `async`/`await` and therefore no function coloring — any function can perform IO, and the API ecosystem stays single-tracked. Timeouts are seconds, and every failure — refused connection, unresolvable name, exceeded deadline, closed socket — returns `(R.error, reason)`, the reason stating the peer, the operation, and the reason.

The socket surface is the standard library's `net` package; HTTP lives in the `http` package:

- **Sockets.** `net.connect(host, port, timeout)`, `net.connect_unix(path, timeout)`, `net.tls_connect(host, port, timeout)`, and `net.tls_connect_insecure(host, port, timeout)` — certificate verification is on by default, and the insecure variant is the explicit, visibly dangerous opt-out — return a `TcpConn`. `net.listen(host, port)`, `net.listen_unix(path)`, and `net.listen_tls(host, port, cert_path, key_path)` return a `TcpListener`; `net.udp_bind(host, port)` returns a `UdpSocket`; `net.resolve(host)` resolves a name to its addresses. The full API reference lives in [docs/stdlib/net.md](docs/stdlib/net.md).
- **Connections.** `read_line()`, `read_exactly(n)`, `read_all()`, `write(data)`, and `close()` — a graceful close delivers pending writes first. `set_timeout(seconds)` bounds the operations that follow (the default is no timeout; `0.0` waits indefinitely). A listener serves `accept()` and reports `port()`; a datagram socket `send_to(host, port, data)`s and `recv_from()`s, and reports `port()`.
- **HTTP.** `http.get(url)`, `http.post(url, body)`, `http.put(url, body)`, `http.delete(url)`, and the general `http.request(method, url, headers, body, timeout)` return an `HttpResponse` carrying `status`, `headers`, and `body`. Redirects are never followed: a 3xx is a response like any other, and following it is the caller's explicit move. On the server, `http.serve(listener) -> (conn TcpConn) { ... }` is the process-per-connection helper, and `http.serve_requests(listener) -> (req HttpRequest) { ... }` parses each request and writes the handler's `HttpResponse` back — the handler is an ordinary Emo function. The full API reference lives in [docs/stdlib/http.md](docs/stdlib/http.md).

Layering is conventional: sockets (TCP/UDP/Unix domain, plus TLS) live in the `net` package, and HTTP (client and server) in the `http` package built on top of it. TLS is an OpenSSL binding on `ocaml` and Node's `tls` on `typescript`; the `c` target refuses it.

## Native Builds

`emo build` compiles a program to a standalone native binary — one command, one executable, no separate install step for applications. The default target is `c`: the emitted C compiles with the system `cc`, so a build needs no OCaml toolchain; `--target ocaml` emits OCaml for the backend that builds Emo itself:

```console
$ emo build main.emo -o myapp
built myapp
```

- **The runtime ships inside the binary.** The scheduler and the networking stack are libraries of the backend: a program that spawns processes and serves HTTP runs identically compiled, with no interpreter and no runtime download.
- **The compiled output is held to the interpreter's standard.** Every example compiles to a binary whose output matches `emo run` byte-for-byte — asserted in CI, not assumed.
- **Types feed performance.** Functions whose types are fully known compile to specialized native code — unboxed numbers, direct calls — while regions the checker cannot pin down keep dynamic semantics. `benchmarks/` records the numbers (the same fully type-declared program runs measurably faster specialized than with `--no-specialize`).
- **Builds are incremental.** The build caches by content hash: an unchanged program (and unchanged runtime) rebuilds without invoking the toolchain, and the build reports `(cached)`.
- **C interop is a `foreign def`.** The declaration names the C symbol — the `c` target calls it directly through the C ABI; the `ocaml` target marshals through a generated C wrapper:

  ```emo
  foreign def sqrt(x Float64) Float64 = "sqrt"
  ```

  `Float64`, `String`, and `Bool` cross the boundary today; other types are refused by the checker. Link additional C libraries with `--cclib` (`emo build main.emo --cclib m`). Foreign definitions run only in compiled programs — `emo run` refuses them. A target that cannot honor a `foreign def` refuses it at check time: `c` and `ocaml` honor it, while `wasm`, `typescript`, `beam`, and the freestanding `riscv64` refuse.
- **C calls back into Emo through an interface.** A `foreign def` parameter may name a single-method interface — the callback type. The `c` target passes the C side a generated trampoline plus the object as an opaque `void *userdata`; the callback's C signature is the method's parameters (marshaled like any foreign argument) followed by the trailing `void *userdata`, and invoking it dispatches to the receiver's own method:

  ```emo
  interface Handler {
    def on_click(tag Int64) String
  }

  foreign def set_handler(h Handler) Void = "set_handler"

  set_handler(MyHandler.new())   # the C side calls cb(tag, data) later
  ```

  The callback method's parameters stay in the marshaling tier (`Float64`, `String`, `Bool`, `Int64`), and its return adds `Void`. Two objects of different classes both satisfying the interface each dispatch to their own method — the object rides in the userdata. On targets without the contract the parameter refuses at check time, like any unhonored `foreign def`.
- **Compound data crosses as a struct shape.** A `foreign def` parameter whose type is a tuple — or a carrier class — passes a C struct by value: the element types in order are the layout, a nested tuple nests a struct within the struct, and a class instance contributes its init-assigned fields (the class's shape is its init signature). A compound return comes back as a tuple:

  ```emo
  foreign def stretch(r ((Float64, Float64), Float64)) (Float64, Float64) = "stretch"

  stretch(((1.0, 2.0), 3.0))   # a struct of a struct and a scalar, by value
  ```

  The `c` target declares the same `typedef struct` the C side sees — in `emo_defs.h`, so a shim compiles against the real layouts — and the by-value calling convention is the C compiler's job. Shape fields stay in the marshaling tier; a class-typed return refuses (name the tuple), and so does every target without the mechanism.
- **The default build needs only a C compiler.** The `c` target invokes the system `cc`; `--target ocaml` requires the OCaml toolchain — the same one that builds Emo itself.

## Testing

`emo test` runs a project's tests. The convention is structural, like the module tree itself: every `.emo` file under the project's `test/` directory is a test file, and every top-level `def test_*` in one is a test. A root-level `test.emo` file is an ordinary module, not a test file — the directory is the marker.

```emo
// test/arithmetic.emo
def test_add() {
  expect_equal(3, main.add(1, 2))
}
```

- **Assertions are the `expect_*` builtins.** `expect_equal(expected, actual)` compares with the language's structural `==`; `expect_true(value)` and `expect_false(value)` take a Bool; `expect_fail(message)` fails unconditionally. A failed assertion raises the one `Exception` class — the same discipline as any contract violation — with a message naming the assertion and both renderings: `expect_equal: expected 3, got 2`.
- **Each test runs in isolation.** The runner invokes every test in its own scheduler run and captures its output, so one test's processes, output, and failure never leak into the next. A raise — assertion or otherwise — fails only its own test; a runtime error (`E30xx`) errors it, reported separately.
- **The whole tree is checked first.** `emo test` runs the same static stages as `emo run` over every module, test files included; a static error anywhere stops the run with exit 65. Results exit 0 when all pass, 1 on any failure or error. A test function takes no parameters — a parameterized `def test_*` is reported, never called.

## Configuration

Emo is its own configuration language: a config file is just an Emo expression, and loading it means evaluating that expression. No separate format to learn — blocks, literals, string interpolation, and method calls are all available to configuration.

Config files are evaluated in a restricted profile:

- **Termination is guaranteed** — evaluation runs under a step budget, and every loop iteration counts against it.
- **Evaluation is hermetic** — the result depends only on the file's content and explicitly declared inputs; no hidden file-system or network access.
- **Side-effect free** — evaluating a config produces data, nothing else.

Because the type checker is built in, configuration schemas are just type declarations checked by the same pass — no second schema language needed.

For interop with the outside world, JSON/YAML/TOML remain supported as exchange formats: the standard library reads and writes them, with Emo as the source of truth and those formats as export products.

## EmoUI

[EmoUI](https://github.com/emo-lang/emo-ui) is the component-based UI framework written in Emo: UIs composed as trees of components that render from reactive state. Emo's syntax is shaped to serve it, and the principle is **no template language — the UI is plain Emo code**, the same philosophy as configuration. A component tree is nested calls with blocks (illustrative syntax):

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

Everything here is ordinary syntax (see [`SYNTAX.md`](SYNTAX.md)): calls with explicit parentheses, single-form blocks, named arguments. A component tree consists of plain function calls — components are defined as functions (`def card(user User) Component { ... }`), or as classes exposed through a same-named lowercase factory function (`def card(user User) Component { return Card.new(user) }`). From the caller's side, every component is a lowercase function; capitalized types are never invoked, and `.new` never appears in a tree. One rule specific to this domain: structured literals are immutable, so props and component trees are plain immutable data.

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

Documentation lives under `docs/`, with the syntax reference at the repository root. The Chinese translations of this README and of the syntax reference are [`docs/zh-CN/README.zh-CN.md`](docs/zh-CN/README.zh-CN.md) and [`docs/zh-CN/SYNTAX.zh-CN.md`](docs/zh-CN/SYNTAX.zh-CN.md).

- [`SYNTAX.md`](SYNTAX.md) — the language syntax reference.
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
- [`docs/industrial-software.md`](docs/industrial-software.md), [`docs/sql-database.md`](docs/sql-database.md), [`docs/rtos-assessment.md`](docs/rtos-assessment.md), [`docs/xv6.md`](docs/xv6.md), [`docs/visualization.md`](docs/visualization.md) — feasibility and market assessments.
- [`docs/TASKS.md`](docs/TASKS.md) — the implementation task checklist.

## License

Emo is released under the [MIT License](LICENSE).
