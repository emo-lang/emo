# Built-in versus runtime implementation — the code-side split

Written 2026-10-15, on `feat/emo-ui`. A temporary working note, not
decided design: this plans one mechanical-to-structural change and records
the evidence for it. English-only on purpose — a translation follows only
if the file outlives the work.

## Why this exists

The terminology sweep of 2026-10-15 settled the *documentation*: a
**built-in** is a mechanism or type the language itself owns — `println`,
`R`, `Exception`, the capability types — and a **runtime implementation**
is what a standard-library package's Emo source calls underneath
(`os_read`, `file_write`, `net_connect`). The type-layering entry in
`CHECK.md` now states the split outright, including that the checker's
root environment carrying runtime implementations is an axis *separate*
from built-in ownership.

The code did not follow, and it is the reason the documents were wrong to
begin with. One word — "builtin" — currently names all of:

- the language's own built-ins,
- the standard library's runtime implementations,
- the capability types' methods,

and, worst of the three, **the table that carries the first two
together**. `is_builtin "os_read"` answers `true`; `BuiltinFn` is a single
value variant holding `println` and `net_connect` alike; `apply_builtin`
is one `match` with arms for both. The split below gives the two
populations independent names, which requires splitting the carriers.

## The three populations

| | A — language built-ins | A′ — capability-type methods | B — runtime implementations |
| --- | --- | --- | --- |
| **Names** | `println` `printf` `self_pid` `halt` `expect_equal` `expect_true` `expect_false` `expect_fail` (8, bare) | `substring` `trim` `split` `lower` `to_string` `length` `get` `set` `push` `push_front` `pop_back` `to_array` `read_line` `write` `close` `accept` `port` `set_timeout` `get_u16_le` … | `os_*` (20) `file_*` (2) `net_*` (9) — 31, package-prefixed |
| **Owner** | the language | the language (the capability types) | the standard library |
| **Reached by** | a bare call | method syntax on a receiver | a bare call |
| **Documented as API** | yes — `docs/intro/` | yes — the capability types' docs | **never** |
| **Import needed** | no | no | no (the stdlib's Emo source calls it) |

### A — language built-ins

Registered in the interpreter's root frame as bare names
([`emo_eval.ml:293-308`](../src/emo_eval/emo_eval.ml)), listed literally
in the name predicate ([`emo_ir.ml:154-155`](../src/emo_ir/emo_ir.ml)),
documented in `docs/intro/` (testing, syntax), and reserved.

### A′ — the capability types' methods

The `emo_builtin_methods[]` table
([`emo_c_runtime.c:3152`](../src/emo_codegen/c/emo_c_runtime.c)) holds the
methods of `String`, `Bytes`, `List`, `Map`, `Box`, and the connection
types — `CHECK.md`'s capability tier. They are reached through
`emo_dynamic_builtin`, which consults a receiver's vtable first and this
table only for a non-instance
([`emo_c_runtime.c:3201`](../src/emo_codegen/c/emo_c_runtime.c)). Its
counterpart on `riscv64` is the `.Ldm_builtin` dispatch label
([`emo_riscv.ml:1875`](../src/emo_codegen/emo_riscv.ml)).

Nothing in A′ is misnamed. It is the language's own types' methods and it
keeps the word.

### B — runtime implementations

`os_*`, `file_*`, `net_*` — one prefix per standard-library package. They
are matched by prefix in the same predicate that lists A by name, and
registered in the same root frame by the same value variant.

The stdlib's own source shows why they are not a surface: the `os`
package's `read` is `return os_read(fd, n)`
([`stdlib/registry/os/0.1.0/os.emo:95`](../stdlib/registry/os/0.1.0/os.emo)).
`os_read` is a bare identifier in Emo source, so **nothing in the AST
records which package it belongs to** — the prefix is the whole of the
association.

## The plan: two name sets

**Set A — the word `builtin` stays, scoped to A and A′.**

```
BuiltinFn | Builtin { name; args } | is_builtin | apply_builtin
E.builtin                     (the emitted TypeScript entry)
emo_dynamic_builtin | emo_builtin_methods | emo_builtin_method | Ldm_builtin
builtin_exception
```

**Set B — a new set, spelled from the already-settled term.** The
documentation term is "runtime implementation"; the code name is its
short form.

```
RuntimeImplFn                 (the interpreter value variant, beside BuiltinFn)
RuntimeImpl { name; args }    (the IR node, beside Builtin)
is_runtime_impl               (the prefix match: os_ / file_ / net_)
apply_runtime_impl            (the interpreter dispatch, beside apply_builtin)
emit_runtime_impl             (the c emitter — today's emit_io_builtin)
E.runtime_impl(name, args)    (the emitted TypeScript entry, beside E.builtin)
```

No third, neutral word is introduced: each set's code name is the code
spelling of the term the documents already use.

## The carriers to split

1. **The interpreter value variant.** `BuiltinFn of string`
   ([`emo_eval.ml:37`](../src/emo_eval/emo_eval.ml)) holds both
   populations; `global_env` registers A at lines 293-308 and B at
   310-346 through it. Split into `BuiltinFn` and `RuntimeImplFn`, and
   register each population under its own variant.

2. **The interpreter dispatch.** `apply_builtin`
   ([`emo_eval.ml:2644`](../src/emo_eval/emo_eval.ml)) is one `match`:
   `"println"` at 2646, `"os_read"` at 2869. Split into `apply_builtin`
   and `apply_runtime_impl`. `call_builtin`
   ([`emo_eval.ml:3672`](../src/emo_eval/emo_eval.ml)) is the wrapper the
   emitted OCaml calls, and takes the same treatment.

3. **The checker predicate and the IR node.** `is_builtin`
   ([`emo_ir.ml:154`](../src/emo_ir/emo_ir.ml)) becomes `is_builtin` (the
   8 bare names) plus `is_runtime_impl` (the 3 prefixes). The IR node
   `Builtin of { name; args }` ([`emo_ir.ml:33`](../src/emo_ir/emo_ir.ml),
   constructed at 374 and 477) gains a sibling `RuntimeImpl`. The
   checker's root environment
   ([`emo_check.ml:691`](../src/emo_check/emo_check.ml), comment "The
   built-in surface every program sees") holds both populations today in
   one flat `bindings` list; the signatures stay, the comment and the
   grouping should follow the split.

4. **The c emitter.** `emit_io_builtin`
   ([`emo_c.ml:555`](../src/emo_codegen/emo_c.ml)) handles B **and**
   `printf`, which is A — `printf` moves to the A path, the rest becomes
   `emit_runtime_impl`. `emit_builtin`
   ([`emo_c.ml:1728`](../src/emo_codegen/emo_c.ml)) and the
   `Builtin { name = "println" }` / `"halt"` / `"self_pid"` arms
   ([`emo_c.ml:1810-1817`](../src/emo_codegen/emo_c.ml)) are already A and
   stay.

5. **The emitted TypeScript entry.** The backend emits
   `E.builtin(%S, [%s])` ([`emo_ts.ml:262`](../src/emo_codegen/emo_ts.ml))
   against the runtime's `builtin` method
   ([`ts_runtime.ts:1886`](../src/emo_codegen/ts/ts_runtime.ts),
   [`:2320`](../src/emo_codegen/ts/ts_runtime.ts)). Split into two entries.

## Names that do not change

- Everything in A′: `emo_dynamic_builtin`, `emo_builtin_methods`,
  `emo_builtin_method`, `.Ldm_builtin`.
- `builtin_exception` ([`emo_eval.ml:50`](../src/emo_eval/emo_eval.ml)) —
  the marker on the shipped `Exception` class, category A.
- The backends' local `builtin` emitters that handle A only:
  [`emo_beam.ml:695`](../src/emo_codegen/emo_beam.ml),
  [`emo_wasm.ml:647`](../src/emo_codegen/emo_wasm.ml),
  [`emo_riscv.ml:467-470`](../src/emo_codegen/emo_riscv.ml).
- [`lsp_completion.ml:63`](../src/emo_lsp/lsp_completion.ml)
  `builtin_type_items` — the capability types and `R`/`Exception`, all A.
  Its sibling `builtin_function_items` is a different story; see below.

## Rejected: one neutral name for the mechanism

The first proposal was to rename the shared carrier once, to a word that
belongs to neither population. Every candidate either collides with an
established term or states something false:

| Candidate | Occurrences in `src/` | Why not |
| --- | --- | --- |
| `runtime` | 319 | Already the module and file name — `Emo_runtime`, `emo_c_runtime.c`, `ts_runtime.ts`, `emo_ocaml_runtime.ml`. `RuntimeFn` reads as "a function of `Emo_runtime`", but B's implementations are spread across all six targets. |
| `host` | 290 (+6 `Host`) | Already the host runtime and the hosted targets. And `riscv64` is freestanding — it has no host, yet the names exist there and are refused. |
| `native` | 215 (+14 `Native`) | Already the `ocaml` native target and native boxing. |
| `primitive` | 15 | All of them "primitive **types**" (the Map key types, the value shapes). `PrimitiveFn` would read as "a function over primitive values". |
| `intrinsic` | 0 | Unoccupied, but it is a third word for a mechanism whose two populations already have the right words. The defect was never that `builtin` is a bad name for A. |

## Rejected: a `package` field on the IR node

`RuntimeImpl { package; name; args }` was proposed, with `package` derived
from the prefix (`os_read` → `os`), and justified as "able to express that
a package does not declare the target". Both halves fail:

- **It has no source.** The AST carries `Ast.Ident "os_read"` and nothing
  else; the package association exists only as the string prefix. Such a
  field is the same string re-spelled as two fields, with a re-join
  invariant that no code checks.
- **The target gate already exists, elsewhere.** It is
  `pick_version` in [`emo_pkg.ml:375-389`](../src/emo_pkg/emo_pkg.ml),
  which filters a package's manifest `targets` and reports `no build for
  target \`%s\`` at dependency resolution. An IR field would not reach it.

If a package ever needs to be first-class for error messages, the place is
`emo_pkg`'s `targets` table, not the IR.

## A defect the split exposes

[`lsp_completion.ml:88`](../src/emo_lsp/lsp_completion.ml),
`builtin_function_items`, offers **nine `net_*` names** to the user as
completions — `net_connect`, `net_listen`, `net_resolve`, `net_udp_bind`,
`net_connect_unix`, `net_listen_unix`, `net_tls_connect`,
`net_tls_connect_insecure`, `net_listen_tls`. These are category B: the
runtime's implementation of the `net` package, reachable without
`require`, never an API, and not what the user is supposed to type.

This is a pre-existing bug, not a consequence of renaming, but the split
is what makes it visible: once B is its own population, a user-facing
completion list offering B is plainly wrong. The fix belongs with the
rename — drop them from the list, or gate them on the completion context
being inside the `net` package's own source.

The second, smaller item: [`emo_riscv.ml:471`](../src/emo_codegen/emo_riscv.ml)
refuses every non-`println`/`halt` name as ``the `%s` builtin``, which is
the wrong term for the 31 B names. After the split each population gets
its own refusal wording.

## Scope and verification

- `src/`: 18 files carry a builtin-flavoured identifier. The split touches
  the IR, the evaluator, the checker's root environment, and the match in
  each of the six backends — the OCaml exhaustiveness check is the safety
  net, since a new IR variant makes every unhandled `match` a compile
  error rather than a silent fallthrough.
- The rename itself is mechanical: `BuiltinFn` 46 occurrences, `Builtin`
  30, the bare word `builtin` 40, `apply_builtin` 5, `call_builtin` 3,
  `emo_dynamic_builtin` 5, `emit_io_builtin` 4, `emit_builtin` 3,
  `is_builtin` 3.
- Two user-visible diagnostics change wording
  ([`emo_riscv.ml:471`](../src/emo_codegen/emo_riscv.ml),
  [`ts_runtime.ts:1888`](../src/emo_codegen/ts/ts_runtime.ts) and
  [`:2352`](../src/emo_codegen/ts/ts_runtime.ts)); three test names carry
  the word ([`emo_eval_test.ml:424`](../test/emo_eval/emo_eval_test.ml),
  `:583`, [`emo_check_test.ml:1608`](../test/emo_check/emo_check_test.ml)).
- `examples/*/.emo-build` and `test/*/.emo-build` are gitignored build
  output (nothing tracked); they regenerate on the next build.
- Verification: `dune build @fmt` and `dune test`.
- Order: `emo_ir` and `emo_eval` first, compiled green, then the checker,
  then the six backends, then the LSP fix.

## Open

- **Are `expect_*` category A?** They are classified as A above: bare
  names, reserved, registered in the root frame, documented in
  `docs/intro/testing.md`, and raising the language's one `Exception`
  class. The alternative reading is that they are a test-framework
  facility like a stdlib package. The classification decides whether they
  keep the `builtin` spelling or move to the runtime-implementation side —
  it does not change any of the carriers above, only the predicate's
  membership list.
