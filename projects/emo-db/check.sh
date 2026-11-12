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

# --- the binding type-checks ---------------------------------------------

( cd rocksdb && "$EMO" check rocksdb.emo ) >"$OUT/binding.log" 2>&1 &&
  rc=0 || rc=$?
expect 0 "the binding type-checks" "$rc"

# --- the registry: the package as a consumer sees it ----------------------
#
# The directory is named for the sources' content, so a run can never
# serve a module the package no longer has.

sum=$(cat rocksdb/package.emo rocksdb/rocksdb.emo rocksdb/internal/*.emo \
  rocksdb/emo_rocksdb_shim.c | cksum | awk '{print $1}')
REG=$PWD/.emo-build/registry-$sum
mkdir -p "$REG/emo/rocksdb/0.1.0/internal"
cp rocksdb/package.emo rocksdb/rocksdb.emo "$REG/emo/rocksdb/0.1.0/"
cp rocksdb/internal/*.emo "$REG/emo/rocksdb/0.1.0/internal/"
cp rocksdb/emo_rocksdb_shim.c "$REG/emo/rocksdb/0.1.0/"

# The demo's lock is committed. A missing one is a package change that
# skipped `emo deps resolve`, not something the gate should paper over.
if [ ! -f kv_demo/package.lock ]; then
  echo "check.sh: kv_demo/package.lock is missing — run" >&2
  echo "  (cd kv_demo && EMO_REGISTRY=$REG \"$EMO\" deps resolve)" >&2
  exit 1
fi

# --- build and run the KV golden -----------------------------------------

( cd kv_demo && EMO_REGISTRY="$REG" "$EMO" build main.emo -o "$OUT/kv_demo" ) \
  >"$OUT/build.log" 2>&1 && rc=0 || rc=$?
expect 0 "the KV demo builds on c" "$rc"

run=1
while [ "$run" -le 3 ]; do
  ( cd kv_demo && "$OUT/kv_demo" ) >"$OUT/run-$run.txt" 2>&1 && rc=0 || rc=$?
  expect 0 "run $run exits 0" "$rc"
  expect_same_file kv_demo/expected.txt "$OUT/run-$run.txt" \
    "run $run is byte-identical"
  run=$((run + 1))
done

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
