# Test primitives and the compiled targets

Emo's four assertion builtins — `expect_equal`, `expect_true`,
`expect_false`, and `expect_fail` — are part of the language surface, not a
library. The interpreter implements them; `emo test` is the runner that traps
their failure per test. The compiled targets do not lower them.

This document records the assessment behind that boundary and the decision it
led to: **a compiled program is the project minus its `test/` modules.** The
assertions stay interpreter-only, and a project can carry tests without its
compiled builds depending on them.

## Current behavior

In the interpreter, a failed assertion raises the language's one `Exception`
class. Inside `emo test` the runner traps that raise per test; outside it, the
raise is an ordinary uncaught exception (`E3010`, exit 1). The four builtins
are registered in the global environment and dispatched by the evaluator.

The compiled targets receive the call as an `Emo_ir.Builtin` node. Before the
change recorded here, each backend answered that node in its own way:

| Target | What a lowered assertion did |
| --- | --- |
| `ocaml` | `Emo_eval.call_builtin` reached `apply_builtin`, which reported `E3007: unknown builtin` at runtime |
| `c` | Emitted `emo_unsupported(...)`; at runtime printed `uncaught exception: <name> is not supported on this target yet` and exited 70 |
| `typescript` | Emitted `E.builtin(...)`; at runtime threw, rendered as `E3010`, exited 70 |
| `beam` | `emo build` refused the program (`builtin ... is not available yet`) with exit 65 |
| `wasm` | `emo build` refused the program with exit 65 |
| `riscv64` | `emo build` refused the program with exit 65 |

Because a build lowered every module in the tree, even an unreferenced
`test/` module containing `expect_equal` was enough to fail a wasm, beam, or
riscv64 build. C and TypeScript built, but the call site remained a runtime
failure if anything reached it. This was the concrete problem: tests are not
part of a program, yet they could decide whether the program built.

## The decision: tests are not lowered

`compile_inputs` now drops every module under the project root's `test/`
directory before type preregistration, checking, and lowering. The same
`test/` predicate is shared with the `emo test` discovery rule, so the two
cannot drift: a root-level `test.emo` remains an ordinary module, and a nested
`test/parser/json.emo` is a test module.

Consequences:

- `emo build` — every target — sees only product modules. A `test/` tree that
  uses assertions no longer blocks a beam, wasm, or riscv64 build.
- A test module is not checked by a build. `emo test` and `emo check` still
  check the whole tree, test modules included.
- Product code cannot reference a test module: the path is not in the build's
  module table, so the reference is a static error rather than a link-time
  surprise.
- An entry under `test/` is refused with `E5012`: a test module is not a
  compiled program. Passing `test/foo.emo` to `emo build` is an explicit
  request for something the build does not produce.
- The `E5007` gate for native dependencies is unchanged; it is independent of
  which modules are lowered.

This keeps the T46 rule — compiled targets refuse honestly rather than
silently doing something else — while removing the accidental coupling
between a project's tests and its builds.

## Could the assertions be implemented on the compiled targets?

Yes, in the sense of assertion logic: pass silently, fail with the specified
message, and terminate the program. The failure presentation and exit status
would still differ per target, because each backend's existing `raise` already
differs. The table below records what each target already has and what is
missing.

| Target | Reusable runtime pieces | Gaps | Effort |
| --- | --- | --- | --- |
| `ocaml` | `equal_value`, `to_string`, `net_raise`; builtins dispatch through `apply_builtin` | four match arms | small |
| `c` | `emo_eq_dyn`, `emo_to_string_dyn`, `emo_make_exception`, `emo_raise` | four emitter arms; a `type_name` helper for `E3001` messages | small |
| `typescript` | `deepEq`, `toStr`, `EEmoException`, `throwException` | four `E.builtin` cases; `deepEq` has no `EBox` arm, so `Box` equality is already wrong; uncaught exit is 70, not 1 | small |
| `beam` | `emo_eq/2`, `emo_to_str/1`, `throw({'emo_raise', ...})` | four builtin arms; a `Box` is a `make_ref`, so `=:=` compares identity, not contents; no `E3010` runner | medium |
| `wasm` | `deep_eq`, `to_str`, `strcat`, `throw` | builtin arms; message construction in the hand-written WAT builder; `deep_eq` has no `Box` arm; `Map` is unsupported on this target | medium |
| `riscv64` | `emo_eq_deep`, `emo_to_string`, `emo_string_concat`, `emo_fail` | `Raise` is refused and `Make_exception` is unsupported | fail-fast: medium; full `Raise`: large |

Two observations shape the recommendation:

1. **The assertion semantics are already backend-independent.** All four can be
   expressed in IR nodes that every target already lowers: `Let`, `If`,
   `Binary`, `Raise`, `Make_exception`, and `Interpolate`. A shared IR
   lowering would define the messages once and reuse each backend's `==`,
   `to_string`, and `raise`:

   ```text
   expect_equal(e, a)  =>
     let t1 = e
     let t2 = a
     if t1 != t2 {
       raise Exception.new(message: "expect_equal: expected ${t1}, got ${t2}")
     }
   ```

   The `Let` temporaries matter: arguments must be evaluated exactly once, in
   the interpreter's left-to-right order. The message built by `Interpolate`
   uses the same rendering rule as `to_string`.

2. **The hard part is not the assertion; it is parity around it.** Exact
   `E3001` messages need a type-name mapping on every backend, and
   `expect_equal` inherits each target's equality gaps: `Box` on TypeScript,
   beam, and wasm, and `Map` on beam and wasm (where maps are unsupported
   outright). Uncaught-exception rendering and exit status also differ today:
   C and OCaml exit 1, TypeScript exits 70, beam surfaces an Erlang crash,
   wasm aborts through the host, and riscv64 prints and powers off (QEMU exits
   0). Implementing assertions would expose these differences, not create
   them.

If the language ever needs assertions in compiled programs, the order should
be: shared IR lowering first, then `ocaml`, `c`, and `typescript`; beam and
wasm after their equality gaps are closed; riscv64 either as a fail-fast
check (print and halt, fitting its existing runtime-error convention) or not
at all until `Raise` exists there.

## Why not implement them now

`emo test` always interprets, so compiled assertions would have no runner and
no reporting to feed. Tests are not shipped with a program, and a compiled
program has no test entry point. The only practical effect of lowering the
assertions would be to make the old accidental build failure disappear — and
excluding `test/` removes that failure without adding four backend-specific
semantics that would then have to be kept in parity forever.

The interpreter remains the single implementation of the assertion contract.
