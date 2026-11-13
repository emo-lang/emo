#!/bin/sh
# Runs emo-db's benchmark set on the c target and writes
# bench/results.md. The method is the repository benchmarks' own: one
# warmup run, then the mean of three timed runs, wall clock, the mean
# in milliseconds per run.
#
# Usage: ./bench/run.sh    (from projects/emo-db, after ./check.sh has
# staged the registry; EMO and EMO_REGISTRY may override the defaults)
set -e
cd "$(dirname "$0")/.."
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac
REG=${EMO_REGISTRY:-$(ls -dt "$PWD"/.emo-build/registry-* 2>/dev/null | head -1)}
if [ -z "$REG" ] || [ ! -d "$REG" ]; then
  echo "bench/run.sh: no staged registry — run ./check.sh first" >&2
  exit 1
fi
mkdir -p .emo-build/bench
BENCH=$PWD/.emo-build/bench/bench
( cd bench && EMO_REGISTRY="$REG" "$EMO" build main.emo -o "$BENCH" ) \
  >/dev/null 2>&1
DB=$PWD/.emo-build/bench-db

ms_per_run() {
  python3 - "$@" <<'PY'
import subprocess, sys, time
cmd = sys.argv[1:]
subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL)
start = time.perf_counter()
runs = 3
for _ in range(runs):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
print(int((time.perf_counter() - start) * 1000 / runs))
PY
}

echo "running: insert-autocommit 200" >&2
insert_auto=$(ms_per_run "$BENCH" insert-autocommit "$DB" 200)
echo "running: insert-batch 10000" >&2
insert_batch=$(ms_per_run "$BENCH" insert-batch "$DB" 10000)
echo "running: seed 10000" >&2
"$BENCH" seed "$DB" 10000 >/dev/null
echo "running: lookup 10000" >&2
lookup=$(ms_per_run "$BENCH" lookup "$DB" 10000 10000)
echo "running: scan 10000" >&2
scan=$(ms_per_run "$BENCH" scan "$DB")
echo "running: seed 10000" >&2
"$BENCH" seed "$DB" 10000 >/dev/null
echo "running: update 200" >&2
update=$(ms_per_run "$BENCH" update "$DB" 200 10000)
echo "running: column-seed 10000" >&2
"$BENCH" column-seed "$DB" 10000 >/dev/null
echo "running: column-scan 10000" >&2
column_scan=$(ms_per_run "$BENCH" column-scan "$DB")
echo "running: column-agg 10000" >&2
column_agg=$(ms_per_run "$BENCH" column-agg "$DB")

rate() {
  awk -v n="$1" -v ms="$2" 'BEGIN { if (ms > 0) printf "%.0f", n * 1000 / ms; else printf "-" }'
}

DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MACHINE=$(uname -sm)
OUT=$PWD/bench/results.md
{
  echo "# emo-db benchmark results"
  echo
  echo "Recorded ${DATE} by \`bench/run.sh\` on ${MACHINE}, c target."
  echo "Method: one warmup plus three timed runs, wall clock, the mean in"
  echo "milliseconds per run; the database is recreated by the insert modes"
  echo "and reseeded before the read modes. Only measured numbers appear."
  echo
  echo "| workload | size | ms per run | per second |"
  echo "| --- | --- | ---: | ---: |"
  echo "| INSERT, autocommit | 200 rows, one transaction each | ${insert_auto} | $(rate 200 "$insert_auto") inserts |"
  echo "| INSERT, one transaction | 10000 rows, one COMMIT | ${insert_batch} | $(rate 10000 "$insert_batch") inserts |"
  echo "| primary-key lookup | 10000 lookups over 10000 rows | ${lookup} | $(rate 10000 "$lookup") lookups |"
  echo "| full table scan | 10000 rows, one SELECT | ${scan} | $(rate 10000 "$scan") rows |"
  echo "| UPDATE, autocommit | 200 rows by primary key | ${update} | $(rate 200 "$update") updates |"
  echo "| column-store scan | 10000 rows, one SELECT | ${column_scan} | $(rate 10000 "$column_scan") rows |"
  echo "| column-store aggregate | count(*), sum(id), avg(score) over 10000 rows | ${column_agg} | $(rate 10000 "$column_agg") rows |"
} >"$OUT"
cat "$OUT"
