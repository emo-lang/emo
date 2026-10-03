# Step 17 — BEAM Target (Core Erlang)

**Milestone:** M5 · **Prereq:** steps 01–16 · **Status:** in progress

## Goal

`emo build --target beam`: an Emo program compiles to Core Erlang text,
`erlc` assembles it to a `.beam`, and an `erl` runner executes it. The
fourth backend, and the first that maps Emo's process model onto a VM
that shares it natively.

## Probed facts (OTP 29, erts 17.1 — the pinned assembler)

- Module form: `module 'name' [exports]` + `attributes []`, defs
  `'f'/A = fun ...`, final `end`. File stem must match the module atom.
- **Every atom is quoted.**
- `do` sequences exactly two expressions — no comma, no `end`; nesting
  carries the rest.
- `fun` bodies are one expression; **no `end` on fun**; no bare
  parenthesized grouping (parens exist only as `arg_list`).
- `case` patterns are wrapped: `<Pat> when 'true' -> Body`; the guard
  is mandatory; `case` has `end`.
- Textual `receive` exists but has **no `end`** and a **mandatory
  after-clause**; the honest lowering is the compiler's own shape:
  `letrec 'recv$K'/0 = fun () -> let <Ok, Msg> =
  primop 'recv_peek_message'() in case Ok of ... end in apply ...` with
  `remove_message`/`recv_next`/`recv_wait_timeout('infinity')`.
- Binary literals are per-segment: `#{#<C>(8,1,'integer',['unsigned'|['big']])}#`.
- Remote calls `call 'mod':'fun'(a, b)`; locals `apply 'f'/A ()`;
  send `call 'erlang':'!'(P, Msg)`; no bare function application.

## Scope

### In

- **The emission target: Core Erlang text + `erlc` as assembler** (the
  native target's OCaml-toolchain precedent). Not direct `.beam`
  emission — the Code chunk is OTP-version-locked; the Core reader of
  the pinned OTP is the spec.
- **One BEAM module** per program, mangled atoms (the wasm target's
  single-artifact design); multi-module interop stays out.
- **The value model**: Int (masked i64 wrap-around — the interpreter's
  semantics, decided), Float, Bool (`true`/`false` atoms), Char
  (codepoint integer), String = **binary** (UTF-8 byte semantics; data
  never in atoms), Tuple, Array (tagged list — immutable, `append`
  copies), Enum (`{emo_enum, Name, Member}` atom pairs), instances
  (`{emo_inst, Class, #{field => Value}}` — map equality is Emo's
  content equality), Box = **holding process** (honest cross-process
  cells), closures = BEAM funs, Pid = BEAM pid, exceptions through
  `throw` + `try`/`catch`.
- **`==` anchored**: tagged comparisons via `=:=`-shaped structural
  equality on tagged values (int vs float never equal — the
  interpreter's rule).
- **Processes**: `do`/`<-`/`receive`/`halt`/`self_pid` map onto
  spawn/`!`/selective receive/process exit. The entry process runs
  pinit; its end is `erlang:halt(0)`.
- **Target plumbing**: `--target beam` through the CLI; the resolution
  gate reads `beam`; packages without it refuse (net/http stay
  native-only — a BEAM sockets story is a later decision).
- **Goldens under Node-free CI**: hello_world, fib; then objects,
  language_tour, shop, pipeline as the tasks land.

### Out

- Direct `.beam` binary emission.
- net/http on BEAM (gen_tcp) — its own decision, not bundled here.
- Specialization/unboxing; multi-module BEAM interop; FFI (`foreign
  def`) — recorded, not gated.
- Dialyzer/spec annotations in emitted code.

## Tasks

- [ ] **T17.1** — The backend skeleton: probes recorded (this file);
      `--target beam` plumbing; the Core Erlang emitter (module, defs,
      literals, call/apply, sequencing); hello_world golden under an
      `erl` runner.
- [x] **T17.2** — The value model and arithmetic: masked wrap-around
      Int, binary Strings with interpolation over strcat, tuples,
      arrays, enums, deep content equality; fib golden.
- [ ] **T17.3** — Classes/instances, Box holding processes, closures
      as funs, case patterns with guards; objects + language_tour
      goldens.
- [ ] **T17.4** — Processes (`do`/`<-`/`receive` via the primop
      dance), shop multi-module, pipeline golden; the CI `beam_examples`
      group and the resolution-gate test for `"beam"`.
