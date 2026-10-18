# Emo testing guide

Emo ships a test runner and four assertion builtins. There is no framework to
install, no import to write, and no `deps` entry to add: `emo test` discovers
tests by convention, and `expect_equal`, `expect_true`, `expect_false`, and
`expect_fail` are bare names that every program already has.

A failed assertion raises the language's one `Exception` class. Emo has no
catch construct, so inside `emo test` the OCaml runner is the only place that
raise is trapped — one failed assertion fails its own test and no other.

## Quick start

A project is a directory with a `package.emo` manifest and a `test/`
directory:

```text
my-project/
  package.emo
  main.emo
  test/
    arithmetic.emo
```

`package.emo` is an ordinary manifest; a plain name is enough while the
project stays local:

```emo
package {
  name = "arithmetic"
  version = "0.1.0"
  targets = ["c"]

  deps {}
}
```

`main.emo` holds the code under test:

```emo
def add(a Int64, b Int64) Int64 {
  return a + b
}
```

`test/arithmetic.emo` holds tests:

```emo
def test_add() {
  expect_equal(3, main.add(1, 2))
}

def test_negative() {
  expect_equal(-1, main.add(-3, 2))
}
```

Run them from the project root:

```console
$ emo test
ok test.arithmetic.test_add
ok test.arithmetic.test_negative
2 tests, 2 passed
```

`emo new <name>` scaffolds the same layout, including a passing test under
`test/greet.emo`.

## Test discovery

- **The root is the working directory.** `emo test` requires a `package.emo`
  in the current directory; without one it reports `E5010` and exits 65.
- **Every module under `test/` is a test module.** Nested directories count
  (`test/parser/json.emo` is a test module). A root-level `test.emo` is an
  ordinary module, not a test file — the directory is the marker.
- **Every top-level `def test_*` in a test module is a test.** The name must
  start with `test_`. Tests inside classes or function groups are not
  collected.
- **A test takes no parameters.** A `def test_*` with parameters is reported
  as `ERROR <module>.<test>` with `E5008` and is never called. The runner
  ignores a test's return value; the ordinary form is a Void `def`.
- **Order is deterministic.** Modules run in sorted path order, and the tests
  within a module run in sorted name order.

There is no name filter and no `skip` attribute: the whole `test/` tree runs.

## The assertion builtins

| Builtin | Arguments | Passes when | Failure message |
| --- | --- | --- | --- |
| `expect_equal(expected, actual)` | any two values | the values are structurally equal | `expect_equal: expected <expected>, got <actual>` |
| `expect_true(value)` | a `Bool` | the value is `true` | `expect_true: got false` |
| `expect_false(value)` | a `Bool` | the value is `false` | `expect_false: got true` |
| `expect_fail(message)` | a `String` | never | the message itself |

All four return `Void`, so they are used as statements. Outside `emo test` a
failure is an ordinary uncaught exception; the runner is what turns it into a
test failure.

### `expect_equal(expected, actual)`

Compares with the language's structural `==`, the same relation ordinary code
uses:

- primitives compare by value; `Int64`, `Byte`, `Char`, and `String` values of
  different types never compare equal, because there is no cross-type coercion;
- tuples, arrays, `List`s, and `ArrayBuilder`s compare element by element;
- `Bytes` compare by content, `Box` by the value it holds, and `Map`s by their
  entries regardless of insertion order;
- class instances compare by class and field values.

Both arguments are untyped at the checker (`Unknown`), so any two values can
be compared. On failure the assertion renders both sides with their normal
`to_string()` form.

```emo
expect_equal(3, main.add(1, 2))
expect_equal([1, [2, "x"]], [1, [2, "x"]])
expect_equal(("ok", 3), result)
```

A failure reads:

```text
expect_equal: expected 3, got 2
```

### `expect_true(value)` and `expect_false(value)`

Take a `Bool` expression — a comparison, a predicate call, or a Bool variable:

```emo
expect_true(main.is_even(4))
expect_false(main.is_even(5))
expect_true(user.is_older?())
```

