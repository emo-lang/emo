#!/bin/sh
# Runs the benchmark set against the compiled binaries and records the
# numbers in benchmarks/results.md.
#
# Usage: benchmarks/run.sh   (from the repository root; requires a built
# emo toolchain — `dune build` — plus curl, cc, and ocamlfind)
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

EMO="$ROOT/_build/default/src/emo_cli/emo.exe"
REGISTRY="$ROOT/stdlib/registry"
RESULTS="$ROOT/benchmarks/results.md"
BLD="$ROOT/benchmarks/baselines/build"
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# build <dir> [extra emo-build flags...] — the content cache skips recompiles.
build() {
    dir=$1
    shift
    (cd "benchmarks/$dir" && EMO_REGISTRY="$REGISTRY" \
        "$EMO" build main.emo -o "$ROOT/benchmarks/$dir/main.emo-bin" "$@" \
        > /dev/null)
}

# build_nospec <dir> — same program, specialization off.
build_nospec() {
    dir=$1
    (cd "benchmarks/$dir" && EMO_REGISTRY="$REGISTRY" \
        "$EMO" build main.emo --no-specialize \
        -o "$ROOT/benchmarks/$dir/main.emo-bin-nospec" > /dev/null)
}

# time_ms <command...> — milliseconds per run over 3 timed runs (one
# warmup, excluded). A single python process does the timing, so python's
# own startup is not charged to short benchmarks.
time_ms() {
    python3 - "$@" <<'PY'
import subprocess, sys, time
cmd = sys.argv[1:]
run = lambda: subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run()  # warmup
runs = 3
t = time.perf_counter()
for _ in range(runs):
    run()
print(int((time.perf_counter() - t) * 1000 / runs))
PY
}

# interp_ms <dir> — interpreter time, ms per run over 3 timed runs (one
# warmup, excluded).
interp_ms() {
    python3 - "$EMO" "$REGISTRY" "benchmarks/$1" <<'PY'
import os, subprocess, sys, time
emo, registry, cwd = sys.argv[1:4]
env = dict(os.environ, EMO_REGISTRY=registry)
cmd = [emo, "run", "main.emo"]
run = lambda: subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run()  # warmup
runs = 3
t = time.perf_counter()
for _ in range(runs):
    run()
print(int((time.perf_counter() - t) * 1000 / runs))
PY
}

row() {
    printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$RESULTS"
}

# --- reference baselines: the same work in C and plain OCaml ---
mkdir -p "$BLD"
cc -O3 benchmarks/baselines/tail_loop.c  -o "$BLD/tail_loop_c"
cc -O3 benchmarks/baselines/sqrt_loop.c  -o "$BLD/sqrt_loop_c" -lm
cc -O3 benchmarks/baselines/bytes_scan.c -o "$BLD/bytes_scan_c"
for src in tail_loop fib bytes_scan; do
    cp "benchmarks/baselines/$src.ml" "$BLD/$src.ml"
    (cd "$BLD" && ocamlfind ocamlopt "$src.ml" -o "${src}_ml" > /dev/null)
done

echo "# Benchmark results" > "$RESULTS"
echo "" >> "$RESULTS"
echo "Recorded $DATE by benchmarks/run.sh (native builds via \`emo build\`)." >> "$RESULTS"
echo "Baselines do the same work with \`cc -O3\` and plain \`ocamlopt\`." >> "$RESULTS"
echo "" >> "$RESULTS"
echo "| benchmark | metric | value |" >> "$RESULTS"
echo "| --- | --- | --- |" >> "$RESULTS"

# --- fib(30): specialization on vs off, plus the plain-OCaml baseline ---
build fib
build_nospec fib
row "fib(30)" "ms per run, specialized build" "$(time_ms "$ROOT/benchmarks/fib/main.emo-bin")"
row "fib(30)" "ms per run, unspecialized build" "$(time_ms "$ROOT/benchmarks/fib/main.emo-bin-nospec")"
row "fib(30)" "ms per run, interpreter (emo run)" "$(interp_ms fib)"
row "fib(30)" "ms per run, plain OCaml baseline" "$(time_ms "$BLD/fib_ml")"

# --- tail-recursive loop: the language's only iteration idiom ---
build loops_tail
build_nospec loops_tail
row "tail loop 10M" "ms per run, specialized build" "$(time_ms "$ROOT/benchmarks/loops_tail/main.emo-bin")"
row "tail loop 10M" "ms per run, unspecialized build" "$(time_ms "$ROOT/benchmarks/loops_tail/main.emo-bin-nospec")"
row "tail loop 10M" "ms per run, interpreter (emo run)" "$(interp_ms loops_tail)"
row "tail loop 10M" "ms per run, plain OCaml baseline" "$(time_ms "$BLD/tail_loop_ml")"
row "tail loop 10M" "ms per run, C baseline" "$(time_ms "$BLD/tail_loop_c")"

# --- foreign call overhead: 10M C sqrt calls through `foreign def` ---
build ffi_call --cclib m
row "ffi sqrt 10M" "ms per run, dynamic foreign calls" "$(time_ms "$ROOT/benchmarks/ffi_call/main.emo-bin")"
row "ffi sqrt 10M" "ms per run, C baseline" "$(time_ms "$BLD/sqrt_loop_c")"

# --- Bytes read throughput: 20M bounds-checked reads ---
build bytes_scan
row "bytes get 20M" "ms per run, dynamic Bytes.get" "$(time_ms "$ROOT/benchmarks/bytes_scan/main.emo-bin")"
row "bytes get 20M" "ms per run, plain OCaml baseline" "$(time_ms "$BLD/bytes_scan_ml")"
row "bytes get 20M" "ms per run, C baseline" "$(time_ms "$BLD/bytes_scan_c")"

# --- ping-pong: 40k messages between processes ---
build ping_pong
row "ping-pong 40k msgs" "wall ms" "$(time_ms "$ROOT/benchmarks/ping_pong/main.emo-bin")"

# --- json-ish scan ---
build json_parse
row "json-ish scan" "wall ms" "$(time_ms "$ROOT/benchmarks/json_parse/main.emo-bin")"

# --- http echo: requests per second over loopback ---
build http_echo
"$ROOT/benchmarks/http_echo/main.emo-bin" > /tmp/emo-bench-port &
SERVER=$!
sleep 1
port=$(cat /tmp/emo-bench-port)
reqs=200
http_start=$(python3 -c 'import time; print(time.time_ns())')
i=0
while [ $i -lt $reqs ]; do
    curl -s "http://127.0.0.1:$port/" > /dev/null
    i=$((i + 1))
done
http_end=$(python3 -c 'import time; print(time.time_ns())')
http_ms=$(( (http_end - http_start) / 1000000 ))
rps=$(( reqs * 1000 / (http_ms + 1) ))
kill $SERVER 2>/dev/null || true
row "http echo" "req/s ($reqs requests in ${http_ms}ms)" "$rps"

echo "" >> "$RESULTS"
echo "Recorded into $RESULTS" >&2
