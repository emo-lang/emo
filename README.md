# Emo

Emo is a general-purpose programming language, implemented in OCaml 5.

Repository: <https://github.com/emo-lang/emo>

## What is Emo?

Emo is **clean, explicit, and intuitive**. It draws on three decades of open-source programming languages — their strengths and their missteps — and is designed around three core principles:

- **Highly expressive syntax.** Code should read naturally and say what it means.
- **Principle of least surprise.** The language rules should match programmer intuition; things should work the way you expect them to.
- **Multiple compilation targets.** Emo compiles to native executables, to WebAssembly, to other languages such as TypeScript, to the BEAM virtual machine, and to bare metal (the `qemu` target — see EmoOS).

## Syntax

Emo's syntax favors explicitness: everything is visibly what it is — a call looks like a call, a return is written out, a block has one shape.

- **Calls always use explicit parentheses.** No optional-parenthesis calls; every call is visibly a call, keeping code readable for beginners and the parser free of ambiguity resolution.
- **Blocks have a single form**: `{ ... }` and `-> (x) { ... }` — the latter being the parameterized block and the anonymous function.
- **Functions and methods are defined with `def`**, uniformly at top level and inside classes. `def` is the named form of the arrow block: `def total(cart Cart) Decimal { ... }` pairs with `const total = -> (cart Cart) { ... }`.
- **Bindings are `const` (immutable) or `var` (mutable, block-scoped)** — constants versus variables, self-explanatory by wording. `var` bindings cannot escape their block; capturing one in a closure that outlives the block is a compile error.
- **Arguments can be passed by position or by name.** Given `def hello(name String)`, both `hello("world")` and `hello(name: "world")` are valid calls. Named form is the natural shape for props and options: `page(title: "Home") { ... }`.
- **Type annotations are postfix, separated by a space**: parameters as `name String`, return types as `def full_name() String`. **Function signatures always carry explicit types — parameters and return types alike**; signatures are contracts, and contracts are checked strictly. `init` is exempt — it returns the class it constructs. Arrow blocks (`-> (cart Cart) { ... }`) always take annotated parameters but infer their return types; when inference fails, the compiler reports an error asking for an explicit annotation. Elsewhere, annotations remain optional (see Type System).
- **Predicate methods end in `?`**: `def is_older?() bool` reads naturally at the call site.
- **`return` is always explicit** — there is no implicit "last expression is the return value" rule.
- **Naming follows a strict case convention, enforced by the compiler.** All types start with an uppercase letter — built-in ones (`String`, `Int`, `Bool`, `Float`, `Char`) and user-defined ones alike (`class Foo`, `interface Bar`, exceptions as in `class Exception`). Everything else — variables, keywords, function names — is lowercase, and function names use snake_case only; camelCase is not allowed.
- **Strings are always double-quoted, with a single interpolation form.** `"hello, ${name}"` — the braces hold any expression. Single quotes denote the `char` type: `'a'` is a character, `"a"` is a String of length one.

### Classes

`class` is the single notation for user-defined types: methods live inside the class body, next to the type they belong to.

```emo
class User {
  def init(name String, age Int) {
    self.name = name
    self.age = age
  }

  def full_name() String {
    return self.name + " " + self.age.to_string()
  }

  def is_older?() Bool {
    return self.age > 35
  }
}
```

- **`init` is the only window where fields are assigned.** Fields come into existence through `self.x = ...` inside `init`; assigning to `self.x` anywhere else is a compile error. Classes are therefore immutable value types: instances are copied on assignment (copy-on-write under the hood), and two instances with equal content are `==`.
- **`self` is passed implicitly and used explicitly** — no `self` in signatures, but always spelled out in bodies (`self.name`), so fields never blur with local variables.
- **No inheritance — neither single nor multiple.** Reuse is served by duck-typed functions, composition, and interfaces instead of class hierarchies.

### Interfaces

Polymorphism is structural: an `interface` declares a set of method signatures, and any class whose shape matches satisfies it — with no `implements` declaration.

```emo
interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "Hello"
  }
}

def welcome(g Greeter) String {
  return g.greet()
}
```

- Interfaces belong to the consumer: an implementation does not need to know the interface exists.
- Interfaces are compile-time contracts: the checker verifies shapes at annotated positions, while runtime dispatch stays duck-typed with zero overhead.
- Narrowing applies uniformly: `if g.is(Greeter) { ... }` works for interfaces as it does for classes.

### Enums

An enum is a closed, nominal set of named values — nothing more. Carrying data on members is deliberately excluded as an anti-pattern: data-carrying cases are classes organized by an interface, and failure paths are exceptions.

