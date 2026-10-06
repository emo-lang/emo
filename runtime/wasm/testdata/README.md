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
