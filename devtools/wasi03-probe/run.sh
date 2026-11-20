#!/bin/sh
# The WASI 0.3 probe: the validated minimal command component.
#
# probe.wat is the hand-written component the step-85 probe campaign
# ended on: a guest core module running the full stdout stream protocol
# (stream.new, write-via-stream, stream.write, drop-writable,
# future.drop-readable) and then exit-with-code(42). Running it proves
# the four load-bearing facts the encoder is built on (see
# plan/step-85-wasi03.md): wasmtime accepts the sync-lifted async run,
# the two-import shape the `use` split produces, the sync stream
# builtins under the more-async-builtins gate, and the exit channel.
#
# Requirements: the wasmtime CLI (46+) on PATH, and wasm-tools to
# assemble the component WAT (on PATH, or point WASM_TOOLS at it).
# wasm-tools is a development-time reference here, not a build
# dependency of the compiler.
set -e

WT="${WASM_TOOLS:-}"
if [ -z "$WT" ]; then
    if command -v wasm-tools >/dev/null 2>&1; then
        WT=wasm-tools
    else
        echo "wasi03-probe: wasm-tools not found (set WASM_TOOLS) — skipping" >&2
        exit 0
    fi
fi
if ! command -v wasmtime >/dev/null 2>&1; then
    echo "wasi03-probe: wasmtime not found on PATH — skipping" >&2
    exit 0
fi

DIR=$(CD=$(dirname "$0") && cd "$CD" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

"$WT" parse "$DIR/probe.wat" -o "$OUT/probe.component.wasm"

set +e
GOT=$(wasmtime run -W component-model-more-async-builtins=y \
    "$OUT/probe.component.wasm" 2>/dev/null)
CODE=$?
set -e
if [ "$GOT" = "hello" ] && [ "$CODE" = "42" ]; then
    echo "wasi03-probe: ok — stdout 'hello', exit 42"
else
    echo "wasi03-probe: FAILED — stdout '$GOT', exit $CODE (want 'hello', 42)" >&2
    exit 1
fi

# The clocks rung (T85.9): the two wasi:clocks@0.3.0 nows under the
# production flags. The exit code names the leg: 43 both answer, 41
# wall only, 42 mono only, 40 neither; stdout is the raw 12-byte
# instant record (s64 seconds, u32 nanoseconds) the probe dumps for
# the layout eyeball.
"$WT" parse "$DIR/clock_probe.wat" -o "$OUT/clock.component.wasm"

set +e
wasmtime run -S cli -W component-model-more-async-builtins=y \
    "$OUT/clock.component.wasm" > "$OUT/clock-record.bin" 2>/dev/null
CODE=$?
set -e
if [ "$CODE" = "43" ]; then
    echo "wasi03-probe: clocks ok — both nows answered; the instant record:" \
        "$(od -An -tx1 "$OUT/clock-record.bin" | tr -s ' \n' '  ')"
else
    echo "wasi03-probe: clocks FAILED — exit $CODE (want 43; 41 wall only," \
        "42 mono only, 40 neither)" >&2
    exit 1
fi
