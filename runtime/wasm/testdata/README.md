# The vendored WebAssembly spec corpus

`cases.all.txt` holds the binary-form module cases of the official spec
suite; `cases.smoke.txt` is the representative subset the default
`dune test` runs. A case line is:

```
<file>.wast:<line> <ok|malformed|invalid|pending> <hex module bytes>
```

- **Upstream:** github.com/WebAssembly/spec, pinned at
  `3cbf75868f7ce301da14a1d2f643d1e8f34cdf00` (2023-06-01) — the newest
  revision the vendoring toolchain (wabt 1.0.42) parses cleanly across
  all of `test/core`; newer revisions use function-references syntax
  that wabt does not know yet. The target is the core spec's MVP
  instruction set, so the older pin is the honest bar.
- **Licence:** the upstream test suite is Apache License 2.0; these
  derived case lists carry the same licence.
- **Regeneration:** fetch the pinned revision, then, from the
  repository root:

  ```
  devtools/vendor-wasm-spec /path/to/spec runtime/wasm/testdata/cases.all.txt
  ```

  (`wast2json` from wabt must be on the path; the checkout itself is
  fetched by hand, once, and never committed.)
- **Pending cases:** every case is vendored `pending`; the decoder and
  validator tasks flip cases to their claimed verdict as the runtime
  grows the matching capability. The runner skips pending cases and
  prints their count, so the gap is visible on every run. Step 20 is
  done when nothing is pending.

## The run list (step 21)

`runs.all.txt` vendors the spec suite's *commands* — the interpreter's
corpus; `runs.smoke.txt` is the representative subset the default
`dune test` runs. A run line is

```
<file>.wast:<line> <verdict> <command> <payload...>
```

`<verdict>` is `pending` until a sweep claims it, then the expected
outcome: `ok`, `return`, `trap`, `uninstantiable`, or `unlinkable`.
`<command>` is one of:

```
module <hex> <name-hex>            instantiate a binary module (its wast name, or `.`)
register <name-hex> <as-hex>       register a named instance under an import name
invoke <ref> <export-hex> [args]   call an exported function
get <ref> <export-hex>             read an exported global
```

Names are UTF-8 hex (export names in the suite contain spaces and
control bytes). `<ref>` is `.` for the last instantiated module or
`@<name-hex>` for a named one. An `invoke`/`get` carries its expected
values after `=`; a bare action or a trap has none. Value words are
`i:<u32>`, `I:<i64>`, `f:<u32 bits>`, `F:<i64 bits>` (all decimal, the
64-bit ones two's complement), `ref.null`, `ref.extern:<n>`,
`ref.func:<n>`, and the NaN classes `nan:canonical` / `nan:arithmetic`.

The `assert_malformed` / `assert_invalid` commands belong to the case
list, not this one; `assert_exhaustion` is out of scope (no host stack
limit is modelled).

- **Regeneration:** the same pinned checkout, then

  ```
  devtools/vendor-wasm-spec runs /path/to/spec runtime/wasm/testdata/runs.all.txt
  ```

- **Pending commands:** as with the case list, everything lands
  `pending`; the sweeps flip families to their verdicts
  (`devtools/vendor-wasm-spec runs-flip`). The runner skips pending
  commands and prints their count. Step 21 is done when nothing is
  pending and nothing fails.
