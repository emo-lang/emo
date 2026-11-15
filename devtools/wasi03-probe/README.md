# The WASI 0.3 probe

`probe.wat` is the hand-written component the step-81 probe campaign
(`plan/step-81-wasi03.md`) ended on: a guest core module running the
full stdout stream protocol against `wasi:cli/stdout@0.3.0`, then
`exit-with-code(42)`. `run.sh` assembles it and runs it under wasmtime,
asserting `hello` on stdout and exit code 42.

## What the campaign established

| # | Fact | Evidence |
| --- | --- | --- |
| 1 | wasmtime 49.0.1 runs a WASI 0.3 command component exporting `wasi:cli/run@0.3.0` | the probe exits 0/42 as written |
| 2 | An `async func`-typed export can be canon-lifted with the sync ABI — `run: async func() -> result` rides `(canon lift ...)` with no async option, the type carrying `(func async (result (result)))` | wit-component generates exactly this shape; wasmtime accepts it |
| 3 | The bare WIT `result` is its own type definition (`(result)`), referenced by index inside function types | an inline `(result)` in a param slot silently shifts the inner type indices |
| 4 | `use` splits an interface into two instance imports: `wasi:cli/types@0.3.0` (the enum) and `wasi:cli/stdout@0.3.0` (which aliases the outer type and re-exports it `(eq ...)`) | a self-contained enum inside the stdout instance is rejected by wasmtime's world matching ("instance not valid to be used as import") |
| 5 | `canon lower` needs the `memory` option only when the lowered function touches linear memory; a handle-to-handle function lowers bare | wit-component's own output for `write-via-stream` (i32 → i32) carries no memory option |
| 6 | `stream.new` answers one packed `i64` — the low 32 bits the readable end, the high 32 the writable end | swapping the halves fails with "handle is not a readable end of a stream" |
| 7 | Sync `stream.write` completes only as the host consumes; with no reader it never returns | the readerless variant hung until killed |
| 8 | Passing a stream handle into `write-via-stream` transfers it — the host drains and drops the readable end; the guest must not `stream.drop-readable` | dropping it after the call fails with "handle is not a stream" |
| 9 | The sync stream builtins (`stream.write`, `future.read`, …) are gated behind wasmtime's `-W component-model-more-async-builtins=y` | the ungated run refuses at parse ("synchronous `stream.write` requires the component model more async builtins feature") |
| 10 | `wasi:cli/exit@0.3.0`'s `exit-with-code(status-code: u8)` sync-lowers to `(param i32)` and propagates through wasmtime's exit status | the probe exits 42 |

## What T81.5 added (the filesystem/random/environment campaign)

| # | Fact | Evidence |
| --- | --- | --- |
| 11 | The component valtype has no inline handle form — own/borrow are deftypes (`0x69`/`0x68` + resource idx) declared inside the instance type and referenced by index | a `0x68`-spliced param fails parse ("invalid leading byte") |
| 12 | A variant case carries a trailing zero byte; the fs error-code is a **variant** (not an enum) and wasmtime's host carries **37 cases** — the 36 normative plus `other(option<string>)`; fewer cases fails the linker case-by-case ("expected variant case named …, found …") | the incremental probes over case counts |
| 13 | The fs instance's named types (error-code, path-flags, open-flags, descriptor-flags, descriptor-type, directory-entry) all need `(eq)` exports for the host's world match | the bare-decl instance fails "instance not valid to be used as import"; the all-exports instance passes |
| 14 | `get-directories`/`get-random-bytes`/`get-environment`/`get-arguments`/`get-initial-cwd` sync-lower to `(retptr)→()` with **realloc**; the realloc cannot reference a guest export, so it lives in the pre-instantiated provider | wit-component's own output carries `(realloc …)` on exactly these lowers |
| 15 | `wasmtime run -S cli` is required for the p3 CLI host (env/argv/filesystem); without it the imports link but the lists answer empty | the argv/env probes with and without `-S cli` |
| 16 | The descriptor is a `(sub resource)` export; resource definitions are rejected inside instance types | wit-component's encoding; the hand probe |

## The validated stdout protocol

```
packed = stream.new()                    ; i64: low = readable, high = writable
future  = write-via-stream(readable)     ; sync-lowered; ownership transfers
stream.write(writable, ptr, len)         ; sync (gated); completes as the host consumes
stream.drop-writable(writable)           ; EOF — the future resolves
future.drop-readable(future)             ; guest cleanup
; never drop-readable(readable) — the host consumed it
```

## Provenance

- wasmtime 49.0.1 (`~/.wasmtime`), the execution oracle.
- wasm-tools 1.263.0 as the development-time reference (component
  composition, WAT assembly, printing) — a self-contained binary under
  `/Users/daqing/protected/tmp/wasm-tools-ref/`, not a build
  dependency; `run.sh` takes `WASM_TOOLS`.
- The normative WIT: `WebAssembly/WASI` `proposals/cli/wit/` (the
  package is `wasi:cli@0.3.2` on main; the encoder pins the `0.3.0`
  version strings the probe validated).
