# The emo-ui decision check

Status: the blocking decision is **settled** (2026-10-10; the rule is
recorded in CHECK.md). This document is the gate checklist for turning
the GUI spikes into a real Emo UI package — what is already settled,
what the one blocking decision was and how it resolved, and what comes
after it. Evidence lives in the three spikes (`spike/macos-gui`,
`spike/gtk`, `spike/components`) and in the compiler fixes they drove.

## What the spikes settled

1. **Reachability.** A native window with working callbacks is
   reachable today: AppKit through a vocabulary shim on macOS
   (`spike/macos-gui`), GTK 4 largely through direct `foreign def`
   calls on Linux (`spike/gtk` — its shim is one third the size,
   because a C toolkit needs no vocabulary at all).
2. **The component model.** `spike/components` runs one React/Elm-style
   application — defs as components, the update/view loop in Emo,
   styles as per-node Maps with a child-overrides-parent cascade,
   layout computed in Emo — byte-identically through AppKit and GTK 4
   behind a nine-verb `ui_*` shim contract.
3. **Compiler fixes the spikes drove** (all on `develop`, 2026-10-10):
   `Void` foreign returns on the c target, `.emo-build/emo_defs.h`
   shim declarations, content-keyed build caches, and local
   cross-module **calls** on the c target (an entry-module alias
   binding lowered its value side into garbage C).

## The blocking decision: cross-module types — settled

The component model wants to be two modules — a UI library (`ui.emo`:
VNode, cascade, layout, paint) and an application (`app.emo`:
components, update, view). The call legs work since the fix above;
the type legs did not. The split was attempted for real and died at
check time:

- `def view(count Int64) VNode` in the application module → **E4005
  ("unknown type `VNode`")**: the checker's classes/interfaces/enums
  tables are built per module (`check_module_typed`, emo_check.ml) and
  nothing pre-registers another module's type declarations.
- Dropping the annotation is no escape: unannotated defs infer Void,
  and a def returning a value then reports **E4016**. The two errors
  deadlock; the split reverted.

### The decision: Option A — program-wide type pre-registration

**Settled (2026-10-10).** Every module's classes, interfaces, and
enums register before any module is checked
(`Emo_check.preregister_types`); names stay unqualified and are
program-unique — a name's second declaration is a loud E4021 naming
both modules, because the emitters key class tables and `is()` vtables
by the bare name, so the uniqueness rule makes an existing emitter
assumption checkable rather than adding a new one. The rule is
recorded in CHECK.md.

The split now checks and runs: `def view(count Int64) VNode` resolves
across the boundary, `is()` narrows to the library's carriers, and
method dispatch on the results produces identical output through the
interpreter and the `c` target. Direct construction joined them the
same day: `Point.new(...)` builds another module's class and bare enum
members answer, identically through the interpreter, `c`, `ocaml`, and
`typescript`. Package types resolve for their consumers too (the `xml`
package's element accessors moved onto its interface, whose signatures
now name `Xml` itself), and an interface signature may name its own
interface inside a checked program.

Option B (module-qualified names, collision-free composition) can
layer later if real collisions appear.

## After the decision: the emo-ui package checklist

In dependency order, each gate with its evidence:

1. **Cross-module types — landed (2026-10-10).** The decision above:
   program-wide pre-registration is in the checker, the rule is in
   CHECK.md, and the ui/app split is its regression test. Unlocked:
   the ui/app split, shared component libraries, the package itself.
2. **Memory reclamation** — the c target's bump allocator never frees
   (self-documented in `emo_c_runtime.c`); a minutes-long demo cannot
   measure a days-long app. The reclamation decision is already
   recorded as open in CHECK.md; GUI is the consumer that makes it
   non-optional.
3. **First-class callbacks** — today a C callback re-enters Emo
   through a fixed extern name with state threaded through its
   signature (the spikes' pattern). Blocks crossing the FFI (E4200)
   plus the existing `emo_closure_fn` convention would let components
   take handlers as values.
4. **Rendering depth** — full repaint per event is fine at demo
   scale; reconciliation, style-key validation (today style maps are
   stringly Float64 pairs), and struct marshaling for toolkit-native
   layouts are the growth path after the package exists.

## What is deliberately out

No packaging/app-store story, no concurrency story for UI threads,
and no commitment to which toolkit the first package targets — the
nine-verb contract is toolkit-agnostic by construction, and that is
all this document assumes.
