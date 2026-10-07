# Emo

Emo is a general-purpose programming language, implemented in OCaml 5.

Repository: <https://github.com/emo-lang/emo>

## What is Emo?

Emo is **clean, explicit, and intuitive**. It draws on three decades of open-source programming languages — their strengths and their missteps — and is designed around three core principles:

- **Highly expressive syntax.** Code should read naturally and say what it means.
- **Principle of least surprise.** The language rules should match programmer intuition; things should work the way you expect them to.
- **Multiple compilation targets.** Emo compiles to native executables, to WebAssembly, to other languages such as TypeScript, to the BEAM virtual machine, and to bare metal (the `riscv64` target — see EmoOS).

## Install

Prebuilt binaries are the fastest way to start. The binary carries the standard library inside it — nothing else to install (a C compiler joins the picture when you build with `emo build`, the default target). Grab the archive for your platform from [GitHub Releases](https://github.com/emo-lang/emo/releases), then:

```console
$ unzip emo-v0.25.9-macos-arm64.zip
$ ./emo-v0.25.9-macos-arm64/bin/emo run hello.emo
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

- **Calls always use explicit parentheses, juxtaposed to the callee.** No optional-parenthesis calls; every call is visibly a call, keeping code readable for beginners and the parser free of ambiguity resolution. The parentheses must touch the callee — `f (a)` with a space in between is an error, never silently a call.
- **A call may take a trailing block as its final argument.** Right after the closing parenthesis, a block attaches to the call: `page(title: "Home") { ... }` passes a zero-parameter block, and `list(users) -> (user User) { ... }` passes a parameterized one. The block must touch the call, exactly like the parentheses — this is the single notation behind UI trees and callbacks.
- **Blocks have a single form**: `{ ... }` and `-> (x) { ... }` — the latter being the parameterized block and the anonymous function. A block that ends without `return` is a Void block; one that returns a value must return on every path.
- **Functions and methods are defined with `def`**, uniformly at top level and inside classes. `def` is the named form of the arrow block: `def total(cart Cart) Decimal { ... }` pairs with `const total = -> (cart Cart) { ... }`.
- **Bindings are `const` (immutable) or `var` (mutable, block-scoped)** — constants versus variables, self-explanatory by wording. `var` bindings cannot escape their block; capturing one in a closure that outlives the block is a compile error.
- **Arguments can be passed by position or by name.** Given `def hello(name String)`, both `hello("world")` and `hello(name: "world")` are valid calls. Named form is the natural shape for props and options: `page(title: "Home") { ... }`.
- **Type annotations are postfix, separated by a space**: parameters as `name String`, return types as `def full_name() String`. **Parameter types are always explicit; the return type may be omitted, which declares the function Void** — an omitted return type is not an untyped one, it is the strongest statement a signature can make. `init` is exempt — it returns the class it constructs, so it declares no return type. Arrow blocks (`-> (cart Cart) { ... }`) always take annotated parameters but infer their return types; when inference fails, the compiler reports an error asking for an explicit annotation. Interface methods always declare their return types — a signature is a contract. Elsewhere, annotations remain optional (see Type System).
- **Predicate methods end in `?`**: `def is_older?() Bool` reads naturally at the call site.
- **`return` follows the signature, in both directions.** A function with a declared return type must end in `return` on every path — there is no implicit "last expression is the return value" rule, and the compiler rejects any path that falls through. A Void function is the exact mirror: it takes no `return` at all — not even `return void` — its body simply ends.
- **`if` has exactly one statement shape.** `if <cond> { ... }` with an optional `else { ... }` — there is no `else if`, `elif`, or any chaining form; a further test is an `if` visibly nested inside the `else` block. Like all control flow, this `if` is a statement.
- **The one-line `if` expression picks a value.** `const label = if n >= 90 { "high" } else { "low" }` — both branches hold exactly one expression, the branch types must agree (`Unknown` joins silently), the condition is a Bool, and the `else` branch is required. The whole construct must stay on one line: a line break anywhere inside it is a syntax error pointing at the breaking token. Values that need more than a line are computed by an `if` statement and bound explicitly.
- **`case` matches a value against patterns.** Branches are `pattern -> { ... }`, first match wins, and a branch may carry a guard: `Color.red when signal.is_bright?()`. Patterns are enum members by qualified name (`Color.red` — a bare lowercase name is a binding pattern, since members and variables share the lowercase space), literals matching by value, and `_` matching anything. Like all control flow, `case` is a statement: results leave a branch through explicit `return` or binding. A scrutinee that matches no branch is a runtime error — never a silent skip.
- **Loops are `for` and `while`.** `for var i = 0; i < 100; i = i + 50 { ... }` binds its index in the header — scoped to the loop — and takes three `;`-separated clauses: init, condition, and post. `while cond { ... }` takes a condition and no binding, so its variable is declared before the loop. Both are statements with the same paren-less shape as `if`, and `;` is legal only in a `for` header. `break` leaves the nearest enclosing loop; `continue` skips to the next iteration, running a `for`'s post clause first.
- **Tuples are `(a, b, c)`.** Fixed-length, heterogeneous, immutable values that compare element-wise; the annotation form mirrors the literal — `(Int64, String)`. The paren rule resolves by content, with no trailing-comma forms: a comma makes a tuple (`()`, `(a, b)`); a single operator-free value in parentheses is a one-element tuple (`(a)` — grouping a lone value is meaningless); an expression containing operators is a group (`(sum * 3)`, `x && (y || z)`). `(a,)` is a syntax error — the one-element tuple is written `(a)` — and so is a `(` directly opening onto a `(`: `((x))` and `f((a, b))` never parse; an inline tuple argument is bound to a name first. Nesting after a comma is legal and never adjacent: `(a, (b, c))`. In `case` patterns, parentheses are always tuple patterns, destructuring by position: `(Color.red, count) -> { ... }`.
- **Naming follows a strict case convention, enforced by the compiler.** All types start with an uppercase letter — built-in ones (`String`, `Int64`, `Bool`, `Float64`, `Char`) and user-defined ones alike (`class Foo`, `interface Bar`, exceptions as in `class Exception`). Everything else — variables, keywords, function names — is lowercase, and function names use snake_case only; camelCase is not allowed.
- **Strings are always double-quoted, with a single interpolation form.** `"hello, ${name}"` — the braces hold any expression. Escapes are the minimal set `\n \r \t \\ \' \"`. Single quotes denote the `char` type: `'a'` is a character, `"a"` is a String of length one.
- **`println(value)` writes one line of output** — the value's `.to_string()` rendering plus a newline. Every primitive implements `.to_string()`, and interpolation uses the same rendering.
- **Comments are `//` to end of line; there are no block comments.**

### Classes

`class` is the single notation for user-defined types: methods live inside the class body, next to the type they belong to.

```emo
class User {
  def init(name String, age Int64) {
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
- **No inheritance — neither single nor multiple.** Reuse is served by duck-typed functions, composition, and interfaces instead of class hierarchies. There is no mixin or `include` either: splicing another type's methods into a class is inheritance under another spelling, with the same method-resolution and collision problems. Nor is there method promotion: a class's methods are exactly the ones its body defines, so its shape never grows from another type — which is also why a type cannot accidentally come to satisfy an interface.

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
- Narrowing goes to a class target: `if g.is(English)` gives `g` the class `English` inside the branch. An interface target (`g.is(Greeter)`) is a runtime shape test — it narrows an `Unknown` value to the interface, and leaves a value that already has a type unchanged, since Emo has no intersection types.

### Function Groups

`emo` declares a **function group**: a named, stateless set of functions and constants. There are no instances, no `init`, and no fields — the members are the point, called through the group's name:

```emo
emo Math {
  const tau = 6

  def abs(x Int64) Int64 {
    if x < 0 {
      return 0 - x
    }
    return x
  }
}

Math.abs(0 - 7)   // 6
Math.tau          // 6
```

- **A group is not a class.** There is nothing to instantiate and nothing to pass around — it is a namespace of functions. The keyword appears at the declaration and disappears at the use site: `Math.abs(7)` never mentions it.
- **Members are referenced through the group** — `Math.abs(7)`, `Config.version` — and inside the group they are visible bare, the way static methods read in their own class.
- **Groups are stateless by design**: no `var`, no fields, no `init`. State wants a class and a `Box`.

### Enums

An enum is a closed, nominal set of named values — nothing more. Carrying data on members is deliberately excluded as an anti-pattern: when a value must be one of a known set with data attached, the idiomatic shape is an enum tag carried in a tuple — `(Outcome.ok, value)` — destructured directly in `case` and `receive`. Polymorphic data heavier than that is classes organized by an interface, and failure paths are exceptions.

```emo
enum Color { red, green, blue }
```

- Members are the only values of the type — there is no way to construct an enum value from outside the set.
- Members are immutable values: comparable with `==`, hashable, usable as map keys.
- Matching an enum in `case` must cover every member; the checker reports the missing members wherever the type is decidable.

### Exceptions

Errors are exceptions. An exception is an ordinary class instance, raised like this:

```emo
raise Exception.new(message: "something went wrong")
```

A raise is handled with `begin` / `catch` / `ensure`:

```emo
begin {
  const body = file.read(path)
  println(body)
} catch {
  e -> { println("failed: ${e.message}") }
} ensure {
  println("done")
}
```

`catch` takes the same `pattern -> { ... }` branches as `case` and
`receive`, matched against the raised exception; the first match wins, and a
raise that matches no branch keeps propagating. Because an exception is an
ordinary class instance, a branch can narrow on its class (`e when
e.is(Timeout) -> { ... }`), and `raise` inside `catch` re-raises. The three
clauses share one scope, so `ensure` can release what `begin` acquired, and
`ensure` runs on every exit — normal completion, a raise, or a `return`.
The construct is a statement, not an expression.

Uncaught exceptions kill only the offending process, and supervision is library-level (see Concurrency). There are no checked exceptions.

### Mutability

Mutability is layered, and every layer is explicit:

- `const` bindings never change; `var` bindings are mutable within their block and cannot escape it.
- Arrays are immutable values: length is fixed and contents are never changed in place — operations that transform an array return a new one, and `==` compares element-wise.
- Class fields are assigned only inside `init` and freeze afterwards.
- Long-lived mutable state — per process — lives in a `Box`: `Box.new(0)` constructs, `box.read()` reads, `box.replace(v)` replaces — deliberately nothing else. Sending a Box to another process delivers a snapshot copy, so mutability never crosses a process boundary.

## Type System

Emo is gradually typed: **types are dynamic at runtime, but statically checked at compile time**.

- Runtime semantics are dynamically typed — every value carries a type tag. This aligns natively with BEAM and keeps everyday code free of type ceremony.
- **Integer types are width-explicit: the default integer type is `Int64`.** It is 64-bit two's complement with wrap-around — arithmetic is performed modulo 2⁶⁴, so overflow behaves identically whether a program runs natively, on Wasm, on the BEAM, or on bare metal. Unannotated integer literals are `Int64`; there is no width-less `Int` spelling (see `docs/numeric-width.md`).
- **Float types are width-explicit: the default float type is `Float64`.** It is IEEE 754 binary64 on every target, so floating-point behavior is identical everywhere. Unannotated float literals are `Float64`; there is no width-less `Float` spelling.
- **Numeric literals** are decimal, hexadecimal (`0xFF`), binary (`0b1010_1010`), or octal (`0o755`), with `_` as a digit separator (`1_000_000`). There is no leading-zero octal and no width suffix — bare literals stay `Int64`/`Float64`.
- The compiler has a built-in type-checking pass. Annotations are optional across the language — except on function signatures, where parameter types are explicit and an omitted return type declares Void — and unannotated code is still inferred and checked, reporting only errors that are certain; annotated code is checked strictly.
- Typing is structural, and an `is` test narrows — after `if user.is(Admin)`, `user` is an `Admin` inside the branch, and never past it — matching duck-typing intuition.
- There is no generics machinery: no generic definition syntax and no type-constraint system. Parameterized types exist only as annotation vocabulary (e.g. `Array[User]`, `Box[Int64]`) serving the checker and library signatures; application code relies on inference and rarely sees any type spelling at all. A parameter that receives a block is annotated `Block`.
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

- **Central registry, with configurable endpoints.** Packages are addressed by `name@version` through a central registry, backed by a global content-addressed cache shared across projects — no per-project dependency copies. The registry endpoint is read from the `EMO_REGISTRY` environment variable — set it globally or per project — serving private and on-premises distribution; unset, the standard library's bundled registry ships with the compiler and serves by default.
- **Scoped package names.** Third-party packages are named under a scope prefix, so ownership is explicit and name squatting has no ground to stand on; the scope prefix becomes the module path prefix. The official standard library alone owns the top-level short names (`json.decode()`, `http.get(url)`).
- **The manifest is an Emo config file**, written in the restricted profile (terminating, hermetic, side-effect free). **Dependencies are exact versions** — the version a package is developed and tested against — and **targets declare which compilation targets the package supports**:

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["ocaml", "wasm"]

    deps {
      json = "2.3.1"
      http = "1.4.2"
    }
  }
  ```

- **Versions are semantic (major.minor.patch), resolved by Minimal Version Selection (MVS).** When different packages require different versions of the same dependency, the smallest version satisfying every requirement wins — for exact requirements, the highest one named. Upgrades are always explicit actions. The lockfile (`package.lock`) records the resolution with checksums and belongs in version control; `emo deps resolve` writes it, `emo deps update` regenerates it after a pin changes, `emo deps list` reads it — building never rewrites it silently. A checksum is the SHA-256 over the package's `.emo` sources, sorted by path and fed as `path \0 content \0` — the same digest the registry recomputes on publish. (Checksums were MD5 before the registry protocol froze; a lockfile written by an older compiler should simply be deleted and re-resolved.)
- **Target compatibility is checked at resolution time.** A dependency that does not support the target being built fails resolution with a clear error, not midway through compilation.
- **Publishing is `emo publish`, run from the package root.** The command validates the manifest (an `owner/name` name, a well-formed version), packs every `.emo` source — subdirectories included — plus an optional root `README.md` into a deterministic `.emoji` archive (gzip tar, sorted paths, zeroed metadata: the same input always packs to the same bytes), and POSTs it to the registry. The endpoint comes from `--registry` or `EMO_REGISTRY`, the API token from `--token` or `EMO_TOKEN`; `--dry-run` validates and packs locally, printing the archive name, size, checksum, and file list without uploading. Versions are immutable: publishing an existing version is rejected — bump `version` in the manifest.

## Concurrency

Emo ships with a native concurrency model built around **processes and message passing**, in the spirit of the actor model. This choice is deliberate: it maps natively onto BEAM processes, while the native backend implements it with a scheduler built on OCaml 5 effects — the same foundation proven by runtimes such as Eio.

The concurrency semantics are shaped by the following decisions:

- **`do` starts a process and yields its pid.** `do work(item)` runs the call in a new process; the value of the `do`-expression is the new process's pid, and the call's own result is discarded.
- **`pid <- message` sends.** `<-` delivers a message to a process's mailbox, and is always written with a space on each side — a juxtaposed `a<-b` is a syntax error rather than a guess, and comparison against a negated value is `a < -b`.
- **`receive` takes the same branches as `case`.** `receive { ... }` scans the mailbox for the first message matching any branch; non-matching messages stay queued, and the process blocks while nothing matches — selective receive comes from ordinary patterns, with no separate mechanism.
- **A process learns its own pid with `self_pid()`.** The idiomatic reply pattern is one line — `sender <- (self_pid(), request)` — with the tuple destructured right in the receiver's branch pattern. Pids are opaque values of type `Pid` that compare by identity and render as `<pid 3>`.
- **`halt()` stops the current process.** So does an unhandled error, and either kills only the offending process; core provides the process-exit signal a supervisor needs and nothing more — kill, wait, and restart policies are library territory.
- Message passing is the core concurrency primitive; shared-memory primitives are not part of the core semantics.
- Data is immutable by default, so messages can be passed by copying on BEAM and by reference on the native backend while keeping identical observable semantics.
- Tail calls are guaranteed; recursion is the idiomatic shape of a receive loop.
- Crash isolation and supervision are library-level on both backends: an unhandled error kills only the offending process.

## Networking

Networking is a first-class citizen: nearly every modern program talks over the network. Emo provides a unified asynchronous networking API. On the native backend it runs on the same effects-based scheduler as the concurrency runtime — non-blocking sockets parked and woken by the scheduler, with TLS provided by OpenSSL bindings. Networking is ocaml/c-only: the `net` and `http` packages declare `targets = ["ocaml", "c"]`, and dependency resolution refuses them on every other target.

The API is **direct style**: network calls look like ordinary blocking calls, and the scheduler switches processes under the hood. There is no `async`/`await` and therefore no function coloring — any function can perform IO, and the API ecosystem stays single-tracked. Timeouts are seconds, and every failure — refused connection, unresolvable name, exceeded deadline, closed socket — raises an ordinary Emo exception whose message states the peer, the operation, and the reason.

The socket surface is the standard library's `net` package; HTTP lives in the `http` package:

- **Sockets.** `net.connect(host, port, timeout)`, `net.connect_unix(path, timeout)`, `net.tls_connect(host, port, timeout)`, and `net.tls_connect_insecure(host, port, timeout)` — certificate verification is on by default, and the insecure variant is the explicit, visibly dangerous opt-out — return a `TcpConn`. `net.listen(host, port)`, `net.listen_unix(path)`, and `net.listen_tls(host, port, cert_path, key_path)` return a `TcpListener`; `net.udp_bind(host, port)` returns a `UdpSocket`; `net.resolve(host)` resolves a name to its addresses. The full API reference lives in [docs/stdlib/net.md](docs/stdlib/net.md).
- **Connections.** `read_line()`, `read_exactly(n)`, `read_all()`, `write(data)`, and `close()` — a graceful close delivers pending writes first. `set_timeout(seconds)` bounds the operations that follow (the default is no timeout; `0.0` waits indefinitely). A listener serves `accept()` and reports `port()`; a datagram socket `send_to(host, port, data)`s and `recv_from()`s, and reports `port()`.
- **HTTP.** `http.get(url)`, `http.post(url, body)`, `http.put(url, body)`, `http.delete(url)`, and the general `http.request(method, url, headers, body, timeout)` return an `HttpResponse` carrying `status`, `headers`, and `body`. Redirects are never followed: a 3xx is a response like any other, and following it is the caller's explicit move. On the server, `http.serve(listener) -> (conn TcpConn) { ... }` is the process-per-connection helper, and `http.serve_requests(listener) -> (req HttpRequest) { ... }` parses each request and writes the handler's `HttpResponse` back — the handler is an ordinary Emo function. The full API reference lives in [docs/stdlib/http.md](docs/stdlib/http.md).

Layering is conventional: sockets (TCP/UDP/Unix domain, plus TLS) live in the `net` package, and HTTP (client and server) in the `http` package built on top of it. TLS is an OpenSSL binding on the `ocaml` target.

## Native Builds

`emo build` compiles a program to a standalone native binary — one command, one executable, no separate install step for applications. The default target is `c`: the emitted C compiles with the system `cc`, so a build needs no OCaml toolchain; `--target ocaml` emits OCaml for the backend that builds Emo itself:

```console
$ emo build main.emo -o myapp
built myapp
```

- **The runtime ships inside the binary.** The scheduler and the networking stack are libraries of the backend: a program that spawns processes and serves HTTP runs identically compiled, with no interpreter and no runtime download.
- **The compiled output is held to the interpreter's standard.** Every example compiles to a binary whose output matches `emo run` byte-for-byte — asserted in CI, not assumed.
- **Types feed performance.** Functions whose types are fully known compile to specialized native code — unboxed numbers, direct calls — while regions the checker cannot pin down keep dynamic semantics. `benchmarks/` records the numbers (the same fully annotated program runs measurably faster specialized than with `--no-specialize`).
- **Builds are incremental.** The build caches by content hash: an unchanged program (and unchanged runtime) rebuilds without invoking the toolchain, and the build reports `(cached)`.
- **C interop is a `foreign def`.** The declaration names the C symbol — the `c` target calls it directly through the C ABI; the `ocaml` target marshals through a generated C wrapper:

  ```emo
  foreign def sqrt(x Float64) Float64 = "sqrt"
  ```

  `Float64`, `String`, and `Bool` cross the boundary today; other types are refused by the checker. Link additional C libraries with `--cclib` (`emo build main.emo --cclib m`). Foreign definitions run only in compiled programs — `emo run` refuses them. A target that cannot honor a `foreign def` refuses it at check time: `c` and `ocaml` honor it, while `wasm`, `typescript`, `beam`, and the freestanding `riscv64` refuse.
- **The default build needs only a C compiler.** The `c` target invokes the system `cc`; `--target ocaml` requires the OCaml toolchain — the same one that builds Emo itself.

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

  list(users) -> (user User) {
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

The `riscv64` compilation target is the bare-metal target. It assumes no OS, no libc, and no default runtime; it builds freestanding RISC-V images — the kernel development loop is compile, boot, debug, with no hardware required. QEMU is the target's default runner for that loop, not part of the target itself; the same image runs on real RISC-V hardware.

Writing a kernel shapes the language in four ways:

- **Layered core library.** `core` (integers, strings, tuples, control flow) has zero runtime dependencies and is the only layer available to kernel code; the standard library requires the runtime.
- **Explicit memory primitives.** Raw memory access (`peek`/`poke` and friends) is provided as explicitly named library functions — dangerous operations are visibly dangerous.
- **Pluggable runtime.** The GC, allocator, and scheduler are replaceable components on the bare-metal target, not injected defaults — a kernel may choose a minimal GC, arenas, or static allocation.
- **Single-language closure.** The kernel builds with the `riscv64` target while the shell and user programs build as ordinary native binaries — one language spanning both sides of the system.

## Implementation

The reference implementation of Emo is written in OCaml 5. Self-hosting is explicitly not a goal: Emo's reference implementation stays in OCaml.

Emo interoperates with C through OCaml's first-class C FFI: on the native backend, Emo binaries link directly against C libraries.

## Documentation

Documentation lives under `docs/`. The Chinese translation of this README is [`docs/zh-CN/README.zh-CN.md`](docs/zh-CN/README.zh-CN.md).

- [`docs/native-backend.md`](docs/native-backend.md) — how `emo build` produces a native binary, and the C FFI.
- [`docs/toolchain-distribution.md`](docs/toolchain-distribution.md) — how the toolchain is distributed: the OCaml requirement, `emo doctor`, and deferring the `c` backend.
- [`docs/runtime-and-freestanding.md`](docs/runtime-and-freestanding.md) — what "runtime" and "freestanding" mean, and how they map to Emo's targets.
- [`docs/numeric-width.md`](docs/numeric-width.md) — width-explicit numeric types on every target.
- [`docs/var-escape.md`](docs/var-escape.md) — the `var`-escape rule.
- [`docs/stdlib/`](docs/stdlib/) — the standard-library API references (`net`, `http`).
- [`docs/lsp.md`](docs/lsp.md) — the language server and the VS Code extension.
- [`docs/industrial-software.md`](docs/industrial-software.md), [`docs/sql-database.md`](docs/sql-database.md), [`docs/rtos-assessment.md`](docs/rtos-assessment.md), [`docs/xv6.md`](docs/xv6.md) — feasibility and market assessments.
- [`docs/TASKS.md`](docs/TASKS.md) — the implementation task checklist.

## License

Emo is released under the [MIT License](LICENSE).
