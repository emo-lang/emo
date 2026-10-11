# Benchmark results

Recorded 2026-10-11T14:56:57Z by benchmarks/run.sh (native builds via `emo build`).
Baselines do the same work with `cc -O3` and plain `ocamlopt`.

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, specialized build | 18 |
| fib(30) | ms per run, unspecialized build | 29 |
| fib(30) | ms per run, c target (emo build --target c) | 25 |
| fib(30) | ms per run, interpreter (emo run) | 930 |
| fib(30) | ms per run, plain OCaml baseline | 8 |
| tail loop 10M | ms per run, specialized build | 1903 |
| tail loop 10M | ms per run, unspecialized build | 400 |
| tail loop 10M | ms per run, c target (emo build --target c) | 36 |
| tail loop 10M | ms per run, interpreter (emo run) | 6211 |
| tail loop 10M | ms per run, plain OCaml baseline | 12 |
| tail loop 10M | ms per run, C baseline | 3 |
| plain loop 10M | ms per run, ocaml target (dynamic by construction) | 85 |
| plain loop 10M | ms per run, c target (emo build --target c) | 27 |
| plain loop 10M | ms per run, interpreter (emo run) | 2543 |
| ffi sqrt 10M | ms per run, dynamic foreign calls | 420 |
| ffi sqrt 10M | ms per run, c target (direct C ABI) | 46 |
| ffi sqrt 10M | ms per run, C baseline | 46 |
| bytes get 20M | ms per run, dynamic Bytes.get | 1453 |
| bytes get 20M | ms per run, c target (emo build --target c) | 138 |
| bytes get 20M | ms per run, plain OCaml baseline | 31 |
| bytes get 20M | ms per run, C baseline | 14 |
| ping-pong 40k msgs | wall ms | 2686 |
| json-ish scan | wall ms | 9 |
| json-ish scan | wall ms, c target | 3 |
| http echo | req/s (200 requests in 2411ms) | 82 |
| http echo | req/s, c target (200 requests in 2155ms) | 92 |

