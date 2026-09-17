# Step 06 — Interpreter: Classes, Enums, Interfaces

**Milestone:** M1 · **Prereq:** step 05 · **Status:** not started

## Goal

Runtime semantics for the three user-defined type forms: value-semantic
immutable classes with the `init` window, closed enums, and duck-typed
dispatch with zero-overhead interfaces. After this step the README's object
examples run.

## Scope

### In

- **Classes**
  - `Class.new(...)` constructs: run `init` with `self` bound to a fresh
    instance; `self.x = ...` inside `init` creates fields; field assignment
    anywhere else is a runtime error (a flag on the evaluator marks the
    init window).
  - Named and positional constructor arguments, checked arity.
  - Instances are immutable value types: `==` is deep content equality.
    Since fields freeze after `init`, the evaluator may share structure
    freely — observable semantics stay those of copy-on-write (aliasing is
    undetectable).
- **Method dispatch** — `receiver.name(args)`: look up the method on the
    receiver's class, bind `self`, evaluate. Missing method → runtime
    `NoMethodError` carrying the receiver tag and method name. Dispatch is
    duck-typed at runtime; interfaces add nothing here.
- **Enums** — members are singleton values created at declaration
  (`Color.red`); `==`, usable as map keys later. No construction outside
  the declared set exists anywhere in the pipeline (nothing to enforce at
  runtime — the closed set is a static property).
- **Interfaces** — no runtime artifact at all. The step 08 checker consumes
  them; the evaluator skips their declarations.
- **`x.is(T)`** — `T` evaluates to a `TypeValue`; `is` checks the runtime
  tag for classes/enums, and for interfaces performs a structural check
  (does the receiver's class provide the declared methods). This is the
  runtime half of narrowing; the static half is step 08.
- **`raise`** — raising any value throws it as an Emo exception; a builtin
  `Exception` class (fields: `message`) ships so
  `raise Exception.new(message: "boom")` works verbatim from the README.
  Uncaught exceptions terminate the program with the exception's
  `.to_string()` and a short trace (polished reporting in step 07).
- Extend `.to_string()` to instances (a readable default like
  `#User(name: "Ada", age: 36)` — provisional format) and enum members
  (`Color.red.to_string()` → `"red"`).

### Out

- Catch syntax (undecided, `CHECK.md`).
- Hashing/map keys beyond enum equality.
- Any performance work (that is step 13's specialization story).

## Tasks

- [ ] `ClassDef` / `Instance` values; `init` window flag; field freeze.
- [ ] Method dispatch + `self`; `NoMethodError`.
- [ ] Deep `==` on instances; shared-structure immutability tests.
- [ ] Enum singletons; `TypeValue`; `is()` with structural interface check.
- [ ] `raise`; builtin `Exception`; uncaught-exception termination.
- [ ] `.to_string()` for instances, enums, exceptions.

## Acceptance

```emo
class User {
  def init(name String, age Int) {
    self.name = name
    self.age = age
  }

  def full_name() String {
    return self.name + " (" + self.age.to_string() + ")"
  }

  def is_older?() Bool {
    return self.age > 35
  }
}

const u = User.new(name: "Ada", age: 36)
print(u.full_name())            // Ada (36)
print(u.is_older?())            // true
print(u == User.new(name: "Ada", age: 36))   // true — value semantics

enum Color { red, green, blue }
print(Color.red == Color.red)   // true

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

print(welcome(English.new()))   // Hello — duck dispatch, no registration
print(English.new().is(Greeter))  // true — structural interface check
```

- Negative tests: `self.x = 1` outside `init` errors; calling a missing
  method errors with receiver + method names; uncaught raise exits non-zero
  with the message.
- `dune test` green.

## Open design items

- Instance `.to_string()` format is provisional.
