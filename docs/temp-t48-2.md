# T48.2 — the EmoUI Elm loop: what it ran into, and what it left open

**Status:** open. Nothing here blocks T48.2, which landed (`8dcdb4f`): the loop,
its fourteen assertions and the package gate are in `projects/emo-ui/`. What
follows is what the task ran into on the way, and what it deliberately did not
decide.
**Found:** 2026-10-15, working `plan/step-48-emo-ui.md` T48.2 (the Elm loop).

This is a working note, not design. Items 1 and 3 are compiler debt and are
recorded in `CHECK.md` as such; item 2 is the one decision the next tasks wait
on; the rest is method and bookkeeping.

## 1. The loop's spelling, not the loop, is what `c` and `wasm` refuse

`ui.run(view, update, model, backend)` takes the application's two functions as
`Block` values, and in Emo a bare def name is the only expression that produces
one. Two targets cannot compile that expression:

- `c` has no def-as-value at all — `the c target does not support this
  expression form (Global) yet`. Only class methods get a dynamic entry
  (`emit_thunk`, `src/emo_codegen/emo_c.ml:2834`).
- `wasm` refuses a dynamic call with more than one parameter — `wasm: only
  one-parameter closures are supported yet` (`src/emo_codegen/emo_wasm.ml:549-561`,
  `630-639`). A two-argument `update` reaches it immediately.

`projects/emo-ui/probe/def_shape/` is that shape in miniature and reaches both
refusals. `projects/emo-ui/probe/handler_shape/` is the same loop with the
application's two functions behind a `Handler` interface — no `Block`-valued
function anywhere, the calls ordinary interface dispatch, the model still
narrowed with `is()` exactly as a backend narrows a node — and it builds on all
five targets, printing what `emo run` prints on `c` and `ocaml`.

So the loop is portable; its *spelling* is not. The decision, recorded as open in
`CHECK.md`, `./check.sh` and both READMEs:

- **grow the two targets** — def-as-value on `c`, n-ary dynamic calls and
  n-parameter function values on `wasm`; or
- **move the application's `view`/`update` behind an interface** — which revises
  `docs/emo-ui.md` Layer 5, and costs the application a class wrapper it does not
  otherwise need.

That is the maintainer's call, and T48.4 onward (the first real backend, which
has to compile on a hosted target) waits on it. The gap has no task number yet.

## 2. Module-level bindings cannot hold the loop's state

`docs/emo-ui.md` Layer 5 sketches the event table as a module-level `ui.on(msg)`.
Three findings, each with a two-file repro, say it cannot be one — full text in
`CHECK.md:42`:

1. a non-entry module's `const` lowers to a zero-arg function, so **every read
   re-runs its initializer** (deliberate: "A const binding in a non-entry module
   becomes a zero-arg function other modules can call", `src/emo_ir/emo_ir.ml`),
   while the interpreter evaluates it once and keeps the value. A `const` whose
   initializer allocates hands out a fresh value per read on every compiled
   target, and does it silently — the identity is gone without a diagnostic.
2. a `const` in the *entry* module is no symbol at all: the pre-registration pass
   skips it (`when m.mpath <> input.entry`, `src/emo_ir/emo_ir.ml`), so a def
   reading it lowers to `Type_ref` — `c` refuses, and `ocaml` emits the type's
   *name*, so `const greeting = "hi"` with `println(greeting)` prints `greeting`
   where `emo run` prints `hi`.
3. a module-level `var` is `ocaml`-only, and the other three crash on it: `c`
   refuses with a diagnostic (`does not support module-level variable assignment
   yet`), and `typescript`, `wasm` and `beam` exit 125 with an escaping OCaml
   exception (`Failure("ts: module-level `var` is not supported")`,
   `src/emo_codegen/emo_ts.ml:332,371`, `emo_wasm.ml:350,1223`,
   `emo_beam.ml:139,1013`) instead of a refusal. That is a diagnostics bug
   independent of the missing capability.

This is why the tag table is the loop's own object (`ui.Registry`, handed to
`view`) rather than module-level state. Findings 1–3 are conformance-and-
diagnostics debt; none of them needs a language-surface decision, and finding 1
is the one that changes answers rather than refusing them.

## 3. A declared interface with no implementer cannot be built on `wasm` or `beam`

The `wasm` and `beam` emitters generate an interface call's dispatch arms from
the classes they see in the file set, and refuse when there are none:
`wasm: method mount has no static dispatch (in ui__run, self type: ui.Backend)`
(`src/emo_codegen/emo_wasm.ml:1055,1090`) and `beam: method patch has no
dispatch (in ui__App__deliver)` (`src/emo_codegen/emo_beam.ml:661`).

