# Step 82 — The standard library: `toml`

**Milestone:** M43 — The configuration format · **Prereq:** step 78
(the `template` package, the most recent pure-Emo format package) ·
**Related:** `stdlib/registry/json`, `stdlib/registry/yaml` (the value
tree this package mirrors), `stdlib/registry/float` (the exact-decimal
constructor every number rides), `docs/stdlib/toml.md` · **Status:**
done on the interpreter, ocaml, c, typescript, wasm, and beam — the
two goldens ride the five compiled lists plus the bootstrap.

## Why this step exists

Every configuration story the language tells ends in someone else's
format: json carries no comments and no dates, yaml resolves by
schema guesswork, and the tooling ecosystem's lingua franca — Rust's
Cargo, Go's tooling, Python's packaging — is TOML. The standard
library had no answer, and the format packages (json, yaml, csv, xml)
had long since settled the shape one takes: pure Emo over the shared
runtimes, a value tree of one interface over one class per kind,
decode answering `(R.error, reason)` with the byte offset, and goldens
that ride every target. TOML 1.1.0 is the strictest of the formats —
its table, dotted-key, and array-of-table redefinition rules are
semantic, not syntactic — so the package is where the strictness-first
stance gets exercised hardest: the parser assembles while it parses,
and every rule violation refuses at the expression that violates it.

## Goal

`require "toml"` decodes any TOML 1.1.0 document into a `Toml` value
tree — seven kinds, no null, the four date-time forms as one
`TomlDateTime` class — byte-identical on the interpreter, ocaml, c,
typescript, wasm, and beam, and encodes a tree back into a document
that decodes to the same value.

## Decisions settled here

- **The tree has no null.** TOML has no null, so the kind enum has
  seven members and the interface has no `is_null?()` — the json and
  yaml trees carry one because their formats do.
- **The four date-time forms share one class.** `TomlDateTime` holds
  every parsed field, `datetime_kind()` names which form it is
  (`toffset`, `tlocal_datetime`, `tlocal_date`, `tlocal_time`), the
  fields the form lacks read zero, `offset_minutes()` rides only on
  the offset form (0 for `Z`, east positive, west negative), and
  `to_text()` renders the canonical spelling — full seconds, the `T`
  delimiter, `Z` or `±hh:mm`, a fraction only when the nanoseconds
  are nonzero, three/six/nine digits with trailing zeros trimmed —
  that `decode` reads back to the same fields. It implements the
  `Toml` interface like every other kind (its scalar accessors
  raise); a factory would need nine parameters, so construction is
  `TomlDateTime.new(...)` directly.
- **The 1.1 relaxations ride in full.** `\e` and `\xHH` escapes;
  seconds omittable in every date-time; lowercase `t` and `z` as RFC
  3339 permits (the spec cites the section); multi-line inline tables
  with comments; trailing commas in inline tables. The space
  delimiter is try-and-see: a clock parse failure rewinds to the
  plain date, so `1979-05-27 07:32` reads as a local date-time while
  `1979-05-27 x` still reads as a date.
- **Strictness keeps the spec's own edges.** Fraction seconds keep
  nine digits — the spec requires further digits be truncated, not
  rounded, and they are. Leap second 60 rides through (the grammar's
  own range). Uppercase `E` refuses — the grammar spells the exponent
  lowercase `e` and nothing else. Day, month, hour, minute, and
  offset validate against the real calendar (leap years included);
  the second range stops at 60.
- **`inf` and `nan` refuse, like yaml's `.inf`/`.nan`.** They are
  valid TOML, and no target that lacks non-finite values can carry
  one — BEAM settles it for the package. Integers outside Int64
  refuse the same way, overflow-checked per spelling so the exact
  minimum stays reachable.
- **The document assembles while it parses.** Nodes are `TTbl`s with
  an origin (`tvalue`, `theader`, `tdotted`, `tarray`) and a
  `declared` flag, children riding an insertion-ordered `Map` so the
  decoded tree keeps document order. A keyval's dotted path creates
  dotted tables; a header's path creates implicit supertables; the
  final position of a header upgrades an implicit table at most once
  and refuses every other shape; `[[x]]` appends elements and a
  deeper header descends into the latest one. Inline tables run the
  same assembly core against a fresh root and convert at the closing
  brace, which is why they are closed by construction.
- **Encode is the document form, scalars first.** Each table renders
  its scalar and inline-array entries, then `[a.b]` sections and
  `[[a.b]]` element sections — the only order a table's own text can
  express, its entries being required to stay contiguous. Arrays
  whose elements are not all tables ride inline, table items
  included; an empty array rides inline, `[[x]]` having no empty
  form. `decode(encode(v)) == v` at the value level, a table defined
  out of order being the one reorder the format forces. The tree's
  own `encode()` is the value literal — tables inline `{ k = v, ... }`
  — which is what a template or a nested key needs.

## Deliberately out (v1)

