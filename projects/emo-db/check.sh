#!/bin/sh
# emo-db's first gate (M28): the RocksDB binding and its KV golden.
#
#   ./check.sh
#
# The gate builds the demo against the binding through a staged
# registry, runs it three times and byte-compares every run with
# expected.txt, and pins the two refusals the package's shape owes:
# the interpreter refuses the foreign calls (E3009), and a non-c target
# refuses the package at resolution (E5007). RocksDB is a build
# dependency, not an optional service — a machine without it fails
# here with the install line rather than skipping the gate.
#
# Usage: ./check.sh

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac
STAGE=$(cd "$(dirname "$0")/../.." && pwd)/scripts/stage-registry.sh

mkdir -p .emo-build/check
OUT=$PWD/.emo-build/check
fail=0

expect() {
  if [ "$1" = "$3" ]; then
    printf 'ok   %s\n' "$2"
  else
    printf 'FAIL %s: expected [%s], got [%s]\n' "$2" "$1" "$3" >&2
    fail=1
  fi
}

expect_same_file() {
  if cmp -s "$1" "$2"; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s: %s and %s differ\n' "$3" "$1" "$2" >&2
    diff "$1" "$2" >&2 || true
    fail=1
  fi
}

# --- RocksDB, through pkg-config -----------------------------------------
#
# The default path first, then Homebrew's keg (the postgres probe's
# escape). The winning path enters the environment, so the build's own
# pkg-config call resolves the same way.

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "check.sh: pkg-config is missing — install it and RocksDB." >&2
  exit 1
fi
if ! pkg-config --exists rocksdb 2>/dev/null; then
  for dir in /opt/homebrew/opt/rocksdb/lib/pkgconfig \
             /usr/local/opt/rocksdb/lib/pkgconfig; do
    if [ -d "$dir" ] && PKG_CONFIG_PATH="$dir" pkg-config --exists rocksdb; then
      export PKG_CONFIG_PATH="$dir"
      break
    fi
  done
fi
if ! pkg-config --exists rocksdb 2>/dev/null; then
  echo "check.sh: RocksDB is not resolvable through pkg-config." >&2
  echo "  macOS: brew install rocksdb" >&2
  echo "  Debian/Ubuntu: sudo apt install librocksdb-dev" >&2
  exit 1
fi
if ! echo 'int main(void){return 0;}' |
  cc -x c - $(pkg-config --cflags --libs rocksdb) -o /dev/null 2>/dev/null; then
  echo "check.sh: RocksDB's headers and library do not link." >&2
  exit 1
fi

# --- psql and libpq, the wire phase's optional counterparties ------------
#
# The wire itself needs only RocksDB; psql is the interactive proof and
# libpq the standard client's proof. A machine without either skips the
# matching phase rather than failing the gate. libpq resolution takes
# the Homebrew kegs the postgres probe uses, appended to any path the
# RocksDB probe set.

PSQL=""
if command -v psql >/dev/null 2>&1; then
  PSQL=$(command -v psql)
fi

LIBPQ=0
if pkg-config --exists libpq 2>/dev/null; then
  LIBPQ=1
else
  for dir in /opt/homebrew/opt/postgresql@18/lib/postgresql/pkgconfig \
             /opt/homebrew/opt/libpq/lib/pkgconfig \
             /opt/homebrew/lib/postgresql@18/pkgconfig \
             /usr/local/opt/postgresql@18/lib/postgresql/pkgconfig \
             /usr/local/opt/libpq/lib/pkgconfig; do
    if [ -d "$dir" ] &&
      PKG_CONFIG_PATH="${dir}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        pkg-config --exists libpq 2>/dev/null; then
      export PKG_CONFIG_PATH="${dir}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      LIBPQ=1
      break
    fi
  done
fi

# --- the binding and the record layer type-check -------------------------

( cd rocksdb && "$EMO" check rocksdb.emo ) >"$OUT/binding.log" 2>&1 &&
  rc=0 || rc=$?
expect 0 "the binding type-checks" "$rc"

