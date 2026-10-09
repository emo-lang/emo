# Step 27 — The standard library: `json`

**Milestone:** M11 — The standard library · **Prereq:** step 10
(packages — the mechanism a stdlib package rides) and step 26 (target
independence — the reason a pure-Emo package reaches every target) ·
**Related:** `stdlib/registry/{net,http,file}` (the worked pattern),
`docs/stdlib/http.md` (the doc format), `README.md` ("the official
standard library alone owns the top-level short names —
`json.decode()`") · **Status:** done on the interpreter, ocaml, and
typescript targets (2026-10-09); c, wasm, and beam are blocked on the
cross-module-types checker work recorded in the follow-ups below

## Why this step exists

The README reserves the name: JSON is an exchange format the standard
library reads and writes, and `json.decode()` is a reserved top-level
short name. Nothing stands behind the reservation — the language has
no JSON anywhere (the `json_parse` benchmark is a scanner over
`substring`). This step turns the reservation into the first pure-Emo
package that exercises the whole value system the runtimes share:
bytes, interfaces with narrowing, enums, tuples, arrays, and both
numeric widths — with zero per-target runtime work, which is the point
the last two steps earned.

## Goal

`require "json"` decodes and encodes JSON on every target the
compiler ships, byte-identically. Decode is strict: malformed input is
an exception naming the byte offset, numbers round-trip exactly, and
the value tree is ordinary Emo data (a package-defined interface over
seven classes) — no dynamic type is added to the language. Encode
emits compact and pretty forms, with floats in the shortest form that
round-trips bit-exactly.

## Decisions to settle here

- **The value model:** `enum JsonKind` plus an `interface Json` over
  seven payload classes (`JsonNull`, `JsonBool`, `JsonInt`,
  `JsonFloat`, `JsonString`, `JsonArray`, `JsonObject`). Payloads are
  read through `is()` narrowing into the concrete class — no unions,
  no map type, no new language construct. `JsonObject.get` is strict:
  a missing key raises.
- **The byte layer:** decode and encode work on `Bytes` (UTF-8)
  end to end, so every target sees the same bytes. The typescript
  runtime's `to_bytes`/`Bytes.to_string` — UTF-16 code units today —
  become true UTF-8 in this step; ASCII behavior is unchanged.
- **Numbers:** integer-form literals (no `.` or exponent) that fit
  `Int64` decode as `JsonInt`; out-of-range integers raise; all other
  numbers decode as `Float64` with correctly-rounded decimal→binary
  conversion (the same answer `strtod` gives). Encode prints floats in
  the shortest decimal form that reads back bit-identically
  (`Float64.to_bits`/`from_bits` make this checkable in pure Emo);
  non-finite floats raise — JSON has no spelling for them.
- **Errors:** the stdlib convention — `raise Exception.new(message:)`
  stating what failed and at what byte offset. No error codes, no nil.
- **Objects:** entries keep document order; duplicate keys are kept in
  `entries` and last-win in `get`. Nesting is capped (512) so hostile
  input dies with a message instead of the stack.

## What the package flushed out (compiler fixes landed here)

The package is ordinary pure Emo, and that is exactly why it kept
tripping over latent backend bugs. Fixed in this step:

- **The span type table was file-blind** (emo_check/emo_ir): types
  were keyed by (start, stop) offsets only, so modules whose offsets
  overlap — every module starts near zero — read each other's types.
  This corrupted field/method dispatch on every typed backend for
  multi-module programs. Keyed by (file, start, stop) now.
- **The typescript tail-call rewrite clobbered parameters** (emo_ts):
  `loop(n - 1, f(n))` decremented `n` before evaluating `f(n)`. All
  tail arguments now evaluate into fresh temporaries first.
- **typescript string escaping** (emo_ts): newlines were emitted raw
  inside literals, quotes were emitted unescaped. Also the interface
  table used OCaml `;` separators.
- **c emo_send arguments** (emo_c): argumentful interface dispatch
  passed an `emo_value` where the runtime reads `emo_value*` — invalid
  C for every argful send (nullary sends masked it). Now a compound
  literal array. An unknown-receiver method outside the builtin table
  also falls through to the vtable send instead of refusing.
- **c mutual-tail clusters** (emo_c): the merged function entered at
  the first member's head regardless of which member was called; each
  wrapper now passes an entry selector and the body routes to the
  member's head.
- **wasm interface dispatch** (emo_wasm): the fallback arms called
  class methods on an uncast `anyref`; the `Ref_test`'s cast was
  missing. Field reads also resolve the display name to the mangled
  cname now (methods already did).

## Follow-ups this step leaves behind

- **The checker does not resolve cross-module type names** ("cross-
  module types stay unchecked this step", step 9): `is(JsonObject)`
  in a consumer module narrows to Unknown, and an interface-typed
  result of a cross-module call dispatches dynamically. Until the
  checker collects dependency modules' declarations, the json package
  builds for the interpreter, ocaml, and typescript; the c backend
  refuses with "unknown receiver", wasm hits a validator error
  (function #63, `struct.get[0]` on an anyref from a dynamic call —
  one missing cast remains in a dynamic tuple/class read path), and
  beam refuses on its T17.4 whitelist. Minimal repros:
  `scratch`-style two-file programs with an interface + `is()` +
  field/method. **Unblocking this one checker step is what carries the
  package onto c, wasm, and beam** — the package itself is ordinary
  pure Emo.

## Tasks

- [ ] **T27.1** — The spec and the skeleton: this plan; the package
      `stdlib/registry/json/0.1.0` (`package.emo` declaring the five
      tested targets, `json.emo` with the value model, the factories,
      and `internal/float.emo` for the numeric machinery) embedded by
      rebuild. Verification: a program that `require "json"`, builds a
      value with the factories, and encodes it runs interpreted.
- [ ] **T27.2** — The typescript bytes fix: `to_bytes` encodes UTF-8
      and `Bytes.to_string` decodes UTF-8 in the ts prelude. All
      existing ts goldens byte-for-byte (ASCII is unaffected).
- [ ] **T27.3** — The decoder: the byte-level scanner and
      recursive-descent parser over the RFC 8259 grammar — string
      escapes including `\uXXXX` with surrogate pairs, the number
      grammar with exact `Int64`/`Float64` handling, whitespace,
      the depth cap, and offset-bearing errors.
- [ ] **T27.4** — The encoder: compact and pretty (two-space indent)
      forms; escaping of `"`, `\`, and control characters; integers
      through `Int64.to_string`; the shortest-round-trip float
      formatter (exact binary→decimal expansion, shortest prefix that
      reads back to the same bits).
- [x] **T27.5** — The golden example: `examples/json_demo` wired into
      the interpreter-bootstrap and typescript golden lists (one
      `expected.txt`); the c, wasm, and beam lists wait on the
      cross-module-types follow-up above. (Done 2026-10-09.)
- [x] **T27.6** — The edge fixtures: `examples/json_edge` — the
      escape matrix, surrogate pairs, the 512-array cap round-tripped,
      duplicate keys, number boundaries (denormals, 1e308,
      9007199254740993), the pretty form — wired into the
      interpreter-bootstrap list (ocaml binary agrees byte for byte).
      (Done 2026-10-09; found the missing empty-container guards in
      the compact encoder.)
- [ ] **T27.7** — The docs and close-out: `docs/stdlib/json.md` and
      its `docs/zh-CN/` mirror; `dune build @fmt` and `dune test`
      green; close-out.

## Open questions

None. The value model, numbers, errors, and object semantics are
settled above; streaming parsing and schema-style decode-into-class
mapping stay out of this step.
