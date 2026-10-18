# Step 39 — Compiler and language enablers for plotting

**Milestone:** M12 — Visualization (`plot`) · **Prereq:** the plot T0
skeleton (`docs/visualization.md`, `docs/temp-visual-check.md`) ·
**Related:** `docs/temp-visual-check.md` R2/R3, `docs/visualization.md`
decision 15, CHECK.md (cross-module types, the FFI capability table) ·
**Status:** in progress on `feat/plot`.

## Why this step exists

The plot T0 work surfaced four compiler gaps that the next plot steps
would otherwise code around: a class field read is typed `Unknown`
(so marks store their style fields flat), a class method named like a
runtime method is shadowed on some back ends (`length`), the `math`
package has no opt-in native fast path, and the ocaml specializer
admits expression shapes its native emitter cannot lower. Each is
independent of the plot steps and each removes a workaround from the
plot code.

## Goal

Every enabler lands with its own regression on every hosted target
it touches, and the plot package uses the one that changes its shape
(`Bar` carries a `BarStyle` instead of flat copies of its fields).

## Design note

- **Field types come from `init`, program-wide.** A class declares no
  field types; a field's type is the type of the expression `init`
  first assigns to it. `preregister_types` already types every
  module's top-level `const`/`var` initializers before any module is
  checked; it now walks every class's `init` the same way, binding
  `self` and the init parameters, and records `(class, field) → type`.
  A field read on a class-typed receiver — `self.width`,
  `ctx.plot_w`, `self.style.color` — answers that type; an
  unrecorded field stays `Unknown` (the old behavior). The emitters
  needed no new rule: a field is a dynamic word at runtime, and every
  back end already unboxes a dynamic word where the static type is
  native (the c emitter's `emit_field_read` does it explicitly; the
  others are dynamic throughout).
- **A runtime-method name never shadows a class method.** The c
  emitter's `read`/`replace` arms gain a `BoxType` guard and its
  `length` arm drops `Unknown`, so an untyped receiver falls to the
  runtime's `emo_dynamic_builtin`, which hands instances to their
  vtable first. The beam and wasm `length` arms gain the instance
  arms their `to_string` arms already carry. The interpreter, the
  ocaml runtime, and the TypeScript runtime already dispatch by
  value kind, so an instance never matched a builtin arm there.
- **`*_native` is a separate name, pinned to `c`/`ocaml`.** `math.exp`
  stays pure and byte-identical; `math.exp_native` (and `log`,
  `log10`, `pow`) is a `foreign def` over the host libm. A package
  may carry a `foreign def` on every target it declares: the
  definition is inert — the interpreter binds a value that raises
  E3009 when called, and the typescript/wasm/beam/riscv emitters skip
  the binding and refuse only a call to it — so `require "math"`
  keeps working everywhere and the native name is visibly different
  at the call site (decision 15).
- **The ocaml specializer and its predicate agree.** `expr_native`
  admits `Type_ref`, `Make_enum`, `Field_read`, and `Global`; the
  native emitter lowers them exactly as the dynamic emitter does (an
  `Emo_eval` value flowing through a native body — the shape an enum
  `case` over a native-typed function already needs). The container
  literals the native emitter cannot model (`Tuple`, `Array_lit`)
  leave the predicate, so such a function stays dynamic instead of
  dying at emit time.

## Tasks

- [ ] T39.1 — type `self.field` precisely (R2): `preregister_types`
  records field types from `init`; the checker answers them for
  class-typed receivers; `examples/field_types` on every target;
  `plot.mark.Bar` carries a `BarStyle`.
- [ ] T39.2 — a class method named like a runtime method is not
  shadowed (R3): the c emitter's guards, the beam and wasm `length`
  instance arms; `examples/length_method` on every target.
- [ ] T39.3 — `math`'s opt-in native fast path: `exp_native`,
  `log_native`, `log10_native`, `pow_native` as `foreign def`s;
  foreign definitions inert off the native targets (interpreter
  E3009 at the call, emitters refusing the call); docs pinned to
  `c`/`ocaml`.
- [ ] T39.4 — the ocaml specialization defect: the native emitter
  lowers `Type_ref`/`Make_enum`/`Field_read`/`Global`, the predicate
  drops the container literals; `examples/specialize_shapes` on the
  interpreter and the ocaml target.

## Out of scope

Field type declarations in class bodies, field assignment outside
`init`, a native fast path on wasm/typescript/beam, specialized
tuple/array locals.
