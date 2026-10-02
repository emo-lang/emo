# Benchmark results

Recorded by `benchmarks/run.sh` (native builds via `emo build`).
Re-run the script to refresh this file.

Latest run: 2026-10-02T11:16:50Z

| benchmark | metric | value |
| --- | --- | --- |
| fib(30) | ms per run, unspecialized build | 345 |
| fib(30) | ms per run, specialized build | 212 |
| ping-pong 40k msgs | wall ms | 2440 |
| json-ish scan | wall ms | 57 |
| http echo | req/s (200 requests in 1774ms) | 112 |

The fib pair demonstrates Stage B: the same fully annotated program
compiles to unboxed native arithmetic with direct calls (specialized)
or keeps tagged values and runtime checks (unspecialized) — a ~1.6x
difference on fib(30).
