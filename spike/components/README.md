# Components spike: one Emo source, two GUI platforms

The third GUI spike. The first proved a macOS window is reachable;
the second measured how much binding layer a C toolkit needs. This one
builds the actual architecture: **a React/Elm-style component model,
written once in Emo, painting through AppKit on macOS and GTK 4 on
Linux — zero compiler changes.**

## Run

```sh
./build-mac.sh                      # macOS, AppKit under the hood
./build-gtk.sh                      # Linux container (Docker), GTK 4
EMO_GUI_AUTOTEST=1 ./ui-app         # self-driving: +1, -1, +1, report,
                                    # quit — identical output on both
```

## The architecture

- **A component is a def.** `counter_label(count)`,
  `action_panel()`, `view(count)` — plain functions that return
  VNodes; nesting function calls builds the hierarchy. No new
  construct anywhere in the language for this.
- **The Elm loop lives in Emo.** `update(tag, model)` and
  `view(model)` are pure; the shim's only job is to hold the model
  scalar, fire `app__on_event(tag, model)` on a click, and keep the
  returned scalar for the next event. Everything else — the update,
  the re-render, the repaint — happens in Emo.
- **Styling is a Map per node.** `Map.new(("gap", 28.0),
  ("padding", 24.0))` — a map has no element order, so two style
  declarations never depend on each other (the explicit opposite of
  SwiftUI's chained modifiers, where `.bold().red()` and
  `.red().bold()` can diverge). Precedence comes only from the
  hierarchy: the resolved style of a node is the parent's map
  overlaid by the child's, so a nested panel's `gap: 8` overrides the
  root's `gap: 28` and everything else flows down — the CSS cascade.
  The demo shows both spacings on screen at once.
- **Layout is computed in Emo.** A vertical-column walk turns the
  VNode tree into positioned Draw commands (padding, gap, per-kind
  default heights, overridable `width`/`height` keys); the shims only
  place pixels. One layout engine, identical pixels on both
  platforms.
- **The per-platform delta is a ~100-line painter.** Both shims
  implement the same nine-verb `ui_*` contract (`window_make`,
  `label_make`, `button_make`, `place`, `clear`, `connect`, `root`,
  `run`, `autotest_arm`). Repaint is a full rebuild — `clear` plus
  re-place — because `view` is pure; reconciliation is a later
  milestone.

## Language findings along the way

1. **Local cross-module calls are refused on the c target.** The
   natural architecture — a shared `app.emo` plus two thin entry
   files — dies at check time: `ui.show(n)` through a module alias
   lowers to a type-level method and refuses ("the c target does not
   support the type-level method ... yet"), on both one- and
   two-segment paths, while the same shape works on the ocaml target
   (`examples/shop`) and package `require`s work everywhere
   (`xml_demo`). That refusal is what forced the neutral-vocabulary
   shape: one self-contained Emo file, the platform difference pushed
   into C. A general-purpose Emo UI package will need either the
   alias-call fix or the package path.
2. **Recursive types need the xml package's shape.** A class cannot
   name itself in its own `init` (E4005), and an interface cannot
   name itself in a signature. The working shape is interface
   `VNode` (uniform accessors) + `VControl`/`VColumn` concretes, with
   `children Array[VNode]` living on the container and `is()`
   narrowing at the walk.
3. **Recursion is the only loop.** No `while`/`for` — the layout walk
   recurses, and accumulating results threads an `Array[Draw]`
   through returns (a `Laid` result class bundling commands and
   cursor), because a def returns one value and a `Box.new([])`
   holds a dynamic array whose `.append` is not wired in the dynamic
   world ("message not understood: append/1" at run time).
4. **`Map.new` takes variadic pairs**, `Map.new()` for empty — an
   array of tuples is refused at check time (E4009).
5. ARC's `__bridge` hops, Linux `int64_t`=`long`, and the
   two-pass-build dance all carry over from the earlier spikes; the
   neutral vocabulary also dissolves the defs-header-vs-library-headers
   TU conflict, because the defs header no longer names any GTK or
   AppKit symbol.

## Files

- `app.emo` — everything in Emo: vocabulary declarations, VNode,
  components, cascade, layout, paint, update/view/on_event.
- `shim_mac.m` / `shim_gtk.c` — the two painters, same contract.
- `build-mac.sh` / `build-gtk.sh` — two-pass builds (pass 1 writes
  `.emo-build/emo_defs.h`, which both shims compile against).
- `ui-gtk.png` / `ui-mac.png` — the same UI on both platforms.