A wrong value fails with the exact message `expect_true: got false` or
`expect_false: got true`. A non-Bool argument is a runtime error: the checker
leaves the parameter at `Unknown`, and the runtime reports
`` E3001: `expect_true` expects a Bool, got Int64 ``, which the runner reports
as `ERROR`, not `FAIL`.

### `expect_fail(message)`

Always raises, carrying `message` unchanged. It is the escape hatch for a
condition that is not expressible as one of the other three:

```emo
def test_parse() {
  const (R.ok, doc) = parse(input)
  if doc.count() != 3 {
    expect_fail("expected 3 nodes, got " + doc.count().to_string())
  }
  expect_equal(3, doc.count())
}
```

Its argument is statically typed `String`; `expect_fail(42)` is a compile-time
type error (`E4004`), not a runtime one.

### Argument errors

| Error | Caught statically | Caught at runtime |
| --- | --- | --- |
| wrong argument count | `E4009` | `E3007` |
| `expect_fail` given a non-`String` | `E4004` | `E3001` |
| `expect_true` / `expect_false` given a non-`Bool` | — | `E3001` |
| `expect_equal` given mismatched value types | — (any two values are legal) | — |

`emo test` checks the whole tree first, so the static forms stop the run before
any test executes.

## How a run is reported

Each test produces exactly one outcome:

- **pass** — the test returned without a raise. The runner prints
  `ok <module>.<test>`.
- **fail** — an assertion failed, or the test raised any other exception. The
  runner prints `FAIL <module>.<test>`, the rendered diagnostic (code `E3010`,
  message `uncaught exception: ...`) with a source excerpt, and everything the
  test printed.
- **error** — a runtime error (`E30xx`) such as a non-Bool passed to
  `expect_true`, an out-of-bounds index, or a parameterized test function. The
  runner prints `ERROR <module>.<test>` with the diagnostic and captured
  output.

The module path includes the `test` directory: a test named `test_add` in
`test/arithmetic.emo` is reported as `test.arithmetic.test_add`. If a test
module's own top-level code raises or errors while loading, the result is
`ERROR <module>.<load>` and that module's tests do not run.

A typical failing run:

```console
$ emo test
FAIL test.fail.test_bad
  error[E3010]: uncaught exception: expect_equal: expected 3, got 2
  before
  loaded
1 test, 0 passed, 1 failed
```

The runner prints the rendered diagnostic — including a source excerpt and
caret — before the captured output. Output printed by a test is captured and
shown only when that test fails or errors; a passing test's output is not
shown. The summary line counts all three outcomes:

```text
3 tests, 0 passed, 1 failed, 2 errors
```

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | every test passed, or no tests were found under `test/` |
| `1` | at least one test failed or errored |
| `65` | a static stage failed (lexing, parsing, checking, or the manifest) |

The whole tree is statically checked before any test runs, so a static error
anywhere — in a test file or in the code under test — stops the run with exit
65. `emo test --locked` additionally requires a lockfile when the project has
dependencies, for CI, and exits 66 when it is missing.

## Isolation and shared state

Each test runs in its own scheduler run, with its own captured output. The
runner traps a raise per test, so one failure does not stop the others, and
processes spawned by a test are dropped when its scheduler run ends.

The module environment is different: a test module loads **once**, and all of
its tests run against that same environment. Module-level mutable values — a
top-level `var`, or a `Box`, `List`, `Map`, or `ArrayBuilder` created at module
scope — are shared by every test in that module and are not reset between
them. Create mutable state inside the test (or inside a helper it calls) when
the tests must not observe each other.

## Limits

- **Four assertions, no more.** There is no `expect_contains`, `expect_gt`, or
  `expect_raises`; compose with `expect_true` over an ordinary expression.
- **One failure per test.** An assertion raises, so the rest of that test does
  not run. Put independent checks in separate `def test_*` functions when you
  want to see all of them.
- **No parameterized tests, filtering, or hooks.** There is no setup/teardown;
  tests are ordinary functions, so call a shared helper instead.
- **Interpreter only.** `emo test` always interprets. The compiled backends do
  not lower the assertion builtins: a program that reaches one is refused by
  the backend (wasm, beam, riscv64) or fails at runtime (`c`, `ocaml`,
  `typescript`). Keep assertions in `test/` modules, which the entry points of
  compiled builds do not reach.
