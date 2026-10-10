# The emo-ui decision check

Status: **decision open** (recorded 2026-10-10). This document is the
gate checklist for turning the GUI spikes into a real Emo UI package —
what is already settled, what the one blocking decision is, and what
comes after it. Evidence lives in the three spikes
(`spike/macos-gui`, `spike/gtk`, `spike/components`) and in the
compiler fixes they drove.

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

## The blocking decision: cross-module types

The component model wants to be two modules — a UI library (`ui.emo`:
VNode, cascade, layout, paint) and an application (`app.emo`:
components, update, view). The call legs work since the fix above;
the type legs do not. The split was attempted for real and died at
check time:

- `def view(count Int64) VNode` in the application module → **E4005
  ("unknown type `VNode`")**: the checker's classes/interfaces/enums
  tables are built per module (`check_module_typed`, emo_check.ml) and
  nothing pre-registers another module's type declarations.
- Dropping the annotation is no escape: unannotated defs infer Void,
  and a def returning a value then reports **E4016**. The two errors
  deadlock; the split reverted.

Today the only typed surface is inside one module. Registry packages
(`xml`) live with the same rule: consumers hold package types as
gradual (unchecked) values.

### Option A — program-wide type pre-registration

Collect every module's classes/interfaces/enums before checking any
module; names stay unqualified.

- Costs: a collection pass before the per-module checks, plus a
  program-unique-name rule (two modules declaring `Widget` must be a
  loud error — silent resolution would betray strictness).
- Unlocks: clean annotations everywhere (`def view(count Int64)
  VNode`), `is()` narrowing across modules, the smallest possible
  surface for library authors and consumers.

### Option B — module-qualified type names

Annotations spell the module path (`def view(count Int64)
ui.VNode`), resolved through the same alias machinery calls already
use.

- Costs: parser and type-name-resolver work, and the qualified name
  must normalize to the module-mangled class name through the IR,
  `is()` vtables, and both emitters — more layers than A.
- Unlocks: collision-free composition (two packages may both define
  `Widget`), explicit grep-able types at every use.

### Recommendation (proposal — not settled)

Option A first, with the loud collision error. It is the smaller
change, matches the strictness-first posture, and unblocks the emo-ui
package for any ecosystem whose type names are unique — which, at
package scale today, they are. Option B can layer later if real
collisions appear. Whichever is chosen, the rule should be settled in
CHECK.md before the emo-ui package starts.

## After the decision: the emo-ui package checklist

In dependency order, each gate with its evidence:

1. **Cross-module types** — the decision above. Unlocks: the ui/app
   split, shared component libraries, the package itself.
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
