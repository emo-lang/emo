# Testing

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
