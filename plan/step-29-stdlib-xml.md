# Step 29 — The standard library: `xml`

**Milestone:** M11 — The standard library · **Prereq:** step 27 (the
json package — the tree design, the byte-scanner discipline, and the
exact-buffer patterns this package follows) · **Related:**
`stdlib/registry/{json,yaml}` (the sibling format packages),
`docs/stdlib/xml.md` · **Status:** done on the interpreter, ocaml,
typescript, and c targets (2026-10-09); the cross-module-types checker
step landed (2026-10-10), and wasm and beam wait on their own
capability walls

## Why this step exists

XML is the third exchange format the README reserves for the standard
library. XML is all text — no scalar coercion, no float machinery —
so the package is the leanest of the three: an element class and a
text class, a byte-level well-formedness parser with the five
predefined entities and character references, and an encoder that
round-trips the tree exactly (all text children kept, including
whitespace-only ones).

## Goal

`require "xml"` decodes and encodes well-formed XML byte-identically
on the verified targets: elements with quoted attributes, self-
closing form, comments / PIs / declaration / DOCTYPE skipped, CDATA
as raw text, the five entities plus `&#ddd;` / `&#xhh;` everywhere,
mixed content, same-name children (get takes the first), and the
usual strictness — mismatched tags, duplicate attributes, unknown
entities, and missing elements all raise with the byte offset.

## What the package flushed out (fix landed here)

- **`Bytes.to_string()` followed by a byte-count `substring`** — the
  buffer was exact, so the substring repeated the byte count against
  a decoded (character-counted) string and went out of bounds on any
  multi-byte content. All exact-fill buffers across the json, yaml,
  and xml packages now return `to_string()` directly.

## Follow-ups

- The cross-module-types checker step (step 27's follow-up) gated
  wasm and beam here as it gated json and yaml. (The c target works:
  the xml_demo golden rides the c_goldens list. The step landed
  2026-10-10; wasm and beam now wait on their own capability walls.)

## Tasks

- [x] **T29.1** — The package, the value model (XmlElement /
      XmlText over the Xml interface), and the decoder: elements,
      attributes, text with entities, CDATA, comments, PIs,
      declaration and DOCTYPE skipping, the depth cap, and
      offset-bearing errors. (Done 2026-10-09.)
- [x] **T29.2** — The encoder: elements with escaped attributes,
      self-closing form, escaped text, exact round-trips. (Done
      2026-10-09.)
- [x] **T29.3** — The goldens: `examples/xml_demo` (bootstrap + c +
      typescript) and `examples/xml_edge` (bootstrap — entity forms,
      attributes, same-name children, mixed content, self-closing,
      declaration/comment/PI skipping). (Done 2026-10-09.)
- [x] **T29.4** — The docs: `docs/stdlib/xml.md` and its zh-CN
      mirror; `dune build @fmt` and `dune test` green. (Done
      2026-10-09.)