Two consequences. First, "build the library alone" is not a valid capability
probe on those two targets — the core's `Backend` has no implementer until a
program supplies one. Second, and conversely: the package builds on `beam`
*because* `test.emo` lives in it and supplies two `Backend` implementations; the
library builds there on the strength of its test, not on its own. Both the
`def_shape` refusal above and this one are reasons `./check.sh` pins per-target
results rather than asking `emo emoji build` once.

## 4. The package gate is all-or-nothing, and its test cannot live outside it

`walk` (`src/emo_project/emo_project.ml:104-120`) registers every `.emo` file
under the package root, and skips a subdirectory carrying its own `package.emo`
(`:110`). So:

- `emo build <entry>` and `emo emoji build` lower **every** module of the
  package, so one file's target gap decides the whole gate. That is what made
  `emo emoji build` red on `c` and `wasm` for T48.2 while the core alone was
  never the question — and what turned the gate from one command into a
  per-target table with each refusal pinned by its exact text.
- the test cannot be moved out to escape that: a subdirectory with its own
  manifest is excluded from the package and cannot see the parent's `ui` module,
  and there are no local-path dev deps.

Pending, non-blocking: a manifest field naming the package's test entry (or an
`exclude` list), or local-path dev deps. Neither is needed until a second package
(T48.4) lands; today the test lives inside the package and the gate is
`projects/emo-ui/check.sh`.

## 5. Probing a target is easy to get wrong — two readings had to be discarded

- **Siblings decide the answer.** One directory holding several probe variants
  answers for all of them at once: a variant that omitted `Backend`'s implementing
  class failed as `E4005 unknown type Backend` because of a file beside it, not
  because of its own content. Each probe has to be its own package directory with
  exactly one program in it — which is why `probe/def_shape/` and
  `probe/handler_shape/` are separate directories with their own `package.emo`.
  Two early readings of "what `c` refuses" were wrong for this reason and were
  discarded.
- **`emo build` answers from its cache.** It prints `(cached)` and reuses the
  product it has for that source, a new `-o` path included, and says nothing
  about what it actually compiled. Since the file under probe had just been
  edited, the trustworthy method was a copy of the tree in a fresh directory
  with a fresh output path; every per-target reading in `CHECK.md` and in both
  READMEs came from one.

Two smaller traps met while writing probes: `(m) { return m }` is not Emo's
closure syntax (`E4009 (Unknown) is not callable`, `E4003 m is not defined`) — a
probe has to use bare defs — and a class named `R` collides with the built-in
`R` enum (`E4023`).

## 6. The fourteen assertions are interpreter-verified only

`./check.sh` runs `test.emo` under `emo run`; the package does not build on `c`
or `wasm`, so no compiled target has run the loop's tests. Two things follow:

- the retained-versus-rebuild checks compare nodes with `==` (chain identity,
  `olds == [...]`); whether `==` on class instances means identity on each
  compiled target is unverified, and identity is exactly what the retained test
  asserts. When the loop compiles on `c`, run `test.emo` there and compare.
- `Registry.on` allocates a fresh tag per call, and `dispatch` on an unregistered
  tag is a hard error. Both are deliberate — a tag is an event's identity, and
  the loop must not drop one silently — but that second one is where the question
  will surface if a real backend ever has to drop events.

## 7. Bookkeeping

- **`docs/emo-ui-check.md`** (2026-10-10) is the pre-package gate checklist; the
  loop was a line in it, not a decision. Now that the gate is
  `projects/emo-ui/check.sh`, decide whether the older checklist is retired or
  rewritten.
- **`package.emo`'s `version`** stays `0.1.0` across T48.1 and T48.2. There is no
  per-task bump convention and no CHANGELOG in the project; if a landing task is
  meant to move the version, say so and it rides in the same commit.
- **The root `README.md`'s EmoUI section** still shows the old block-children
  tree spelling; revising it is T48.13, already in the plan.
- **T48.3's `debug` backend** will need what `test.emo`'s local `Recorder` and
  `Rebuild` backends do today (record the mount/patch sequence, print a node's
  label). When it lands, decide whether the test keeps its own recorders or runs
  against the real `debug` backend.
- **The full `dune test` suite was not re-run for T48.2**, because of the
  intermittent root stall recorded in `docs/temp-dune-test-problem.md`. What was
  run instead: `./check.sh` (five targets `ok`, exit 0, fourteen assertions),
  `dune build` (rc 0), and the per-target probe builds above. If a later bisect
  puts a failure at `8dcdb4f`, that gap is the first thing to check.
