#!/bin/sh
# The ocaml target's emitted-code inventory: emit the golden corpus (the
# examples with an expected.txt) through the ocaml emitter and collect
# every host-module symbol the emitted sources reference. The result is
# the standalone ocaml runtime's contract, recorded in
# plan/step-26-target-independence.md (T26.2); re-run it after emitter
# changes to catch contract drift — any host module outside Emo_eval and
# Emo_runtime fails the run.
#
# Usage: ocaml-runtime-inventory.sh [path-to-emo]
set -e

emo=${1:-_build/default/src/emo_cli/emo.exe}
repo=$(cd "$(dirname "$0")/.." && pwd)
case $emo in
  /*) ;;
  *) emo=$repo/$emo ;;
esac

scratch=${TMPDIR:-/tmp}/emo-ocaml-inventory.$$
mkdir -p "$scratch"

for d in "$repo"/examples/*/; do
  [ -f "${d}expected.txt" ] || continue
  name=$(basename "$d")
  entry=main.emo
  [ -f "${d}main.emo" ] || entry=$(ls "$d"*.emo | head -1 | xargs basename)
  (cd "$d" && "$emo" build "$entry" --target ocaml -o "$scratch/$name" \
    >"$scratch/$name.build.log" 2>&1) || {
    echo "build failed: $name (see $scratch/$name.build.log)" >&2
    exit 1
  }
  # the emitter's source lands in the example's .emo-build; move it in
  mv "${d}.emo-build/main.ml" "$scratch/$name.main.ml"
done

refs=$(cat "$scratch"/*.main.ml | grep -hoE 'Emo_[A-Za-z_]+\.' | sort -u)
stray=$(printf '%s\n' "$refs" | grep -vE '^Emo_(eval|runtime)\.$' || true)
if [ -n "$stray" ]; then
  echo "host modules outside the runtime contract:" >&2
  printf '%s\n' "$stray" >&2
  exit 1
fi

printf '%s\n' "$refs" | sed 's/^Emo_eval\.$/eval module/; s/^Emo_runtime\.$/runtime module/'
cat "$scratch"/*.main.ml | grep -hoE 'Emo_eval\.[A-Za-z_][A-Za-z0-9_]*|Emo_runtime\.[A-Za-z_][A-Za-z0-9_]*' | sort | uniq -c | sort -rn
cat "$scratch"/*.main.ml | grep -hoE 'Emo_eval\.call_builtin "[A-Za-z_0-9]+"' | sort -u
echo "(emitted sources kept in $scratch)"
