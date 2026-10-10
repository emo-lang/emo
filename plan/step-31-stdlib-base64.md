# Step 31 — The standard library: `base64`

**Milestone:** M11 — The standard library · **Prereq:** step 27 (the
json package — the byte-scanner discipline and the exact-buffer
patterns this package follows) · **Related:**
`stdlib/registry/{json,yaml,xml,os}` (the sibling packages),
`docs/stdlib/base64.md` · **Status:** done on every target — the
first standard-library package whose golden rides all five lists:
bootstrap, c, typescript, wasm, and beam (2026-10-09).

## Why this step exists

base64 is the smallest complete codec a real program needs — tokens,
attachments, data URLs, basic auth — and the first pure-Emo package
small enough to hold the whole standard-library contract in one
glance: strictness, offset-bearing errors, byte-identical answers on
every target. Getting it onto the wasm and beam lists also meant
flushing out the constructs the shipped examples never exercised, so
this step is as much about the backends as about the package.

## Goal

`require "base64"` encodes with the standard alphabet and `=` padding
and decodes strictly: alphabet-only, padding only in the final
quantum, the final quantum holding two or three data characters, and
the RFC's zero padding bits actually zero (`QR==` is a mistake, not a
synonym of `QQ==`). Every rejection raises with the offending byte
offset. No whitespace or line-wrap tolerance — the caller joins a
wrapped message first.

## What the step flushed out (fixes landed here)

Four latent backend bugs, each one unreachable by every shipped
example until this package walked through them:

- **The wasm `&&`/`||` left operand** skipped the `ref.cast` that
  `truthy` documents as the contract, so any logical operator in
  unspecialized code failed module validation (`struct.get` on
  anyref). This was the wall that had gated json/yaml/xml out of the
  wasm goldens since step 27.
- **The wasm zero-length byte copies** were do-whiles: `"".to_bytes()`
  and `Bytes.new(0).to_string()` each read element 0 of an empty
  array and trapped.
- **The beam `&&`/`||`** fell into the generic binary arm and called
  the runtime's `emo_add` on two booleans.
- **The beam tuple index** lowered to `lists:nth` over an Erlang
  tuple — `function_clause` on first use. Tuples now answer
  `element/2`; arrays (Erlang lists) keep `lists:nth`.
- **The beam `Exception.new`** was refused outright (the T17.4
  catch-all); the exception object on beam is its message, thrown as
  `{'emo_raise', message}`.

## Design note

Every raise lives in `decode` (the String-taking function); the
scanning and filling helpers are pure and report `(kind, offset)`
pairs. The decoder is canonical by default — the strictness-first
rule applied to bytes.

## Follow-ups

- The wasm/beam gates on json/yaml/xml should be re-examined: the
  `&&` fix removes the wall this step documented, but those packages
  also pass class/interface values across module boundaries — the
  cross-module-types checker step (step 27's follow-up) may still gate
  them. First step when picked up: build json_demo for wasm and see.
- The guard emitter's `'andalso'` lowering (Core Erlang has no
  `andalso` call) is the same bug family as the beam `&&` fix and is
  still dormant — no shipped example reaches it.

## Tasks

- [x] **T31.1** — The package: arithmetic alphabet both directions,
      the strict decoder, offset-bearing errors. (Done 2026-10-09.)
- [x] **T31.2** — The wasm fixes: the `&&`/`||` cast and the
      zero-length byte-copy guard. (Done 2026-10-09.)
- [x] **T31.3** — The beam fixes: the logical operators, the tuple
      index, and `Make_exception`. (Done 2026-10-09.)
- [x] **T31.4** — The golden: `examples/base64_demo` on all five
      lists — the RFC 4648 vectors plus a multi-byte UTF-8 round
      trip. (Done 2026-10-09.)
- [x] **T31.5** — The docs: `docs/stdlib/base64.md` and its zh-CN
      mirror; `dune build @fmt` and `dune test` green. (Done
      2026-10-09.)
