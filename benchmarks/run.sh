#!/bin/sh
# Runs the benchmark set against the compiled binaries and records the
# numbers in benchmarks/results.md.
#
# Usage: benchmarks/run.sh   (from the repository root; requires a
# built emo toolchain — `dune build` — and curl on PATH)
set -e
cd "$(dirname "$0")/.."

EMO=./_build/default/src/emo_cli/emo.exe
RESULTS=benchmarks/results.md
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

build() {
    # build <dir> — compile once; the content cache skips recompiles.
    (cd "benchmarks/$1" && EMO_REGISTRY="$(cd ../../stdlib/registry && pwd)" \
        "$OLDPWD/$EMO" build main.emo -o "$OLDPWD/benchmarks/$1/main.emo-bin" \
        > /dev/null)
}

time_runs() {
    # time_runs <binary> — milliseconds for 3 runs, per-run
    start=$(python3 -c 'import time; print(time.time_ns())')
    i=0
    while [ $i -lt 3 ]; do
        "$1" > /dev/null
        i=$((i + 1))
    done
    end=$(python3 -c 'import time; print(time.time_ns())')
    echo $(( (end - start) / 3000000 ))
}

echo "# Benchmark results" > "$RESULTS"
echo "" >> "$RESULTS"
echo "Recorded $DATE by benchmarks/run.sh (native builds via \`emo build\`)." >> "$RESULTS"
echo "" >> "$RESULTS"
echo "| benchmark | metric | value |" >> "$RESULTS"
echo "| --- | --- | --- |" >> "$RESULTS"

build fib
# The unspecialized build: same program, specialization off.
(cd benchmarks/fib && EMO_REGISTRY="$(cd ../../stdlib/registry && pwd)" \
    "$OLDPWD/$EMO" build main.emo --no-specialize \
    -o "$OLDPWD/benchmarks/fib/main.emo-bin-nospec" > /dev/null)

# fib(30): specialized build vs unspecialized build, ms per run.
fib_dyn_ms=$(time_runs benchmarks/fib/main.emo-bin-nospec)
fib_typ_ms=$(time_runs benchmarks/fib/main.emo-bin)
echo "| fib(30) | ms per run, unspecialized build | $fib_dyn_ms |" >> "$RESULTS"
echo "| fib(30) | ms per run, specialized build | $fib_typ_ms |" >> "$RESULTS"

build ping_pong
pp_start=$(python3 -c 'import time; print(time.time_ns())')
benchmarks/ping_pong/main.emo-bin > /dev/null
pp_end=$(python3 -c 'import time; print(time.time_ns())')
pp_ms=$(( (pp_end - pp_start) / 1000000 ))
echo "| ping-pong 40k msgs | wall ms | $pp_ms |" >> "$RESULTS"

build json_parse
js_start=$(python3 -c 'import time; print(time.time_ns())')
benchmarks/json_parse/main.emo-bin > /dev/null
js_end=$(python3 -c 'import time; print(time.time_ns())')
js_ms=$(( (js_end - js_start) / 1000000 ))
echo "| json-ish scan | wall ms | $js_ms |" >> "$RESULTS"

# http echo: requests per second over loopback.
build http_echo
benchmarks/http_echo/main.emo-bin > /tmp/emo-bench-port &
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
echo "| http echo | req/s ($reqs requests in ${http_ms}ms) | $rps |" >> "$RESULTS"

# http echo: requests per second over loopback.
build http_echo
benchmarks/http_echo/main.emo-bin > /tmp/emo-bench-port &
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
echo "| http echo | req/s ($reqs requests in ${http_ms}ms) | $rps |" >> "$RESULTS"

echo "" >> "$RESULTS"
echo "Recorded into $RESULTS" >&2
