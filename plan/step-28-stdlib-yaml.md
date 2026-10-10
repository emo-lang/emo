# Step 28 — The standard library: `yaml`

**Milestone:** M11 — The standard library · **Prereq:** step 27 (the
json package — the yaml package shares its tree design, its block
parser discipline, and its exact-decimal float machinery) ·
**Related:** `stdlib/registry/json` (the sibling format package),
`docs/stdlib/yaml.md` (the doc format) · **Status:** done on the
interpreter, ocaml, and typescript targets (2026-10-09); c, wasm, and
beam are blocked on the same cross-module-types checker step that
gates the json package (see step 27's follow-ups)

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

- The cross-module-types checker step (step 27's follow-up) gates c,
  wasm, and beam here exactly as it gates the json package.

## Tasks

- [x] **T28.1** — The package and the parser: `stdlib/registry/yaml/
      0.1.0` (`package.emo` over the five targets, `yaml.emo` with the
      value model and the block/flow parser, `internal/float.emo` for
      the numeric machinery) embedded by rebuild. (Done 2026-10-09.)
- [x] **T28.2** — The encoder: block style, plain-when-unambiguous
      string policy with double-quoting otherwise, empty-container
      flow forms. (Done 2026-10-09.)
- [x] **T28.3** — The goldens: `examples/yaml_demo` (bootstrap +
      typescript) and `examples/yaml_edge` (bootstrap — escape
      matrix, surrogate pairs, number boundaries, block-scalar
      chomping, duplicate keys, empty containers, round-trips).
      (Done 2026-10-09.)
- [x] **T28.4** — The docs: `docs/stdlib/yaml.md` and its zh-CN
      mirror; `dune build @fmt` and `dune test` green. (Done
      2026-10-09.)