```emo
enum Color { red, green, blue }
```

- Members are the only values of the type — there is no way to construct an enum value from outside the set.
- Members are immutable values: comparable with `==`, hashable, usable as map keys.
- Matching on an enum must cover every member; the checker reports the missing one wherever the type is decidable.

### Exceptions

Errors are exceptions. An exception is an ordinary class instance, raised like this:

```emo
raise Exception.new(message: "something went wrong")
```

Uncaught exceptions kill only the offending process, and supervision is library-level (see Concurrency). There are no checked exceptions.

### Mutability

Mutability is layered, and every layer is explicit:

- `const` bindings never change; `var` bindings are mutable within their block and cannot escape it.
- Class fields are assigned only inside `init` and freeze afterwards.
- Long-lived mutable state — per process — lives in a mutable-cell primitive: a small container whose content can be read and replaced. Sending a cell to another process delivers a snapshot copy, so mutability never crosses a process boundary.

## Type System

Emo is gradually typed: **types are dynamic at runtime, but statically checked at compile time**.

- Runtime semantics are dynamically typed — every value carries a type tag. This aligns natively with BEAM and keeps everyday code free of type ceremony.
- The compiler has a built-in type-checking pass. Annotations are optional across the language — except on function signatures, where parameters and return types are both explicit — and unannotated code is still inferred and checked, reporting only errors that are certain; annotated code is checked strictly.
- Typing is structural and flow-sensitive — after `if user.is(Admin)`, `user` is narrowed to `Admin` — matching duck-typing intuition.
- There is no generics machinery: no generic definition syntax and no type-constraint system. Parameterized types exist only as annotation vocabulary (e.g. `Array[User]`) serving the checker and library signatures; application code relies on inference and rarely sees any type spelling at all.
- Strictness defaults high and can be relaxed explicitly.
- Type information feeds back into performance: modules with sufficiently complete type knowledge can be specialized (unboxed representations, direct dispatch) on the native backend.

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
- **The dependency graph is explicit.** Path references are the dependency declarations, giving automatic module discovery, incremental compilation, and compile-time cycle detection.

## Package Management

Packages slot directly into the module system: a package name becomes a top-level module path prefix. There is no `install` step for libraries — dependency resolution is a side effect of building. Using a package is `require`:

```emo
require "acme/json_tools"

def parse_config(text String) Json {
  return json_tools.parse(text)
}
```

- **`require` is a file-level statement that brings the package's short name into scope.** It needs no counterpart on the package side — a package's public surface is simply its module tree. Fully qualified paths are always available.
- **`require` pairs with the manifest, strictly.** Requiring a package that is missing from `deps` is a compile error — strictness comes first, and the manifest changes only by explicit action.

