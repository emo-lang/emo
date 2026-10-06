# Benchmark results

Recorded 2026-10-06T15:39:08Z by benchmarks/run.sh (native builds via `emo build`).
Baselines do the same work with `cc -O3` and plain `ocamlopt`.

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, specialized build | 20 |
| fib(30) | ms per run, unspecialized build | 35 |
| fib(30) | ms per run, interpreter (emo run) | 941 |
| fib(30) | ms per run, plain OCaml baseline | 10 |
| tail loop 10M | ms per run, specialized build | 1910 |
| tail loop 10M | ms per run, unspecialized build | 419 |
| tail loop 10M | ms per run, c target (emo build --target c) | 4 |
| tail loop 10M | ms per run, interpreter (emo run) | 5935 |
| tail loop 10M | ms per run, plain OCaml baseline | 15 |
| tail loop 10M | ms per run, C baseline | 3 |
| ffi sqrt 10M | ms per run, dynamic foreign calls | 442 |
| ffi sqrt 10M | ms per run, C baseline | 45 |
| bytes get 20M | ms per run, dynamic Bytes.get | 1092 |
| bytes get 20M | ms per run, plain OCaml baseline | 31 |
| bytes get 20M | ms per run, C baseline | 15 |
| ping-pong 40k msgs | wall ms | 2628 |
| json-ish scan | wall ms | 10 |
| http echo | req/s (200 requests in 2111ms) | 94 |

