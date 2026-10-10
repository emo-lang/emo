# Step 32 — The standard library: `slog`

**Milestone:** M11 — The standard library · **Prereq:** step 31
(base64 — the native-types-only surface shape that crosses module
boundaries cleanly) · **Related:** `stdlib/registry/{json,os,base64}`
(the sibling packages), `docs/stdlib/slog.md` · **Status:** done on
interpreter/ocaml/c/typescript; wasm and beam refuse the package until
their runtimes implement `Map` (2026-10-09).

## Why this step exists

Structured logging is the shape every real backend reaches for, and
the first standard-library package whose subject is *stateful-looking*
behavior — levels, sinks, configuration — on a language with no
module-level mutable state and no clock. How Emo says "a logger"
without a framework is the design question this step answers: the
logger must be a value, the output must be deterministic, and the
strictness rules must be the package's, not the caller's hope.

## Goal

`require "slog"` logs one line per record, logfmt or JSON, filtered by
a minimum level. A logger is an opaque handle carrying its name,
level, and format — `child` derives a renamed copy, `enabled` answers
before the record is built. Attrs are a `Map[String, String]` whose
keys are strict to one alphabet (ASCII letters, digits, `_`, `.`,
`-`), so a key reads the same in both formats. Every rejection raises
with the exact mistake; filtering is the only silence.

## Design note

- **Loggers are values.** The handle packs `name/level/format` in
  plain sight — the name percent-encoded, fields joined with `:` —
  and every function parses it. The package holds no state at all, so
  there is no initialization order to reason about on any target.
- **No clock, no timestamps.** Records carry only what the caller
  passes; deterministic output is a feature (the golden is
  byte-stable forever), and a caller with a time passes it as an
  ordinary attribute.
- **One strict key alphabet.** The same `plain_byte` set gates
  attribute keys and drives percent-escaping, so no key ever needs
  quoting and no encoded name can smuggle a `:`.
- **Attrs are a `Map[String, String]`.** wasm and beam refuse `Map`
  today, so the manifest declares the three targets that work and
  widens when their runtimes land `Map` — the same honesty rule as
  the os package.

## What the step flushed out

Nothing in the backends — the first package whose golden needed zero
compiler changes, walking only paths steps 24–31 had already paved
(`Map` on interp/ocaml/c/ts, `Bytes` and native-type surfaces
everywhere they run). The step-31 wasm/beam fixes held.

## Tasks

- [x] **T32.1** — The package: the ordered levels and two formats,
      the handle pack/parse, the logfmt and JSON renderers, strict
      keys and exact errors. (Done 2026-10-09.)
- [x] **T32.2** — The golden: `examples/slog_demo` — both formats,
      filtering, a child logger, quoting and escaping, UTF-8, and
      `enabled` — on the bootstrap, c, and typescript lists. (Done
      2026-10-09.)
- [x] **T32.3** — The docs: `docs/stdlib/slog.md` and its zh-CN
      mirror; `dune build @fmt` and `dune test` green. (Done
      2026-10-09.)
