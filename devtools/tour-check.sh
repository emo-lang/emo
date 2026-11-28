#!/bin/sh
# tour-check — compile and run every ```emo run block of a Markdown tour.
#
#   tour-check.sh [--keep] [--filter ID] [--emit-dir DIR] FILE...
#   tour-check.sh --pair EN.md ZH.md
#
# Each run block becomes its own temporary project:
#
#   package.emo   targets = ["wasm"], deps from the block's deps= attribute
#   main.emo      the block body
#
# The block is built with `emo build --target wasm` and executed with the
# compiler's own host under Node, so the program's stdout is compared byte
# for byte with the block's ```output fence. `emo run --target wasm` is not
# used because it prints a "built ..." notice on stdout.
#
# The block grammar (see docs/tour/PLAN.md):
#
#   ```emo run id=name [deps=a,b] [timeout=seconds]
#   ...program...
#   ```
#   ```output
#   ...exact stdout...
#   ```
#
# Exit codes: 0 all pass; 1 a block failed; 2 a parse error; 3 a tool is
# missing or the host could not be built.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EMO=${EMO:-"$ROOT/_build/default/src/emo_cli/emo.exe"}
SEP='|'

KEEP=0
FILTER=""
EMIT=""
PAIR=0
FILES=""

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1 ;;
  --filter)
    [ $# -ge 2 ] || usage
    FILTER=$2
    shift
    ;;
  --emit-dir)
    [ $# -ge 2 ] || usage
    EMIT=$2
    shift
    ;;
  --pair)
    PAIR=1
    shift
    while [ $# -gt 0 ]; do
      FILES="$FILES $1"
      shift
    done
    break
    ;;
  -h | --help) usage ;;
  --*) usage ;;
  *) FILES="$FILES $1" ;;
  esac
  shift
done

[ -n "$FILES" ] || usage

if [ ! -x "$EMO" ]; then
  echo "tour-check: no emo binary at $EMO (run: dune build src/emo_cli/emo.exe)" >&2
  exit 3
fi
if ! command -v node >/dev/null 2>&1; then
  echo "tour-check: node is not on PATH (the wasm target's host needs it)" >&2
  exit 3
fi
PERL=""
if command -v perl >/dev/null 2>&1; then
  PERL=$(command -v perl)
else
  echo "tour-check: perl is not on PATH; running without a timeout" >&2
fi

with_timeout() {
  secs=$1
  shift
  if [ -n "$PERL" ]; then
    "$PERL" -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else
    "$@"
  fi
}

