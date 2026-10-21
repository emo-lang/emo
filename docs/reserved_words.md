# Reserved words

Emo reserves a small, fixed set of words. The lexer recognizes them before
identifiers, so none of them can name a variable, parameter, field, function,
class, interface, enum, or function group. Wherever a name is
expected, a reserved word is a compile error that says so:

```text
expected a def name, found `if` (a reserved word)
```

Reserved words are lowercase and case-sensitive. Their capitalized spellings
(`Def`, `Class`, `Self`) are ordinary type names.

## The complete list

| Word | Role |
| --- | --- |
| `break` | Leaves the nearest enclosing loop. |
| `case` | Pattern-matching statement. |
| `class` | Class declaration. |
| `const` | Immutable binding. |
| `continue` | Skips to the next loop iteration. |
| `def` | Function or method definition. |
| `do` | Starts a process from a call and yields its pid. |
| `else` | The alternative branch of an `if`. |
| `emo` | Function group declaration; in expression position, `emo.` accesses the language's protocol registry. |
| `enum` | Enum declaration. |
| `for` | Three-clause loop. |
| `if` | Conditional statement, or the one-line conditional expression. |
| `interface` | Interface declaration. |
| `raise` | Raises an `Exception`. |
| `receive` | Selective receive from the process mailbox. |
| `require` | Brings a package's short name into scope. |
| `return` | Returns from a function. |
| `self` | The current instance inside a class method. |
| `var` | Mutable block-scoped binding. |
| `when` | Guard on a `case` or `receive` branch. |
| `while` | Condition loop. |

## Declarations

- **`def`** defines a function or a method, with the same form at top level and
  inside a class: `def total(cart Cart) Decimal { ... }`. A `def` name may end
  in `?` for a predicate; no other name may (see below).
- **`class`** declares a class. All fields come into existence through
  `self.x = ...` inside `init`, and classes have no inheritance.
- **`emo`** declares a function group — a named, stateless set of functions and
  constants: no instances, no fields, no `init`.
- **`interface`** declares a set of method signatures. Satisfaction is
  structural, with no `implements` declaration.
- **`enum`** declares a closed set of named values: `enum Color { red, green, blue }`.

```emo
class User {
  def init(name String) {
    self.name = name
  }

  def display_name() String {
    return self.name
  }
}

interface Greeter {
  def greet() String
}

emo Math {
  const tau = 6

  def abs(x Int64) Int64 {
    if x < 0 {
      return 0 - x
    }
    return x
  }
}
```

## Bindings

- **`const`** introduces an immutable binding.
- **`var`** introduces a mutable binding, scoped to its block. A `var` cannot
  escape its block; capturing one in a closure that outlives the block is a
  compile error.

Both take a full pattern in place of a plain name. A pattern that does not
match is a runtime error.

```emo
const (R.ok, body) = file.read(path)
var count = 0
```

## Control flow

- **`if`** / **`else`** — one statement shape, `if cond { ... }` with an
  optional `else { ... }`. There is no `else if`; a further test is an `if`
  nested inside the `else` block. The one-line form is an expression and
  requires both branches: `const label = if n >= 90 { "high" } else { "low" }`.
- **`for`** — a three-clause loop: `for var i = 0; i < 100; i = i + 1 { ... }`.
  All three clauses are required, and `;` is legal only in the `for` header.
- **`while`** — a condition loop: `while running { ... }`.
- **`break`** leaves the nearest enclosing loop, and **`continue`** skips to the
  next iteration, running a `for`'s post clause first. Both are errors outside
  a loop.
- **`case`** matches a value against patterns. Branches are
  `pattern -> { ... }`, the first match wins, and a scrutinee that matches no
  branch is a runtime error. Enum matching must cover every member wherever the
  type is decidable.
- **`when`** adds a guard to a branch: `Color.red when signal.is_bright?() -> { ... }`.

```emo
if n >= 90 {
  println("high")
} else {
  println("low")
}

for var i = 0; i < 100; i = i + 1 {
  if i == 10 {
    break
  }
  if i % 2 == 0 {
    continue
  }
}

case color {
  Color.red when signal.is_bright?() -> {
    println("bright red")
  }
  Color.red -> {
    println("dark red")
  }
  Color.green -> {
    println("green")
  }
}
```

## Functions and errors

- **`return`** returns from a function. A function with a declared return type
  must end in `return` on every path; there is no implicit "last expression is
  the return value" rule. A Void function takes no `return` at all.
- **`raise`** raises an exception. Its operand must be an `Exception` instance,
  and a raise cannot be caught.

```emo
def discount(cart Cart) Int64 {
  if cart.total() < 0 {
    raise Exception.new(message: "negative total")
  }
  return cart.total() * 9 / 10
}
```

## Processes

- **`do`** starts a process from a call and yields the new process's pid; the
  call's own result is discarded. Its operand must be a call:
  `const worker = do work(item)`.
- **`receive`** takes the same branches as `case` and scans the mailbox for the
  first message matching any branch. Non-matching messages stay queued, and the
  process blocks while nothing matches.

```emo
receive {
  (from, request) -> {
    from <- (self_pid(), handle(request))
  }
}
```

## Modules and packages

- **`require`** is a file-level statement that brings a package's short name
  into scope: `require "acme/json_tools"`. Every `require` pairs with a `deps`
  pin in the manifest, the standard library included.

## Reserved literals

**`true`** and **`false`** are the Bool literals. The lexer emits them as
literal tokens, so they are unavailable as names just like the keywords above.

## Names the compiler holds back

Two uppercase names are built into every program and cannot be declared:

- **`R`** — the built-in result enum, with members `ok` and `error`.
- **`Exception`** — the built-in exception class.

Unlike the words in the list above, these are not lexer keywords; the checker
refuses a class, interface, enum, or function group declared with either name.

## Pattern wildcard

In a pattern — a `case` or `receive` branch, or a binding's pattern — **`_`**
matches anything and binds nothing:

```emo
case pair {
  (_, count) -> {
    println(count)
  }
}
```

`_` is not a keyword; the wildcard meaning applies in pattern position only.

## Other reserved forms

- **A trailing `?`** is reserved for `def` names. It must be the last character
  of the name, and no other kind of declaration or binding may use it.
- **`@`, `$`, and `#`** have no meaning outside string and character literals;
  the lexer rejects them.

## Contextual words that are not reserved

Two words that look special are ordinary identifiers:

- **`foreign`** selects the C FFI form only at the start of a top-level item,
  where `foreign def` declares a binding to a C symbol. Elsewhere it is an
  ordinary name.
- **`init`** names the constructor only as a `def` inside a class. Outside a
  class, `def init` is an error; a binding named `init` is fine.

## Protocol names

`to_string` and `length` are ordinary identifiers everywhere except one
position: as a `def` name inside a class or interface body, they carry a
language protocol's contract — `def to_string() String` and
`def length() Int64` — and any other signature is a compile error stating
the contract. The complete set of protocol names is the `emo` registry (see
[protocols.md](protocols.md)); bindings, fields, parameters, top-level
functions, and group members with either name are fine.
