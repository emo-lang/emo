# Reference baselines

Lower-bound reference points for the Emo microbenchmarks, compiled by
`benchmarks/run.sh` with `cc -O3` (C) and plain `ocamlopt` (OCaml). They
do the same work as the Emo cases so the results table has a ceiling to
compare against, not a claim that C and OCaml are the target's peers.

| baseline | pairs with | work |
| --- | --- | --- |
| `tail_loop.c` / `tail_loop.ml` | `benchmarks/loops_tail` | 10M-iteration counter |
| `sqrt_loop.c` | `benchmarks/ffi_call` | 10M `sqrt` calls |
| `bytes_scan.c` / `bytes_scan.ml` | `benchmarks/bytes_scan` | 20M buffer reads |
| `fib.ml` | `benchmarks/fib` | `fib(30)` |

The C counter is a `for` loop and the Emo one is tail recursion, because
recursion is Emo's only loop; the OCaml counter is tail recursion too.
Build artifacts land in `build/`, which is git-ignored.
