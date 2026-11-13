#!/bin/sh
# The second-engine check: every example that carries a wasm golden is
# compiled to wasm and fed to `wasmtime compile`, whose cranelift
# pipeline validates every byte — the GC type hierarchy, the multi-value
# signatures, the block nesting — against a second independent
# implementation. Node executes the artifacts (the canonical host);
# wasmtime vouches for their shape.
#
# Usage: devtools/wasmtime-smoke.sh   (from the repository root; needs a
# built emo toolchain, Node, and the wasmtime CLI on PATH)
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

EMO="$ROOT/_build/default/src/emo_cli/emo.exe"
REGISTRY="$ROOT/stdlib/registry"
OUT="$ROOT/.emo-build/wasmtime-smoke"
mkdir -p "$OUT"

command -v wasmtime >/dev/null || { echo "wasmtime-smoke: the wasmtime CLI is not on PATH" >&2; exit 69; }

# The wasm golden list, mirrored from test/emo_cli/emo_cli_test.ml —
# the examples a wasm build promises to run.
GOLDENS="hello_world if_expr fib objects field_types length_method
language_tour shop pipeline function_group showcase bit_ops fixed_width
list array_builder map base64_demo csv_demo json_demo yaml_demo xml_demo
slog_demo sync_demo loops error_matching float_methods string_methods
math_demo math_trig math_inverse_trig branch_var builtin_names
to_string_render typed_calls typed_sigs typed_methods plot_demo png_demo
sql_demo sql_edge atomic_cell crypto_hash crypto_aead crypto_sign
crypto_ecdh file_read bufio_demo os_fs_demo rand_demo uuid_demo"

pass=0
fail=0
for name in $GOLDENS; do
    dir="$ROOT/examples/$name"
    [ -d "$dir" ] || { echo "MISSING  $name"; fail=$((fail + 1)); continue; }
    art="$OUT/$name"
    if (cd "$dir" && EMO_REGISTRY="$REGISTRY" "$EMO" build main.emo \
            --target wasm -o "$art" > /dev/null 2>&1) \
        && wasmtime compile "$art.wasm" -o "$OUT/$name.cwasm" 2> "$OUT/$name.validate.log"
    then
        pass=$((pass + 1))
        echo "ok       $name"
    else
        fail=$((fail + 1))
        echo "FAIL     $name"
        sed -n '1,5p' "$OUT/$name.validate.log" 2>/dev/null || true
    fi
done

echo "wasmtime-smoke: $pass validated, $fail failed"
[ "$fail" -eq 0 ]