# --- the registry: the packages as a consumer sees them -------------------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has.

sum=$(cat rocksdb/package.emo rocksdb/rocksdb.emo rocksdb/internal/*.emo \
  rocksdb/emo_rocksdb_shim.c record/package.emo record/record.emo \
  record/internal/*.emo engine/package.emo engine/*.emo \
  wire/package.emo wire/*.emo \
  ../../stdlib/registry/sql/0.1.0/package.emo \
  ../../stdlib/registry/sql/0.1.0/sql.emo \
  ../../stdlib/registry/float/0.1.0/package.emo \
  ../../stdlib/registry/float/0.1.0/float.emo \
  ../../stdlib/registry/float/0.1.0/internal/*.emo \
  ../../stdlib/registry/net/0.1.0/package.emo \
  ../../stdlib/registry/net/0.1.0/net.emo \
  ../../stdlib/registry/os/0.1.0/package.emo \
  ../../stdlib/registry/os/0.1.0/os.emo \
  ../../stdlib/registry/file/0.1.0/package.emo \
  ../../stdlib/registry/file/0.1.0/file.emo \
  ../../stdlib/registry/postgres/0.1.0/package.emo \
  ../../stdlib/registry/postgres/0.1.0/postgres.emo \
  ../../stdlib/registry/postgres/0.1.0/internal/*.emo \
  ../../stdlib/registry/postgres/0.1.0/emo_postgres_shim.c |
  cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum
"$STAGE" "$REG"

( cd record && EMO_REGISTRY="$REG" "$EMO" check record.emo ) \
  >"$OUT/record.log" 2>&1 && rc=0 || rc=$?
expect 0 "the record layer type-checks" "$rc"

( cd engine && EMO_REGISTRY="$REG" "$EMO" check engine.emo ) \
  >"$OUT/engine.log" 2>&1 && rc=0 || rc=$?
expect 0 "the engine type-checks" "$rc"

( cd wire && EMO_REGISTRY="$REG" "$EMO" check wire.emo ) \
  >"$OUT/wire.log" 2>&1 && rc=0 || rc=$?
expect 0 "the wire type-checks" "$rc"

# The demos' locks are committed. A missing one is a package change that
# skipped `emo deps resolve`, not something the gate should paper over.
for lock in kv_demo/package.lock record_demo/package.lock \
            engine_demo/package.lock txn_demo/package.lock \
            corpus_runner/package.lock bench/package.lock \
            column_demo/package.lock htap_demo/package.lock \
            htap_client/package.lock \
            wire/package.lock wire_demo/package.lock \
            wire_client/package.lock; do
  if [ ! -f "$lock" ]; then
    echo "check.sh: $lock is missing — run" >&2
    echo "  (cd $(dirname "$lock") && EMO_REGISTRY=$REG \"$EMO\" deps resolve)" >&2
    exit 1
  fi
done

# --- build and run the KV golden -----------------------------------------

( cd kv_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo -o "$OUT/kv_demo" ) \
  >"$OUT/build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the KV demo builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

run=1
while [ "$run" -le 3 ]; do
  ( cd kv_demo && "$OUT/kv_demo" ) >"$OUT/run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "run $run exits 0" "$rc"
  expect_same_file kv_demo/expected.txt "$OUT/run-$run.txt" \
    "run $run is byte-identical"
  run=$((run + 1))
done

# --- build and run the record golden -------------------------------------

( cd record_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/record_demo" ) >"$OUT/record-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the record demo builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

run=1
while [ "$run" -le 3 ]; do
  ( cd record_demo && "$OUT/record_demo" ) \
    >"$OUT/record-run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "record run $run exits 0" "$rc"
  expect_same_file record_demo/expected.txt "$OUT/record-run-$run.txt" \
    "record run $run is byte-identical"
  run=$((run + 1))
done

# --- build and run the engine golden --------------------------------------

( cd engine_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/engine_demo" ) >"$OUT/engine-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the engine demo builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

run=1
while [ "$run" -le 3 ]; do
  ( cd engine_demo && "$OUT/engine_demo" ) \
    >"$OUT/engine-run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "engine run $run exits 0" "$rc"
  expect_same_file engine_demo/expected.txt "$OUT/engine-run-$run.txt" \
    "engine run $run is byte-identical"
  run=$((run + 1))
done

# --- build and run the transaction golden ---------------------------------

( cd txn_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/txn_demo" ) >"$OUT/txn-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the transaction demo builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

run=1
while [ "$run" -le 3 ]; do
  ( cd txn_demo && "$OUT/txn_demo" ) \
    >"$OUT/txn-run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "txn run $run exits 0" "$rc"
  expect_same_file txn_demo/expected.txt "$OUT/txn-run-$run.txt" \
    "txn run $run is byte-identical"
  run=$((run + 1))
done

# --- build and run the SQL corpus -----------------------------------------
#
# The corpus is data: six files, one fresh database per run, the case
# expectations pinned as text. The runner prints one line per file and
# the total; three runs must agree byte for byte.

( cd corpus_runner && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/corpus_runner" ) >"$OUT/corpus-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the corpus runner builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

run=1
while [ "$run" -le 3 ]; do
  ( cd corpus_runner && "$OUT/corpus_runner" ../corpus/ddl.test \
      ../corpus/types.test ../corpus/dml.test ../corpus/select.test \
      ../corpus/column.test ../corpus/transactions.test \
      ../corpus/errors.test ) \
    >"$OUT/corpus-run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "corpus run $run exits 0" "$rc"
  expect_same_file corpus/expected.txt "$OUT/corpus-run-$run.txt" \
    "corpus run $run is byte-identical"
  run=$((run + 1))
done

# --- build and run the column-format golden -------------------------------

( cd column_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/column_demo" ) >"$OUT/column-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the column demo builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

run=1
while [ "$run" -le 3 ]; do
  ( cd column_demo && "$OUT/column_demo" ) \
    >"$OUT/column-run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "column run $run exits 0" "$rc"
  expect_same_file column_demo/expected.txt "$OUT/column-run-$run.txt" \
    "column run $run is byte-identical"
  run=$((run + 1))
done

# --- build and run the two-engine golden ----------------------------------
#
# One database, both storages: htap_demo seeds a row table and a column
# table (1100 rows, across the block boundary), then serves the wire.
# The psql phase and the client phase each get a fresh server, and each
# script updates the row table and inserts into the column table inside
# one BEGIN/COMMIT.

( cd htap_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/htap_demo" ) >"$OUT/htap-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the two-engine server builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

if [ "$LIBPQ" -eq 1 ]; then
  ( cd htap_client && EMO_REGISTRY="$REG" "$EMO" build main.emo \
      -o "$OUT/htap_client" ) >"$OUT/htap-client-build.log" 2>&1 \
    && rc=0 || rc=$?
  expect 0 "the two-engine client builds on c" "$rc"
  if [ "$rc" -ne 0 ]; then exit 1; fi
fi

if [ -n "$PSQL" ]; then
  portfile="$OUT/htap-psql-port.txt"
  : >"$portfile"
  ( cd htap_demo && "$OUT/htap_demo" 0 1 "$portfile" ) \
    >"$OUT/htap-psql-server.log" 2>&1 &
  srv=$!
  tries=0
  while [ ! -s "$portfile" ] && [ "$tries" -lt 300 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ ! -s "$portfile" ]; then
    echo "check.sh: the two-engine phase's server wrote no port" >&2
    exit 1
  fi
  port=$(cat "$portfile")

  "$PSQL" "host=127.0.0.1 port=$port user=emo dbname=emo" -X -A -t \
    -c "select id, name, price from items; select count(*), sum(id), min(score), max(name) from cold_items; begin; update items set price = 11.0 where id = 1; insert into cold_items (id, name, score) values (1101, 'new', 4.0); commit; select id, price from items where id = 1; select count(*), sum(id) from cold_items" \
    >"$OUT/htap-psql.txt" 2>"$OUT/htap-psql.err" && rc=0 || rc=$?
  expect 0 "psql drives both engines" "$rc"
  expect_same_file htap_demo/psql_expected.txt "$OUT/htap-psql.txt" \
    "psql's two-engine script is byte-identical"

  wait "$srv" && rc=0 || rc=$?
  expect 0 "the two-engine server exits 0" "$rc"
  expect_same_file htap_demo/expected.txt "$OUT/htap-psql-server.log" \
    "the two-engine server's own output is stable"
else
  echo "skip two-engine psql: psql is not on PATH"
fi

if [ "$LIBPQ" -eq 1 ]; then
  portfile="$OUT/htap-client-port.txt"
  : >"$portfile"
  ( cd htap_demo && "$OUT/htap_demo" 0 1 "$portfile" ) \
    >"$OUT/htap-client-server.log" 2>&1 &
  srv=$!
  tries=0
  while [ ! -s "$portfile" ] && [ "$tries" -lt 300 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ ! -s "$portfile" ]; then
    echo "check.sh: the two-engine client phase's server wrote no port" >&2
    exit 1
  fi
  port=$(cat "$portfile")

  "$OUT/htap_client" "$port" >"$OUT/htap-client.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "the postgres client drives both engines" "$rc"
  expect_same_file htap_client/expected.txt "$OUT/htap-client.txt" \
    "the client's two-engine script is byte-identical"

  wait "$srv" && rc=0 || rc=$?
  expect 0 "the two-engine client server exits 0" "$rc"
  expect_same_file htap_demo/expected.txt "$OUT/htap-client-server.log" \
    "the two-engine client server's own output is stable"
else
  echo "skip two-engine client: libpq is not resolvable through pkg-config"
fi

# --- build the bench and smoke its counts ---------------------------------
#
# The bench's numbers are measured by bench/run.sh, never by the gate;
# the gate checks that every mode still runs and answers its count.

( cd bench && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/bench" ) >"$OUT/bench-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the bench builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

bench_db=$OUT/bench-smoke-db
( cd bench && "$OUT/bench" insert-autocommit "$bench_db" 25 &&
    "$OUT/bench" seed "$bench_db" 100 &&
    "$OUT/bench" lookup "$bench_db" 40 100 &&
    "$OUT/bench" scan "$bench_db" &&
    "$OUT/bench" update "$bench_db" 40 100 &&
    "$OUT/bench" insert-batch "$bench_db" 25 &&
    "$OUT/bench" column-seed "$bench_db" 25 &&
    "$OUT/bench" column-scan "$bench_db" &&
    "$OUT/bench" column-agg "$bench_db" ) \
  >"$OUT/bench-smoke.txt" 2>&1 && rc=0 || rc=$?
expect 0 "the bench modes run" "$rc"
expect_same_file bench/smoke_expected.txt "$OUT/bench-smoke.txt" \
  "the bench modes answer their counts"

# --- build and run the wire golden ---------------------------------------
#
# Phase A: a fresh server serves two psql connections — the script's
# multi-statement string (DDL, DML, a transaction, and a SELECT), then
# the error script, whose first SELECT answers, whose missing table
# answers ErrorResponse, and whose third statement must never run.
# Phase B: another fresh server serves the standard library's postgres
# client, which runs the same script through libpq's simple path.
# Both phases stop by the server's own max-connections count, so the
# gate never kills a process.

( cd wire_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo \
    -o "$OUT/wire_demo" ) >"$OUT/wire-demo-build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the wire server builds on c" "$rc"
if [ "$rc" -ne 0 ]; then exit 1; fi

if [ "$LIBPQ" -eq 1 ]; then
  ( cd wire_client && EMO_REGISTRY="$REG" "$EMO" build main.emo \
      -o "$OUT/wire_client" ) >"$OUT/wire-client-build.log" 2>&1 \
    && rc=0 || rc=$?
  expect 0 "the wire client builds on c" "$rc"
  if [ "$rc" -ne 0 ]; then exit 1; fi
fi

if [ -n "$PSQL" ]; then
  portfile="$OUT/psql-port.txt"
  : >"$portfile"
  ( cd wire_demo && "$OUT/wire_demo" 0 2 "$portfile" ) \
    >"$OUT/psql-server.log" 2>&1 &
  srv=$!
  tries=0
  while [ ! -s "$portfile" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ ! -s "$portfile" ]; then
    echo "check.sh: the psql phase's server wrote no port" >&2
    exit 1
  fi
  port=$(cat "$portfile")

  "$PSQL" "host=127.0.0.1 port=$port user=emo dbname=emo" -X -A -t \
    -c "create table items (id bigint not null primary key, name text not null, price double precision, active boolean, payload bytea); insert into items (id, name, price, active, payload) values (1, 'Ada', 9.5, true, null), (2, 'Grace', 3.25, false, null); select id, name, price, active, payload from items; begin; update items set price = 10.5 where id = 1; select id, price from items where id = 1; commit;" \
    >"$OUT/psql-run.txt" 2>"$OUT/psql-run.err" && rc=0 || rc=$?
  expect 0 "psql runs the script" "$rc"
  expect_same_file wire_demo/psql_expected.txt "$OUT/psql-run.txt" \
    "psql's rows and command tags are byte-identical"

  "$PSQL" "host=127.0.0.1 port=$port user=emo dbname=emo" -X -A -t \
    -c "select id from items where id = 1; select * from missing; select id from items where id = 2" \
    >"$OUT/psql-error.txt" 2>"$OUT/psql-error.err" && rc=0 || rc=$?
  expect 1 "psql exits 1 on the error" "$rc"
  expect_same_file wire_demo/psql_error_expected.txt "$OUT/psql-error.txt" \
    "the error stopped the rest of the string"
  expect_same_file wire_demo/psql_error_stderr.txt "$OUT/psql-error.err" \
    "the ErrorResponse carries the SQLSTATE's message"

  wait "$srv" && rc=0 || rc=$?
  expect 0 "the psql server exits 0" "$rc"
  expect_same_file wire_demo/expected.txt "$OUT/psql-server.log" \
    "the psql server's own output is stable"
else
  echo "skip psql: not on PATH"
fi

if [ "$LIBPQ" -eq 1 ]; then
  portfile="$OUT/client-port.txt"
  : >"$portfile"
  ( cd wire_demo && "$OUT/wire_demo" 0 1 "$portfile" ) \
    >"$OUT/client-server.log" 2>&1 &
  srv=$!
  tries=0
  while [ ! -s "$portfile" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ ! -s "$portfile" ]; then
    echo "check.sh: the client phase's server wrote no port" >&2
    exit 1
  fi
  port=$(cat "$portfile")

  "$OUT/wire_client" "$port" >"$OUT/client-run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "the postgres client runs the script" "$rc"
  expect_same_file wire_client/expected.txt "$OUT/client-run.txt" \
    "the client's rows, tags, and error are byte-identical"

  wait "$srv" && rc=0 || rc=$?
  expect 0 "the client server exits 0" "$rc"
  expect_same_file wire_demo/expected.txt "$OUT/client-server.log" \
    "the client server's own output is stable"
else
  echo "skip postgres client: libpq is not resolvable through pkg-config"
fi

# --- the refusals ---------------------------------------------------------

( cd kv_demo && EMO_REGISTRY="$REG" "$EMO" run main.emo ) \
  >"$OUT/run.log" 2>&1 && rc=0 || rc=$?
expect 70 "emo run refuses the foreign bindings" "$rc"
grep -q "E3009" "$OUT/run.log" && rc=0 || rc=$?
expect 0 "and names E3009" "$rc"

( cd kv_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo --target ocaml \
    -o "$OUT/ocaml" ) >"$OUT/ocaml.log" 2>&1 && rc=0 || rc=$?
expect 65 "a non-c target refuses the package at resolution" "$rc"
grep -q "does not declare the \`ocaml\` target" "$OUT/ocaml.log" &&
  rc=0 || rc=$?
expect 0 "and names the missing target" "$rc"

exit $fail
