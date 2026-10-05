# Step 20 — Wasm runtime: the decoder and validator

**Milestone:** M6 · **Prereq:** step 19 · **Status:** not started

The task list is written when the step starts, per `plan/README.md`. The
boundaries below are decided now, because step 20 is where they first
bite — and they are the whole answer to "why does a wasm runtime live in
a language repository".

## Boundaries carried in from step 19

These bind the runtime ladder as a whole (steps 20 and 21, and the
kernel path that shares the layer), not just this step.

**The package is the boundary.** `runtime/wasm/` is an Emo package with
its own `package.emo`; everything it offers crosses that deps edge and
nothing else. It never imports compiler internals — no file under
`src/`, no dune library, no reaching into the wasm writer's ABI or the
codegen's runtime indices — and the dependency never runs the other way:
the compiler does not depend on the runtime. Where the two must meet
(the self-hosting test, below), the coupling lives in the test, which
depends on both.

**Spec data is not on the default test path.** The vendored spec suite
is large and changes rarely, and a language change has no reason to
re-run it. It lives with the package under `runtime/wasm/testdata/`; a
dedicated alias runs it (the Emo-written runtime executing the suite),
while the default `dune test` runs only a small smoke subset. Wiring
that smoke subset in is the first task of this step — until then the
package is inert, and step 19's claim that "the build has something to
check" is not yet true.

**The split is scheduled, not open-ended.** The runtime leaves this
repository when it passes the vendored spec subset and Emo reaches 1.0.
On the split, the language repository keeps a conformance/integration
test that pins a released runtime version, and the runtime gets its own
release cadence and issue tracker. The self-hosting test is the exit
sign that keeps the two in one place until then: the acceptance is
running Emo's own `--target wasm` goldens inside the Emo-written
runtime. Until the split, every primitive the runtime asks for still
goes through step 19's unification gate — the runtime is a consumer that
justifies a primitive, never an argument that skips the gate.
