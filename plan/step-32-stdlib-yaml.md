# Step 32 — The standard library: `yaml`

**Milestone:** M11 — The standard library · **Prereq:** step 31 (the
json package — the yaml package shares its tree design, its block
parser discipline, and its exact-decimal float machinery) ·
**Related:** `stdlib/registry/json` (the sibling format package),
`docs/stdlib/yaml.md` (the doc format) · **Status:** done on all five
targets (c 2026-10-10; wasm and beam 2026-10-14)

## Why this step exists

YAML is the second exchange format the README reserves for the
standard library. With the json package's tree design proven, the
yaml package mirrors it: a `Yaml` interface over one class per kind,
decoding YAML 1.2 (core schema) into that tree and encoding it back
in block style. The packages are independent — yaml carries its own
tree and its own copy of the exact-decimal float machinery — so each
can be required alone.

## Goal

`require "yaml"` decodes and encodes byte-identically on the targets
the checker currently carries: block mappings and sequences (nested,
compact `- k: v`, same-indent sequences under a key), flow
collections, quoted scalars with the YAML escape set, comments,
literal and folded block scalars with chomping, duplicate keys
last-win, and the number formats at their boundaries.

## What the package flushed out (compiler fix landed here)

- **The typescript runtime's method dispatch** (ts_runtime.ts): a
  field shadowed a same-named prototype method — `entries` as both a
  field and an accessor — and `E.method` found the field first and
  refused. When the own property is not a function, dispatch now
  falls through to the prototype's method. (The json package has the
  same latent collision and was equally masked.)

## Follow-ups

- The cross-module-types checker step (step 31's follow-up) gated c,
  wasm, and beam here exactly as it gated the json package. (Landed
  2026-10-10; yaml_demo runs byte-identically through the interpreter
  and the c binary — the landing also flushed a trampoline defect the
  yaml parser's mutual-tail cluster exposed: sibling cluster members'
  locals now live in per-head blocks.)
- **The wasm and beam landing (2026-10-14):** `yaml_demo` now rides
  the wasm, beam, and c golden lists (json_demo and xml_demo with it —
  the three packages shared the gate). `String.substring` had no wasm
  or beam runtime at all; wasm gained an in-bounds byte copy, beam a
  `binary:part/3` behind the interpreter's range check. Two wasm class
  bugs the format packages flushed are fixed: the class-pad formula
  gave two classes the same WasmGC struct shape — `ordinal *
  (max_fields + 1) + field_count` mapped (ordinal 0, 1 field) and
  (ordinal 1, 0 fields) both to two fields, so canonicalization merged
  their RTTs and every `ref.test` arm matched the wrong class (a
  `YamlNull` instance answered `YamlBool.encode`); the total field
  count is now `(ordinal + 1) * (max_fields + 1) + 2`, unique per
  class and clear of the two all-anyref runtime shapes. And the `get`
  builtin shadowed every class's `get` method (`doc.get("k")` lowered
  to Bytes indexing on both targets): both backends now test
  Bytes/instance at runtime and fall back to the Bytes accessor.

## Tasks

- [x] **T32.1** — The package and the parser: `stdlib/registry/yaml/
      0.1.0` (`package.emo` over the five targets, `yaml.emo` with the
      value model and the block/flow parser, `internal/float.emo` for
      the numeric machinery) embedded by rebuild. (Done 2026-10-09.)
- [x] **T32.2** — The encoder: block style, plain-when-unambiguous
      string policy with double-quoting otherwise, empty-container
      flow forms. (Done 2026-10-09.)
- [x] **T32.3** — The goldens: `examples/yaml_demo` (bootstrap +
      typescript) and `examples/yaml_edge` (bootstrap — escape
      matrix, surrogate pairs, number boundaries, block-scalar
      chomping, duplicate keys, empty containers, round-trips).
      (Done 2026-10-09.)
- [x] **T32.4** — The docs: `docs/stdlib/yaml.md` and its zh-CN
      mirror; `dune build @fmt` and `dune test` green. (Done
      2026-10-09.)
