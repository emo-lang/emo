# Emo Syntax

Emo's syntax favors explicitness: everything is visibly what it is — a call looks like a call, a return is written out, a block has one shape. The rest of the design is indexed in [`README.md`](../../README.md) — the type system, modules and visibility, package management, concurrency, networking, native builds, testing, and configuration.

- **Calls always use explicit parentheses, juxtaposed to the callee.** No optional-parenthesis calls; every call is visibly a call, keeping code readable for beginners and the parser free of ambiguity resolution. The parentheses must touch the callee — `f (a)` with a space in between is an error, never silently a call.
- **A call may take a trailing block as its final argument.** Right after the closing parenthesis, a block attaches to the call: `page(title: "Home") { ... }` passes a zero-parameter block, and `list(users) -> (user User) { ... }` passes a parameterized one. The block must touch the call, exactly like the parentheses — this is the single notation behind UI trees and callbacks.
- **Blocks have a single form**: `{ ... }` and `-> (x) { ... }` — the latter being the parameterized block and the anonymous function. A block that ends without `return` is a Void block; one that returns a value must return on every path.
- **Functions and methods are defined with `def`**, uniformly at top level and inside classes. `def` is the named form of the arrow block: `def total(cart Cart) Decimal { ... }` pairs with `const total = -> (cart Cart) { ... }`.
- **Bindings are `const` (immutable) or `var` (mutable, block-scoped)** — constants versus variables, self-explanatory by wording. Both take a full pattern in place of the name: `const (R.ok, body) = file.read(path)` destructures a tuple, and a pattern that does not match is a runtime error — the same rule as a `case` scrutinee matching no branch. `var` bindings cannot escape their block; capturing one in a closure that outlives the block is a compile error.
- **Arguments can be passed by position or by name.** Given `def hello(name String, count Int64)`, `hello("world", 3)` and `hello(name: "world", count: 3)` are both valid calls, and both read in the parameter order: `hello(count: 3, name: "world")` is an error, and so is a positional argument after a named one, `hello(name: "world", 3)`. The block a call ends with is the one exception — it is the call's final argument by construction, and attached it reads as no argument at all: `page(title: "Home") { ... }`. Named form is the natural shape for props and options.
- **Type declarations are postfix, separated by a space**: parameters as `name String`, return types as `def full_name() String`. **Parameter types are always explicit; the return type may be omitted, which declares the function Void** — an omitted return type is not an untyped one, it is the strongest statement a signature can make. `init` is exempt — it returns the class it constructs, so it declares no return type. Arrow blocks (`-> (cart Cart) { ... }`) always declare their parameter types but infer their return types; when inference fails, the compiler reports an error asking for an explicit type declaration. Interface methods always declare their return types — a signature is a contract. Elsewhere, type declarations remain optional (see [Type System](type-system.md)).
- **Predicate methods end in `?`**: `def is_older?() Bool` reads naturally at the call site.
- **`return` follows the signature, in both directions.** A function with a declared return type must end in `return` on every path — there is no implicit "last expression is the return value" rule, and the compiler rejects any path that falls through. A Void function is the exact mirror: it takes no `return` at all — not even `return void` — its body simply ends.
- **`if` has exactly one statement shape.** `if <cond> { ... }` with an optional `else { ... }` — there is no `else if`, `elif`, or any chaining form; a further test is an `if` visibly nested inside the `else` block. Like all control flow, this `if` is a statement.
- **The one-line `if` expression picks a value.** `const label = if n >= 90 { "high" } else { "low" }` — both branches hold exactly one expression, the branch types must agree (`Unknown` joins silently), the condition is a Bool, and the `else` branch is required. The whole construct must stay on one line: a line break anywhere inside it is a syntax error pointing at the breaking token. Values that need more than a line are computed by an `if` statement and bound explicitly.
- **`case` matches a value against patterns.** Branches are `pattern -> { ... }`, first match wins, and a branch may carry a guard: `Color.red when signal.is_bright?()`. Patterns are enum members by qualified name (`Color.red` — a bare lowercase name is a binding pattern, since members and variables share the lowercase space), literals matching by value, and `_` matching anything. Like all control flow, `case` is a statement: results leave a branch through explicit `return` or binding. A scrutinee that matches no branch is a runtime error — never a silent skip.
- **Loops are `for` and `while`.** `for var i = 0; i < 100; i = i + 50 { ... }` binds its index in the header — scoped to the loop — and takes three `;`-separated clauses: init, condition, and post. The clauses are all required; the init is a `var` declaration and the post an assignment written out in full (`i = i + 1` — there is no `+=` or `++`). `while cond { ... }` takes a condition and no binding, so its variable is declared before the loop. Both are statements with the same paren-less shape as `if`, and `;` is legal only in a `for` header. `break` leaves the nearest enclosing loop and `continue` skips to the next iteration, running a `for`'s post clause first; both refuse outside a loop, and a loop never satisfies a declared return — the function still has to end in `return`.
- **Tuples are `(a, b, c)`.** Fixed-length, heterogeneous, immutable values that compare element-wise; the type-declaration form mirrors the literal — `(Int64, String)`. The paren rule resolves by content, with no trailing-comma forms: a comma makes a tuple (`()`, `(a, b)`); a single operator-free value in parentheses is a one-element tuple (`(a)` — grouping a lone value is meaningless); an expression containing operators is a group (`(sum * 3)`, `x && (y || z)`). `(a,)` is a syntax error — the one-element tuple is written `(a)` — and so is a `(` directly opening onto a `(`: `((x))` never parses; bind the inner value to a name first. The pair tuples of `Map.new(("a", 1), ("b", 2))` are the exception — each argument's parentheses are the pair itself, not a nesting. Nesting after a comma is legal and never adjacent: `(a, (b, c))`. In `case` patterns, parentheses are always tuple patterns, destructuring by position: `(Color.red, count) -> { ... }`.
- **Maps are `{ "key": value }`** — the mutable, insertion-ordered hash table. `{}` is the empty map, keys and values are arbitrary expressions whose types unify across the entries exactly like array elements, and keys must be hashable primitives — `String`, `Int64`, `Byte`, `Bool`, `Char`, `Float64` — with a provably unhashable key a compile error. `Map.new(("a", 1), ("b", 2))` builds from `(key, value)` pairs; a later pair overwrites an earlier one. The method surface: `get` (a missing key is a runtime error), `set` (inserts or replaces and returns the map, so `m.set("a", 1).set("b", 2)` chains; a replacement keeps the key's position), `has`, `remove` (a no-op when absent, returns the map), `length`, `keys`, and `values` — the last two as arrays in insertion order. `==` compares entries regardless of order, a map sent to another process arrives as a snapshot copy, and `m[k]` indexing is a compile error — `get` is the reading form.
- **Naming follows a strict case convention, enforced by the compiler.** All types start with an uppercase letter — built-in ones (`String`, `Int64`, `Bool`, `Float64`, `Char`) and user-defined ones alike (`class Foo`, `interface Bar`). Everything else — variables, keywords, function names — is lowercase, and function names use snake_case only; camelCase is not allowed.
- **Strings are always double-quoted, with a single interpolation form.** `"hello, ${name}"` — the braces hold any expression. Escapes are the minimal set `\n \r \t \\ \' \"`. Single quotes denote the `char` type: `'a'` is a character, `"a"` is a String of length one.
- **`println(value)` writes one line of output** — the value's `.to_string()` rendering plus a newline. Every primitive implements `.to_string()`, and interpolation uses the same rendering.
- **`printf(format, data)` renders C-style formatting.** `printf("hello: %s\n", ["world"])` — the format is a `String` and the arguments ride in one `Array`, consumed left to right. The conversions are C's: `%d %i %u %o %x %X` over `Int64` (the unsigned and base-16 forms read the 64-bit pattern), `%c` over `Char`, `Byte`, or `Int64` (one byte, C's unsigned-char conversion), `%s` over `String`, `%f %F %e %E %g %G` over `Float64`, and `%%` for a literal percent. Flags (`-`, `+`, space, `#`, `0`), width, and precision follow C17 §7.21.6.1 — `%*d` takes the width from the array, and a negative `*` width left-aligns. Rendering is byte-identical on every target: halfway float cases round to even, and `%g` switches style on the rounded exponent. What has no Emo reading is an error, not a guess — `%n`, `%p`, hex-float `%a`, and the length modifiers (`ll`, `h`, `z`, …) are all rejected. When the format and the data are literals (or the array's element type is known), the checker reads them statically: wrong conversion types, wrong counts, and malformed conversions are compile errors; a dynamic format or array is checked at runtime, where a mismatch is a runtime error.
- **Comments are `//` to end of line; there are no block comments.**

## Classes

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

## Interfaces

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
- Interfaces are compile-time contracts: the checker verifies shapes at type-declared positions, while runtime dispatch stays duck-typed with zero overhead.
- Narrowing goes to a class target: `if g.is(English)` gives `g` the class `English` inside the branch. An interface target (`g.is(Greeter)`) is a runtime shape test — it narrows an `Unknown` value to the interface, and leaves a value that already has a type unchanged, since Emo has no intersection types.

## Function Groups

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

## Enums

An enum is a closed, nominal set of named values — nothing more. Carrying data on members is deliberately excluded as an anti-pattern: when a value must be one of a known set with data attached, the idiomatic shape is an enum tag carried in a tuple — the built-in `R` exists for exactly the ok/error pair, `(R.ok, value)` beside `(R.error, reason)` — destructured directly in `case` and `receive`. Polymorphic data heavier than that is classes organized by an interface; failure paths are the error tuple, and only contract violations raise.

```emo
enum Color { red, green, blue }
```

- Members are the only values of the type — there is no way to construct an enum value from outside the set.
- Members are immutable values: comparable with `==`, hashable, usable as map keys.
- Matching an enum in `case` must cover every member; the checker reports the missing members wherever the type is decidable.

## Exceptions

Errors split in two, and Emo keeps the split visible. An **expected failure** — a malformed document, a missing file, a refused connection — is an ordinary value: the call returns `(R.ok, value)` on success and `(R.error, reason)` on failure, the reason a string stating exactly what failed (`json: expected array element at byte 3`). `R` is a built-in enum, no import needed, and the pair is matched, not caught:

```emo
case file.read(path) {
  (R.ok, body)   -> { println(body) }
  (R.error, why) -> { println("read failed: ${why}") }
}
```

When a failure is not expected, a binding pattern says so — a pattern that does not match is a runtime error, ending the process loudly:

```emo
const (R.ok, body) = file.read(path)
```

A **violation** — a broken contract, a bug — raises. `Exception` is the language's one exception class, carrying a `message` and an optional `data` Map of machine-readable context (a peer address, a file descriptor) that the crash report and supervision libraries read back:

```emo
raise Exception.new(message: "queue drained below zero")
raise Exception.new("connect timed out", { "op": "connect", "peer": host })
```

A raise cannot be caught — Emo has no catch construct — and the `raise` operand must be an `Exception` instance. Both built-in names are reserved: no declaration, whatever its kind, can take `Exception`, and none can take the result enum `R`. Uncaught exceptions kill only the offending process, and supervision is library-level (see [Concurrency](concurrency.md)). There are no checked exceptions.

## Mutability

Mutability is layered, and every layer is explicit. The mutable surface is a
closed set of six things — `var`, `Box`, `Bytes`, `List`, `Map`,
`ArrayBuilder` — each an independent value type of its own; none is built out
of another, and nothing else mutates in place. Mutation is alias-visible on all
six — a change made through one binding is seen through every other — while
`==` stays structural everywhere: a `Box` compares by contents, a `List`
element-wise, an `ArrayBuilder` element-wise, a `Map` by entries, `Bytes` by
bytes.

- `const` bindings never change; `var` bindings are mutable within their block and cannot escape it.
- Arrays are immutable values: length is fixed and contents are never changed in place — operations that transform an array return a new one, and `==` compares element-wise.
- A `Bytes` is a fixed-length mutable byte buffer: `Bytes.new(n)` allocates `n` bytes, `get` and `set` address them one by one (little-endian multi-byte accessors sit beside them), and `==` compares by content. The length never changes — `set` replaces bytes, it does not grow the buffer.
- Maps are the mutable keyed collection: `Map.new(("foo", "bar"), ("hello", 123))` takes each pair only as an initialization source — keys and values are read once into a fresh map and the returned value is that map itself; later pairs overwrite earlier values, and the key keeps its first-insertion position. `set` and `remove` change the map in place (each returns the map), keys keep their insertion position across updates, and `==` compares entries rather than order. Keys must be primitive types — a non-primitive key is an error. A map sent to another process arrives as a snapshot copy, so map mutation never crosses a process boundary either.
- Class fields are assigned only inside `init` and freeze afterwards.
- Long-lived mutable state — per process — lives in a `Box`: `Box.new(0)` constructs, `box.read()` reads, `box.replace(v)` replaces — deliberately nothing else. Sending a Box to another process delivers a snapshot copy, so mutability never crosses a process boundary.
- A `List` is the deque beside the Box: a double-ended queue that mutates in place where a Box holds one cell. `List.new([1, 2, "foo"])` takes the array only as an initialization source — the elements are copied into a fresh deque and the returned value is that deque itself; the array is not kept, so the two never see each other's changes. `list.push_front(x)` and `list.push_back(x)` insert at either end and return the list; `list.pop_front()` and `list.pop_back()` remove and yield the element; `list.length()` measures. Popping an empty List is a runtime error, like an out-of-bounds index, and `==` compares element-wise. Sending a List to another process delivers a snapshot copy — mutability never crosses a process boundary.
- An `ArrayBuilder` grows an array one element at a time. `ArrayBuilder.new()` takes nothing — a builder is born empty, and it is the one place an array is built without knowing its length up front. `b.push(v)` appends and answers the builder itself, so pushes chain; `b.length()` measures; `b.get(i)` reads back by index; `b.to_array()` returns a **fresh** `Array[T]` holding the elements pushed so far. The builder keeps its own elements, so growing it after `to_array` leaves the array it already returned untouched — the opposite of `List.new`, which copies on the way *in*. Reading outside the pushed prefix is a runtime error, and `==` compares element-wise. Sending an ArrayBuilder to another process delivers a snapshot copy.

  The element type is pinned by the first `push` whose argument type is known: `const kids = ArrayBuilder.new()` followed by `kids.push("a")` makes `kids` an `ArrayBuilder[String]`, so `kids.push(1)` is a type error. The pin lands on the **`const` binding named at the base of the pushed chain** — `kids.push("a").push("b")` pins `kids` just as plainly — while a `var` binding accepts any element type and a push written inside a larger expression pins nothing, since only a whole statement is a place a binding's type can be settled. This is deliberately stricter than `List.new`, whose elements stay unchecked until something reads them.

  On the BEAM target `get(i)` walks the builder's reversed accumulator and so costs O(n) where `push` is O(1); everywhere else `get` is O(1).
