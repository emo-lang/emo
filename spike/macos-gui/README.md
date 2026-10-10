# macOS GUI spike

A feasibility spike: a native AppKit window whose every visible behavior
is Emo code, driven through a fixed C vocabulary shim — with **zero
compiler changes**. It exists to turn the FFI analysis into evidence:
what the current `foreign def` + C target can and cannot carry.

## Run

```sh
./build.sh                        # two-pass build (see below)
./gui-spike                       # the demo: click the button
EMO_GUI_AUTOTEST=1 ./gui-spike    # self-driving: one synthetic click,
                                  # prints the label, quits (exit 0)
```

Requires macOS with Xcode command-line tools. The interpreter refuses
foreign defs (E3009), so this is compiled-only by construction.

## What is in the box

- **`main.emo`** — all UI logic: window/button/label assembly with every
  layout number, the click behavior (counter arithmetic, message
  formatting, label update), and the vocabulary's foreign declarations.
- **`shim.m`** — the whole bridge, ~200 lines: three composite creators
  (the AppKit ceremony Emo cannot name: struct parameters, method
  chains, target wiring), five generic `objc_msgSend` shapes (selector
  named by string), one delegate that forwards clicks into Emo, and a
  self-driving autotest mode.
- **`build.sh`** — pass 1 runs `emo build` knowing it fails at link:
  it writes `.emo-build/emo_c_runtime.h`, which the shim compiles
  against; pass 2 links the shim object in with `--cclib`.

## Findings (2026-10-10)

The demo works end to end: Emo builds the UI, AppKit delivers the
event, the delegate calls `main__on_click`, Emo updates the label
through a foreign call, and the autotest reads the result back from
the real window. Every leg of the loop is exercised.

Gaps discovered on the way, all now evidence-backed:

1. **A foreign def could not return Void** (E4200) — every
   fire-and-forget call in the vocabulary carried a dummy `Int64`
   return. *Resolved 2026-10-10: Void returns are honored on the c
   target, and the vocabulary's fire-and-forget calls return Void.*
2. **The C target gives defs no reachable global storage.** A top-level
   `const` referenced inside a def lowers to a `Type_ref` (refused); a
   top-level `var` lowers to a `Global_var` expression (refused). There
   is nowhere for cross-callback state to live in Emo, so the state
   travels through the callback's signature: current count in, new
   count out, and the shim holds the slot.
3. **Entry-module defs are emitted module-qualified** — `main__on_click`,
   never bare `on_click`.
4. **`--cclib` passthrough rules**: only values starting with `-` or
   `/` pass verbatim (so the shim object must be `--cclib="$PWD/shim.o"`
   — a bare `shim.o` becomes `-lshim.o`), and cmdliner needs the `=`
   form for values starting with `-` (`--cclib="-framework AppKit"`).
   *Also 2026-10-10: a cclib naming an existing file enters the build's
   cache key by content, so editing the shim invalidates the cached
   binary instead of silently relinking it.*
5. **AppKit headers are Objective-C** — the shim compiles as `.m` (same
   clang, no extra tooling, but the "pure C bridge" idea dies on the
   headers, not the runtime API). ARC also requires `__bridge` hops for
   the Int64-handle convention.

Two compiler changes came out of the spike (2026-10-10): `Void` foreign
returns on the c target, and `.emo-build/emo_defs.h` — every externally
linkable declaration of the program, written by `emo build` so the shim
includes the compiler's own declarations instead of hand-writing
externs. Sabotaging a shim signature now fails at cc time with
`conflicting types` — verified here.

Unchanged blockers for product-grade GUI work (assessed before the
spike): the bump allocator never reclaims (fine for minutes, fatal for
days), callbacks are not first-class (no function pointers across the
FFI, state and handlers travel through fixed signatures), no struct or
variadic marshaling, and one C symbol cannot be declared under two
signatures (so every selector that does not fit the five generic
shapes needs its own shim function).

## Status

Spike only — not part of the toolchain, not committed. `emo` binary
path defaults to `../../_build/default/src/emo_cli/emo.exe`; override
with `EMO=...`.
