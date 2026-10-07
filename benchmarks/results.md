# Benchmark results

Recorded 2026-10-07T13:56:25Z by benchmarks/run.sh (native builds via `emo build`).
Baselines do the same work with `cc -O3` and plain `ocamlopt`.

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, specialized build | 18 |
| fib(30) | ms per run, unspecialized build | 29 |
| fib(30) | ms per run, c target (emo build --target c) | 6 |
| fib(30) | ms per run, interpreter (emo run) | 969 |
| fib(30) | ms per run, plain OCaml baseline | 7 |
| tail loop 10M | ms per run, specialized build | 2087 |
| tail loop 10M | ms per run, unspecialized build | 406 |
| tail loop 10M | ms per run, c target (emo build --target c) | 3 |
| tail loop 10M | ms per run, interpreter (emo run) | 6236 |
| tail loop 10M | ms per run, plain OCaml baseline | 10 |
| tail loop 10M | ms per run, C baseline | 3 |
| ffi sqrt 10M | ms per run, dynamic foreign calls | 422 |
| ffi sqrt 10M | ms per run, c target (direct C ABI) | 46 |
| ffi sqrt 10M | ms per run, C baseline | 44 |
| bytes get 20M | ms per run, dynamic Bytes.get | 1444 |
| bytes get 20M | ms per run, c target (emo build --target c) | 43 |
| bytes get 20M | ms per run, plain OCaml baseline | 32 |
| bytes get 20M | ms per run, C baseline | 14 |
| ping-pong 40k msgs | wall ms | 2665 |
| json-ish scan | wall ms | 6 |
| json-ish scan | wall ms, c target | 3 |
| http echo | req/s (200 requests in 2655ms) | 75 |
| http echo | req/s, c target (200 requests in 2562ms) | 78 |

