# Benchmark results

Recorded 2026-10-06T06:50:25Z by benchmarks/run.sh (native builds via `emo build`).
Baselines do the same work with `cc -O3` and plain `ocamlopt`.

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, specialized build | 17 |
| fib(30) | ms per run, unspecialized build | 35 |
| fib(30) | ms per run, interpreter (emo run) | 910 |
| fib(30) | ms per run, plain OCaml baseline | 6 |
| tail loop 10M | ms per run, specialized build | 1670 |
| tail loop 10M | ms per run, unspecialized build | 392 |
| tail loop 10M | ms per run, interpreter (emo run) | 5774 |
| tail loop 10M | ms per run, plain OCaml baseline | 14 |
| tail loop 10M | ms per run, C baseline | 3 |
| ffi sqrt 10M | ms per run, dynamic foreign calls | 428 |
| ffi sqrt 10M | ms per run, C baseline | 45 |
| bytes get 20M | ms per run, dynamic Bytes.get | 1012 |
| bytes get 20M | ms per run, plain OCaml baseline | 30 |
| bytes get 20M | ms per run, C baseline | 15 |
| ping-pong 40k msgs | wall ms | 2442 |
| json-ish scan | wall ms | 6 |
| http echo | req/s (200 requests in 2047ms) | 97 |