# ---- the Markdown extractor ----
#
# Writes:
#   WORK/index.tsv       seq|kind|id|deps|timeout|line|has_expect
#   WORK/<seq>.code      the program (or the no-run block body)
#   WORK/<seq>.expect    the expected stdout, when has_expect is 1
extract() {
  src=$1
  work=$2
  mkdir -p "$work"
  awk -v WORK="$work" -v SRC="$src" -v SEP="$SEP" '
    function fail(msg) {
      printf "%s:%d: %s\n", SRC, NR, msg > "/dev/stderr"
      bad = 1
      exit 2
    }
    function ticks(s,   i) {
      i = 0
      while (substr(s, i + 1, 1) == "`") i++
      return i
    }
    function slug(s,   t) {
      t = tolower(s)
      gsub(/[^a-z0-9]+/, "-", t)
      gsub(/^-+/, "", t)
      gsub(/-+$/, "", t)
      if (t == "") t = "block"
      return t
    }
    function attr(tok, key,   eq) {
      eq = index(tok, "=")
      if (eq == 0) return ""
      if (substr(tok, 1, eq - 1) == key) return substr(tok, eq + 1)
      return ""
    }
    function setreq(line,   s) {
      if (match(line, /require[ \t]+"[^"]*"/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^require[ \t]+"/, "", s)
        sub(/"$/, "", s)
        req[s] = 1
      }
    }
    function add_dep(s,   n, a, i) {
      if (s == "") return
      n = split(s, a, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", a[i])
        if (a[i] != "") seen[a[i]] = 1
      }
    }
    function close_emo(   n, lines, d, msg, file) {
      n = split(code_all, lines, "\n")
      delete req
      delete seen
      for (i = 1; i <= n; i++) setreq(lines[i])
      add_dep(deps_of)
      for (d in req) {
        if (!(d in seen)) {
          msg = sprintf("block `%s`: require \"%s\" is missing from deps=", id, d)
          fail(msg)
        }
      }
      for (d in seen) {
        if (!(d in req)) {
          msg = sprintf("block `%s`: deps=%s is not required by the block", id, d)
          fail(msg)
        }
      }
      file = WORK "/" seq ".code"
      printf "%s", code_all > file
      kind_of[seq] = kind
      id_of[seq] = id
      deps_of_seq[seq] = deps_of
      timeout_of[seq] = timeout
      line_of[seq] = startline
      has_of[seq] = 0
      if (kind == "run") pending = seq
    }
    function close_output(   file) {
      file = WORK "/" output_seq ".expect"
      printf "%s", expect > file
      has_of[output_seq] = 1
      pending = 0
    }
    BEGIN {
      fence = 0
      cap = ""
      seq = 0
      pending = 0
      heading = "tour"
      bad = 0
    }
    {
      if (fence) {
        if (substr($0, 1, 1) == "`") {
          t = ticks($0)
          rest = substr($0, t + 1)
          if (t >= fence_ticks && rest ~ /^[ \t]*$/) {
            if (cap == "emo") close_emo()
            else if (cap == "output") close_output()
            fence = 0
            cap = ""
            next
          }
          fail("a code line starts with backticks inside a fence (close the fence first)")
        }
        if (cap == "emo") code_all = code_all $0 "\n"
        else if (cap == "output") expect = expect $0 "\n"
        next
      }

      if (pending) {
        if ($0 ~ /^[ \t]*$/) next
        if (substr($0, 1, 1) == "`") {
          t = ticks($0)
          info = substr($0, t + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", info)
          if (t >= 3 && info == "output") {
            fence = 1
            fence_ticks = t
            cap = "output"
            expect = ""
            output_seq = pending
            next
          }
        }
        pending = 0
      }

      if ($0 ~ /^#+[ \t]/) {
        heading = $0
        sub(/^#+[ \t]+/, "", heading)
        next
      }
      if (substr($0, 1, 1) != "`") next
      t = ticks($0)
      if (t < 3) next
      info = substr($0, t + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", info)
      n = split(info, tok, /[ \t]+/)
      lang = tok[1]

      if (lang == "emo") {
        if (n < 2) fail("an ```emo fence must say run or no-run")
        kind = tok[2]
        if (kind != "run" && kind != "no-run")
          fail("unknown block kind `" kind "` (expected run or no-run)")
        seq++
        id = ""
        deps_of = ""
        timeout = 10
        for (i = 3; i <= n; i++) {
          v = attr(tok[i], "id"); if (v != "") id = v
          v = attr(tok[i], "deps"); if (v != "") deps_of = v
          v = attr(tok[i], "timeout"); if (v != "") timeout = v
        }
        if (id == "") id = slug(heading) "-" seq
        if (id in ids) fail("duplicate block id `" id "`")
        ids[id] = 1
        startline = NR + 1
        code_all = ""
        fence = 1
        fence_ticks = t
        cap = "emo"
        next
      }
      if (lang == "output") fail("an ```output fence must follow an ```emo run block")
      fence = 1
      fence_ticks = t
      cap = "skip"
    }
    END {
      if (bad) exit 2
      if (fence) {
        printf "%s:%d: unclosed fence\n", SRC, NR > "/dev/stderr"
        exit 2
      }
      file = WORK "/index.tsv"
      printf "" > file
      for (i = 1; i <= seq; i++) {
        printf "%d%s%s%s%s%s%s%s%s%s%d%s%d\n", i, SEP, kind_of[i], SEP,
          id_of[i], SEP, deps_of_seq[i], SEP, timeout_of[i], SEP,
          line_of[i], SEP, has_of[i] > file
      }
    }
  ' "$src" || exit 2
}

# ---- running one block ----

run_block() {
  work=$1
  seq=$2
  id=$3
  deps=$4
  timeout=$5
  has=$6
  line=$7
  proj="$work/run-$seq"
  mkdir -p "$proj"

  {
    printf 'package {\n'
    printf '  name = "emo/tour/%s"\n' "$id"
    printf '  version = "0.1.0"\n'
    printf '  targets = ["wasm"]\n\n'
    printf '  deps {\n'
    if [ -n "$deps" ]; then
      printf '%s\n' "$deps" | tr ',' '\n' | while IFS= read -r d; do
        [ -n "$d" ] && printf '    "%s" = "0.1.0"\n' "$d"
      done
    fi
    printf '  }\n}\n'
  } >"$proj/package.emo"
  cp "$work/$seq.code" "$proj/main.emo"

  (cd "$proj" && with_timeout 60 "$EMO" build --target wasm -o prog main.emo) \
    >"$proj/build.out" 2>"$proj/build.err"
  bstat=$?
  if [ "$bstat" -ne 0 ]; then
    printf 'FAIL %s (line %s)\n' "$id" "$line"
    printf '  compile failed (exit %s)\n' "$bstat"
    sed "s|$proj|<tour>/$id|g" "$proj/build.err" | sed 's/^/  /'
    finish_block "$proj"
    return 1
  fi

  (cd "$proj" && with_timeout "$timeout" node "$HOST" prog.wasm) \
    >"$proj/out" 2>"$proj/err"
  rstat=$?
  if [ "$rstat" -ne 0 ]; then
    printf 'FAIL %s (line %s)\n' "$id" "$line"
    if [ "$rstat" -eq 142 ] || [ "$rstat" -eq 143 ]; then
      printf '  timed out after %ss\n' "$timeout"
    else
      printf '  exit %s\n' "$rstat"
    fi
    sed "s|$proj|<tour>/$id|g" "$proj/err" | sed 's/^/  /'
    finish_block "$proj"
    return 1
  fi

  if [ -s "$proj/err" ]; then
    printf 'FAIL %s (line %s)\n' "$id" "$line"
    printf '  stderr was not empty\n'
    sed "s|$proj|<tour>/$id|g" "$proj/err" | sed 's/^/  /'
    finish_block "$proj"
    return 1
  fi

  if [ "$has" = "1" ]; then
    if ! cmp -s "$proj/out" "$work/$seq.expect"; then
      printf 'FAIL %s (line %s)\n' "$id" "$line"
      printf '  stdout differs (expected vs actual)\n'
      diff -u "$work/$seq.expect" "$proj/out" 2>/dev/null |
        sed '1,2d' | sed "s|$proj/out|<tour>/$id/stdout|g" | sed 's/^/  /'
      finish_block "$proj"
      return 1
    fi
  elif [ -s "$proj/out" ]; then
    printf 'FAIL %s (line %s)\n' "$id" "$line"
    printf '  expected no output, got:\n'
    sed "s|$proj|<tour>/$id|g" "$proj/out" | sed 's/^/  /'
    finish_block "$proj"
    return 1
  fi

  if [ -n "$EMIT" ]; then
    mkdir -p "$EMIT"
    cp "$proj/prog.wasm" "$EMIT/$id.wasm"
    [ -f "$proj/prog.wat" ] && cp "$proj/prog.wat" "$EMIT/$id.wat"
  fi

  printf 'ok   %s\n' "$id"
  finish_block "$proj"
  return 0
}

finish_block() {
  if [ "$KEEP" -eq 1 ]; then
    :
  else
    rm -rf "$1"
  fi
}

# ---- main ----

WORK=$(mktemp -d "${TMPDIR:-/tmp}/emo-tour.XXXXXX") || exit 3
WORK=$(cd "$WORK" && pwd -P)

cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    echo "tour-check: kept $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT HUP INT TERM

# The compiler's wasm host rides the binary; `emo run` is the door that
# materializes it. One throwaway build pays for every block.
HOSTPROJ="$WORK/host"
mkdir -p "$HOSTPROJ"
printf 'package {\n  name = "emo/tour/host"\n  version = "0.1.0"\n  targets = ["wasm"]\n\n  deps {}\n}\n' \
  >"$HOSTPROJ/package.emo"
printf 'println("tour-host")\n' >"$HOSTPROJ/main.emo"
(cd "$HOSTPROJ" && "$EMO" run --target wasm main.emo) >/dev/null 2>"$WORK/host.err" || {
  echo "tour-check: could not build the wasm host" >&2
  sed 's/^/  /' "$WORK/host.err" >&2
  exit 3
}
HOST="$HOSTPROJ/.emo-build/emo_wasm_host.mjs"
if [ ! -f "$HOST" ]; then
  echo "tour-check: the compiler did not materialize its wasm host" >&2
  exit 3
fi

if [ "$PAIR" -eq 1 ]; then
  set -- $FILES
  [ $# -eq 2 ] || usage
  a=$1
  b=$2
  Ia="$WORK/pair-a"
  Ib="$WORK/pair-b"
  extract "$a" "$Ia" || exit 2
  extract "$b" "$Ib" || exit 2
  canon() {
    dir=$1
    while IFS="$SEP" read -r seq kind id deps timeout line has; do
      printf '=== %s %s %s %s\n' "$kind" "$id" "$deps" "$timeout"
      cat "$dir/$seq.code"
      if [ "$has" = "1" ]; then
        printf '%s\n' '--- output'
        cat "$dir/$seq.expect"
      fi
      printf '%s\n' '=== end'
    done <"$dir/index.tsv"
  }
  canon "$Ia" >"$WORK/a.txt"
  canon "$Ib" >"$WORK/b.txt"
  if cmp -s "$WORK/a.txt" "$WORK/b.txt"; then
    echo "pair ok   $a  $b"
    exit 0
  fi
  echo "pair FAIL $a  $b" >&2
  diff -u "$WORK/a.txt" "$WORK/b.txt" >&2
  exit 1
fi

total=0
skipped=0
passed=0
failed=0
index=0
for file in $FILES; do
  [ -f "$file" ] || {
    echo "tour-check: no such file: $file" >&2
    exit 2
  }
  index=$((index + 1))
  fw="$WORK/file-$index"
  extract "$file" "$fw"

  while IFS="$SEP" read -r seq kind id deps timeout line has; do
    [ -n "$seq" ] || continue
    if [ "$kind" = "no-run" ]; then
      skipped=$((skipped + 1))
      echo "skip $id (no-run)"
      continue
    fi
    if [ -n "$FILTER" ]; then
      case "$id" in
      *"$FILTER"*) ;;
      *) continue ;;
      esac
    fi
    total=$((total + 1))
    if run_block "$fw" "$seq" "$id" "$deps" "$timeout" "$has" "$line"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done <"$fw/index.tsv"
done

printf '%d blocks, %d ok, %d failed, %d skipped\n' "$total" "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ] || exit 1
