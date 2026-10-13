# Step 47 — The standard library: `csv`

**Milestone:** M14 — CSV read/write · **Prereq:** step 35 (base64 —
the byte-scanner discipline and the all-five-golden shape) and step 31
(json — the format-package conventions) · **Related:**
`stdlib/registry/{json,yaml,xml,base64}` (the sibling formats),
`docs/stdlib/csv.md`, `docs/stdlib/base64.md` · **Status:** done on
every target — the golden rides all five lists: bootstrap, c,
typescript, wasm, and beam.

## Why this step exists

CSV is the tabular exchange format every data tool already speaks, and
the standard library shipped readers for JSON, YAML, and XML without
one. It is also a small enough format to hold the stdlib contract in
one glance — strictness, offset-bearing errors, byte-identical answers
— while needing nothing beyond bytes and arrays, so no target has a
runtime excuse to refuse it.

## Goal

`require "csv"` decodes RFC 4180 text into `Array[Array[String]]` and
encodes it back byte-identically on all five targets. Decode is strict:
CRLF / LF / lone-CR records, quoted fields holding delimiters and line
breaks, a doubled quote as one quote of data, a leading BOM ignored,
and every byte validated as UTF-8 (overlong forms, surrogates, and
code points past U+10FFFF rejected). Encode is the canonical writer:
CRLF after every record, a field quoted exactly when it holds the
delimiter, a quote, CR, or LF, and `decode(encode(rows))` equal to
`rows`. The `_delimited` pair takes a one-byte delimiter for TSV and
semicolon files.

## Decisions settled here

- **The value model is the table itself.** A decoded document is
  `Array[Array[String]]` — the records, in document order, with no
  header imposed. CSV has no schema, so no wrapper type earns its
  place; the first record is a header only if the caller reads it as
  one.
- **The error split.** Malformed input is the value
  `(R.error, reason)` with the offending byte offset. A caller's own
  mistake — a delimiter that is not one ASCII byte or that is a quote
  or line break, a zero-field record, a field `encode` cannot read as
  UTF-8 — raises.
- **The delimiter is a parameter, not a second package.** The grammar
  is one byte wide, so `decode_delimited` / `encode_delimited` cover
  TSV and semicolon files without a second package or an options
  record; the delimiter is validated as ASCII once, up front.

## What the step flushed out (fixes landed here)

Two latent backend bugs, unreachable by every shipped example until
this package walked through them:

- **The TypeScript UTF-8 decoder** rejected 3-byte lead bytes E8–EF
  (`b < 0xe8`), so every code point in U+8000–U+FFFF decoded as
  U+FFFD. No existing golden carried one — `csv_demo`'s `雷` did.
  Fixed to `b < 0xf0`; overlong and surrogate checks downstream stand.
- **The wasm unary `!`** read the `$vbool` field directly on the
  operand, which arrives as anyref, without the `ref.cast` `&&` and
  `||` already emit — so any module using `!` failed WebAssembly
  validation. `bad_utf8`'s `!continuation(…)` flushed it.

## Tasks

- [x] **T47.1** — The package: `stdlib/registry/csv/0.1.0` — the
      manifest over all five targets, `csv.emo` with the record model,
      the strict decoder, the canonical encoder, the UTF-8 validator,
      and the delimiter pair.
- [x] **T47.2** — The goldens: `examples/csv_demo` on the bootstrap,
      c, typescript, wasm, and beam lists; `examples/csv_edge` on the
      bootstrap list — every record shape, the malformed matrix, the
      UTF-8 boundaries, the BOM, and the encoder's quoting rule.
- [x] **T47.3** — The TypeScript UTF-8 fix.
- [x] **T47.4** — The wasm `!` fix.
- [x] **T47.5** — The docs: `docs/stdlib/csv.md` and its zh-CN mirror;
      the stdlib tour (`docs/stdlib.md` + zh-CN) and the README
      package lists; `dune build @fmt` and `dune test` green.