Date-time arithmetic (a `to_utc_ms` or the like — the fields are the
surface, conversion is the caller's arithmetic or a later arc), a
`has?(key)` presence test (json and yaml have none; entries() is the
scan), input UTF-8 validation (bytes pass through, the json/yaml
stance), non-finite floats (named above), and any TOML 1.0-draft
compatibility toggles — the package implements one spec.

## Tasks

- [x] **T82.1** — The package: `stdlib/registry/toml/0.1.0` — the
      manifest and the value tree, decode (frame, keys, values,
      strings, numbers, date-times, arrays, inline tables, document
      assembly), encode (document form, sections, inline literals,
      key and string quoting), and the float package dependency.
- [x] **T82.2** — The goldens: `examples/toml_demo` (the happy path —
      tables, dotted keys, arrays of tables, inline tables, every
      number spelling, the four date-time forms, encode round trips)
      and `examples/toml_edge` (every escape, the boundaries, the 1.1
      relaxations, the redefinition rules, and ninety refusals each
      printing its reason) — expected.txt on the interpreter,
      byte-identical through the ocaml, c, typescript, wasm, and beam
      lists.
- [x] **T82.3** — The wiring: `test/emo_cli`'s wasm, beam, and c
      golden lists, `test/emo_project`'s bootstrap and ts_golden
      suites, and `devtools/wasmtime-smoke.sh`'s GOLDENS.
- [x] **T82.4** — The docs: `docs/stdlib/toml.md` + zh-CN mirror, the
      `docs/stdlib.md` row + section + mirror.
- [x] **T82.5** — The tracking: this plan, `plan/README.md`'s
      milestone bullet and status row, `docs/TASKS.md`'s M43 section +
      mirror, `CHECK.md`'s settle record.

## Found and fixed here

Seven bugs in the package the edge battery flushed, each a shape the
format packages' shared toolkit had not walked before:

- **The basic string's fill answered the write length where the next
  index belongs.** json's two-pass shape answers `(written, next)`;
  the toml copy answered `written` alone, so every string left the
  parser positioned at a byte offset equal to the string's decoded
  length. The pair shape restored.
- **Hex escape digits read with the wrong weights.** The recursive
  reader multiplied each digit by sixteen regardless of depth
  (`h * 16 + rest`), so `\u4e16` decoded as U+0136 and `\U0001F600`
  landed nowhere near U+1F600 — and the surrogate checks sat inert,
  the misread values never landing in the surrogate range. Place
  values (`h * 16^(n-1) + rest`) restored both.
- **The float buffer counted the underscores.** `1_000.000_1` sized
  its integer part by the byte span (five) instead of the digit count
  (four), leaving a stale zero in the normalized buffer and decoding
  9952.0001. The count comes from the collector's answer now.
- **The exponent value ate the underscores as digits.** `1e1_0`
  accumulated `_` as forty-seven, reading an exponent of 570 and
  refusing a number that is exactly 1e10. Underscores ride through.
- **`doc_inline?` answered true for all-table arrays.** Encode emitted
  `x = [{...}, {...}]` inline in the scalar pass *and* `[[x]]`
  sections in the section pass — the same value twice, the inline
  text itself invalid as a document line. All-tables arrays are
  sections; the predicate now refuses them.
- **Section lines rendered the full dotted path.** Inside `[owner]`,
  entries printed as `owner.name = ...` — valid-looking TOML that
  decodes as something else entirely. Keys inside a section are
  relative to the table the header named.
- **The date-time class missed the interface.** `TomlDateTime` stood
  outside the `Toml` interface's method set, so a date-time value
  could not ride the tree at all — the checker refusing every decode
  that produced one. It implements the interface like every other
  kind now.

And three compiler bugs the goldens flushed on the compiled targets —
each pre-existing on the tree, each invisible until a package leaned
on the shape it breaks, each fixed in its backend:

- **The TypeScript backend's Void tail-call driver had no exit.** The
  driver is a labeled `for(;;)` that only `return`s; a Void body
  whose tail call sits inside an `if` without an `else` (the implicit
  fall-through the step-81 lowering makes a Return position) emitted
  an empty else, and the fall-through wrapped to the loop header —
  every Void tail recursion spun forever on TS, json's `fill_spaces`
  and float's `copy_range` included, so the whole ts_golden suite
  burned CPU on this tree. A Void driver now ends in
  `return undefined;` (the emitter's own While-in-tail pattern).
- **The BEAM backend's runtime dispatch bound its builtin arm through
  a clobberable map.** An open-receiver call (`get` on an interface,
  say) emits `let <fresh> = recv in case fresh of` with a builtin
  default arm whose receiver was the literal `"__inst_recv"` —
  resolved through `local_map`, which the NEXT dispatch's
  `fresh_var` overwrites. One level deep the map answers the right
  name (why json_demo passed); two or more levels deep the outer
  chain's builtin arm named the inner binding, out of scope, and
  erlc refused the module on an unbound variable — any package
  chaining `get` past two interfaces hit it. The arm now names its
  own fresh binding directly, with the map carrying that binding's
  self-entry.
- **The wasm backend's `deep_eq` had no tuple arm.** Structural
  equality arms for every kind but `$vtuple` — a tuple fell through
  the chain to the constant false, so any class field of
  `Array[(A, B)]` compared unequal to its own twin: the toml root
  table's `Array[(String, Toml)]` was never equal to its re-decode,
  and json's `JsonObject` carried the same latent break. The array
  arm parameterized over its operand locals, and the tuple arm
  spills both tuples' element arrays into two fresh locals and runs
  it — tuples compare element-wise like arrays do.