- **Central registry, with configurable endpoints.** Packages are addressed by `name@version` through a central registry, backed by a global content-addressed cache shared across projects — no per-project dependency copies. The registry endpoint is configurable per project or globally, serving private and on-premises distribution.
- **Scoped package names.** Third-party packages are named under a scope prefix, so ownership is explicit and name squatting has no ground to stand on; the scope prefix becomes the module path prefix. The official standard library alone owns the top-level short names (`json.decode()`, `http.get(url)`).
- **The manifest is an Emo config file**, written in the restricted profile (terminating, hermetic, side-effect free). **Dependencies are exact versions** — the version a package is developed and tested against — and **targets declare which compilation targets the package supports**:

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["native", "wasm"]

    deps {
      json = "2.3.1"
      http = "1.4.2"
    }
  }
  ```

- **Versions are semantic (major.minor.patch), resolved by Minimal Version Selection (MVS).** When different packages require different versions of the same dependency, the smallest version satisfying every requirement wins — for exact requirements, the highest one named. Upgrades are always explicit actions. A lockfile records the resolution with checksums and belongs in version control.
- **Target compatibility is checked at resolution time.** A dependency that does not support the target being built fails resolution with a clear error, not midway through compilation.

## Concurrency

Emo ships with a native concurrency model built around **processes and message passing**, in the spirit of the actor model. This choice is deliberate: it maps natively onto BEAM processes, while the native backend implements it with a scheduler built on OCaml 5 effects — the same foundation proven by runtimes such as Eio.

The concurrency semantics are shaped by the following decisions:

- Message passing is the core concurrency primitive; shared-memory primitives are not part of the core semantics.
- Data is immutable by default, so messages can be passed by copying on BEAM and by reference on the native backend while keeping identical observable semantics.
- Tail calls are guaranteed; recursion is the idiomatic shape of a receive loop.
- Crash isolation and supervision are library-level on both backends: an unhandled error kills only the offending process.

## Networking

Networking is a first-class citizen: nearly every modern program talks over the network. Emo provides a unified asynchronous networking API, implemented on each backend by its native facilities:

- **Native (OCaml)**: an effects-based scheduler on top of io_uring (Linux), kqueue (macOS), and IOCP (Windows), with libuv as the portable fallback — the same foundation as the concurrency runtime.
- **BEAM**: `gen_tcp` / `gen_udp` / `ssl`, one process per connection.
- **Wasm**: WASI sockets, or fetch/WebSocket in the browser.
- **TypeScript**: the target runtime's net/HTTP modules.

The API is **direct style**: network calls look like ordinary blocking calls, and the scheduler switches processes under the hood. There is no `async`/`await` and therefore no function coloring — any function can perform IO, and the API ecosystem stays single-tracked.

Layering is conventional: sockets (TCP/UDP/Unix domain, plus TLS) live in the core library, and HTTP (client and server) is part of the standard library. TLS starts as an OpenSSL binding on the native backend, with a pure-OCaml TLS stack as an optional alternative.

## Configuration

Emo is its own configuration language: a config file is just an Emo expression, and loading it means evaluating that expression. No separate format to learn — blocks, literals, string interpolation, and method calls are all available to configuration.

Config files are evaluated in a restricted profile:

- **Termination is guaranteed** — unbounded loops are disabled and iteration is bounded.
- **Evaluation is hermetic** — the result depends only on the file's content and explicitly declared inputs; no hidden file-system or network access.
- **Side-effect free** — evaluating a config produces data, nothing else.

Because the type checker is built in, configuration schemas are just type annotations checked by the same pass — no second schema language needed.

For interop with the outside world, JSON/YAML/TOML remain supported as exchange formats: the standard library reads and writes them, with Emo as the source of truth and those formats as export products.

## EmoUI

[EmoUI](https://github.com/emo-lang/emo-ui) is the component-based UI framework written in Emo: UIs composed as trees of components that render from reactive state. Emo's syntax is shaped to serve it, and the principle is **no template language — the UI is plain Emo code**, the same philosophy as configuration. A component tree is nested calls with blocks (illustrative syntax):

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}
```

Everything here is ordinary syntax (see Syntax): calls with explicit parentheses, single-form blocks, named arguments. A component tree consists of plain function calls — components are defined as functions (`def card(user User) Component { ... }`), or as classes exposed through a same-named lowercase factory function (`def card(user User) Component { return Card.new(user) }`). From the caller's side, every component is a lowercase function; capitalized types are never invoked, and `.new` never appears in a tree. One rule specific to this domain: structured literals are immutable, so props and component trees are plain immutable data.

Reactivity is explicit rather than implicit:

- Reactivity primitives live in the standard library with explicit, predictable semantics — no hidden dependency graphs.
- Compiler awareness optimizes them: statically decidable updates compile into targeted refreshes instead of runtime diffing.

These decisions interlock with the core design: props are checked by the built-in type checker (gradual typing), UI events are process messages (a UI process plus its mailbox yields the Elm architecture on top of Emo's concurrency), and platform backends only consume the component tree and its reactive updates — the language layer knows no platform details.

## EmoOS

Emo's reach extends down to the operating system layer: the language is capable of writing a kernel, so that an Emo kernel plus an Emo shell — with EmoUI on top — forms a complete OS, EmoOS.

The `qemu` compilation target is the bare-metal target. It assumes no OS, no libc, and no default runtime; it supports RISC-V and builds images bootable by QEMU — the kernel development loop is compile, boot, debug, with no hardware required.

Writing a kernel shapes the language in four ways:

- **Layered core library.** `core` (integers, strings, tuples, control flow) has zero runtime dependencies and is the only layer available to kernel code; the standard library requires the runtime.
- **Explicit memory primitives.** Raw memory access (`peek`/`poke` and friends) is provided as explicitly named library functions — dangerous operations are visibly dangerous.
- **Pluggable runtime.** The GC, allocator, and scheduler are replaceable components on the bare-metal target, not injected defaults — a kernel may choose a minimal GC, arenas, or static allocation.
- **Single-language closure.** The kernel builds with the `qemu` target while the shell and user programs build as ordinary native binaries — one language spanning both sides of the system.

## Implementation

The reference implementation of Emo is written in OCaml 5. Self-hosting is explicitly not a goal: Emo's reference implementation stays in OCaml.

Emo interoperates with C through OCaml's first-class C FFI: on the native backend, Emo binaries link directly against C libraries.

## Documentation

Documentation lives under `docs/`. Chinese translations are maintained under `docs/zh-CN/`.

## License

Emo is released under the [MIT License](LICENSE).
