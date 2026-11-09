# Benchmark results

Recorded 2026-11-09T00:32:28Z by benchmarks/run.sh (native builds via `emo build`).
Baselines do the same work with `cc -O3` and plain `ocamlopt`.
The wasm rows run under Node's WasmGC — module execution only, node's own startup and the compile excluded (benchmarks/wasm_driver.mjs).

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, specialized build | 18 |
| fib(30) | ms per run, unspecialized build | 29 |
| fib(30) | ms per run, c target (emo build --target c) | 26 |
| fib(30) | ms per run, interpreter (emo run) | 980 |
| fib(30) | ms per run, plain OCaml baseline | 9 |
| fib(30) | ms per run, wasm target (Node WasmGC) | 38 |
| tail loop 10M | ms per run, specialized build | 2023 |
| tail loop 10M | ms per run, unspecialized build | 376 |
| tail loop 10M | ms per run, c target (emo build --target c) | 37 |
| tail loop 10M | ms per run, interpreter (emo run) | 6237 |
| tail loop 10M | ms per run, plain OCaml baseline | 11 |
| tail loop 10M | ms per run, C baseline | 3 |
| tail loop 10M | ms per run, wasm target (Node WasmGC) | 178 |
| plain loop 10M | ms per run, ocaml target (dynamic by construction) | 87 |
| plain loop 10M | ms per run, c target (emo build --target c) | 27 |
| plain loop 10M | ms per run, interpreter (emo run) | 2630 |
| plain loop 10M | ms per run, wasm target (Node WasmGC) | 141 |
| ffi sqrt 10M | ms per run, dynamic foreign calls | 512 |
| ffi sqrt 10M | ms per run, c target (direct C ABI) | 49 |
| ffi sqrt 10M | ms per run, C baseline | 49 |
| bytes get 20M | ms per run, dynamic Bytes.get | 1138 |
| bytes get 20M | ms per run, c target (emo build --target c) | 138 |
| bytes get 20M | ms per run, plain OCaml baseline | 31 |
| bytes get 20M | ms per run, C baseline | 15 |
| bytes get 20M | ms per run, wasm target (Node WasmGC) | 470 |
| ping-pong 40k msgs | wall ms | 2546 |
| json-ish scan | wall ms | 7 |
| json-ish scan | wall ms, c target | 4 |
| json-ish scan | wall ms, wasm target (Node WasmGC) | 0 |
| http echo | req/s (200 requests in 2238ms) | 89 |
| http echo | req/s, c target (200 requests in 2349ms) | 85 |

