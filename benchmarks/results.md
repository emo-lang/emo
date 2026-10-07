# Benchmark results

Recorded 2026-10-07T08:00:18Z by benchmarks/run.sh (native builds via `emo build`).
Baselines do the same work with `cc -O3` and plain `ocamlopt`.

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, specialized build | 18 |
| fib(30) | ms per run, unspecialized build | 34 |
| fib(30) | ms per run, c target (emo build --target c) | 7 |
| fib(30) | ms per run, interpreter (emo run) | 938 |
| fib(30) | ms per run, plain OCaml baseline | 7 |
| tail loop 10M | ms per run, specialized build | 1967 |
| tail loop 10M | ms per run, unspecialized build | 417 |
| tail loop 10M | ms per run, c target (emo build --target c) | 4 |
| tail loop 10M | ms per run, interpreter (emo run) | 6064 |
| tail loop 10M | ms per run, plain OCaml baseline | 14 |
| tail loop 10M | ms per run, C baseline | 3 |
| ffi sqrt 10M | ms per run, dynamic foreign calls | 446 |
| ffi sqrt 10M | ms per run, c target (direct C ABI) | 46 |
| ffi sqrt 10M | ms per run, C baseline | 45 |
| bytes get 20M | ms per run, dynamic Bytes.get | 1130 |
| bytes get 20M | ms per run, c target (emo build --target c) | 43 |
| bytes get 20M | ms per run, plain OCaml baseline | 33 |
| bytes get 20M | ms per run, C baseline | 16 |
| ping-pong 40k msgs | wall ms | 2752 |
| json-ish scan | wall ms | 9 |
| json-ish scan | wall ms, c target | 3 |
| http echo | req/s (200 requests in 2878ms) | 69 |
| http echo | req/s, c target (200 requests in 2380ms) | 83 |

