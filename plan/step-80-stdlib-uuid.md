# Step 80 — The standard library: `uuid`

**Milestone:** M41 — The standard library: `uuid` ·
**Prereq:** step 35 (base64 — the pure-Emo codec discipline and the
all-five-golden shape) and step 55 (crypto and rand — the digests the
name-based versions ride, and the entropy source v4 and v7 draw
through) · **Related:** `stdlib/registry/{crypto,rand}` (the
dependencies), Go 1.27's standard `uuid` package (the scoping
reference), RFC 9562 (the specification and its vectors) ·
**Status:** done on every target — the golden rides all five lists:
bootstrap, typescript, c, wasm, and beam.

## Why this step exists

Every distributed system needs an identifier that requires no
coordination to mint. UUIDs are the Internet's answer, RFC 9562 the
current specification, and Go's standard library shipped its own
`uuid` package in 2026 with the minimal surface the problem actually
has: one opaque value, the random and time-ordered versions, the
strict parse, and the byte/text conversions. Emo's standard library
has `crypto` (the digests v3/v5 need) and `rand` (the entropy v4/v7
draw), and it has a decade of Go's `github.com/google/uuid` experience
to scope against — so the identifier deserves its own package, in
pure Emo, byte-identical on every target like the rest of the format
packages.

## Goal

`require "uuid"` gives one value and the versions that mint it:

- **One value.** `Uuid` is a class holding 16 bytes — immutable,
  copied on assignment, `==` by content. `to_string` is the protocol
  method (the lowercase hex-and-dash form the RFC's ABNF defines),
  `to_bytes` answers the RFC's network-byte-order form, `version` and
  `variant` read the two fields the layout tables define, `is_nil?`
  and `is_max?` answer the special forms, and `compare` is the RFC
  6.11 big-endian order.
- **The versions as named doors.** `v4()` draws 122 random bits;
  `v7(now_ms)` takes the Unix time in milliseconds from the caller's
  own clock over 74 random bits; `v3(ns, name)` and `v5(ns, name)` are
  the deterministic name-based doors over `crypto.legacy`; the
  namespace IDs of RFC 6.6's Table 3 are `ns_dns`/`ns_url`/`ns_oid`/
  `ns_x500`. No `new()` alias — the door names the algorithm.
- **Strict conversions.** `parse` takes exactly the canonical
  36-character form (hex case-insensitive, as the RFC's own ABNF
  reads), every rejection naming the first offending byte;
  `from_bytes` takes exactly 16 bytes. The braced, urn-prefixed, and
  undashed forms are other systems' presentations, not silent
  fallbacks.

## Decisions settled here

- **The scoping is Go's standard `uuid`, filled in where the RFC pins
  the shape.** Go's stdlib treats UUIDs as generally opaque: `New`/`
  NewV4`/`NewV7`, `Parse`, `Nil`, `Max`, `String`, `Compare`, the text
  marshals. Emo's package keeps that spine and adds the two things the
  RFC fully specifies and pure Emo gives for free: the name-based
  versions (`v3`/`v5` — deterministic, byte-identical on every target,
  the golden's core) and the introspection pair (`version`/`variant`)
  the random doors' goldens need. `version` deliberately answers an
  Int64 (0–15), not an enum: versions 9–15 are reserved, not named.
- **The value, not raw bytes.** The base64 package answers Strings
  because base64 is text; crypto answers Bytes because bytes are what
  algorithms read. A UUID is an identifier: it renders itself through
  the `to_string` protocol, sorts through `compare`, and crosses
  process boundaries as a value. The 16 raw bytes stay one
  `to_bytes()` away for storage (the RFC's Section 6.13 advice).
- **v7's clock is the caller's, and the time is a parameter.** Emo has
  no clock primitive — the stance `slog` records and `httpd`'s
  `with_date` follows — so `v7(now_ms Int64)` takes the Unix time in
  milliseconds. 74 random bits fill the rest, the RFC's base shape
  (Section 5.7); no generator state, no hidden counter — the
  monotonicity methods of Section 6.2 are the caller's to run, and two
  same-millisecond draws are distinct but not ordered. A negative
  timestamp raises; one that does not fit the 48-bit field raises too
  — the field is honest to the year 10889, and a larger number is a
  units mistake, not a time (strictness first: no silent truncation of
  what is almost certainly nanoseconds).
- **One canonical text form.** RFC 9562's ABNF is the hex-and-dash
  form with case-insensitive HEXDIG, so `parse` takes exactly that —
  36 characters, dashes at 8/13/18/23 — and refuses the braced,
  urn-prefixed, and undashed 32-character forms the way base64's
  decoder refuses whitespace and line wraps: another system's
  presentation is the caller's trim, visibly. Errors name the first
  offending byte (`uuid: expected a dash at byte 8`), the base64
  shape. `MustParse` has no door because the binding pattern
  (`const (R.ok, id) = uuid.parse(text)`) already raises on a
  mismatch.
- **v1/v2/v6 and a v8 constructor are out, named.** v1/v2/v6 need a
  Gregorian timestamp, a node, and clock-sequence generator state —
  the MAC address the RFC's Section 8 discourages, and state the
  package does not hold; the RFC's own answer for systems without
  legacy UUIDv1 is v7. v8 needs no constructor: the custom layouts are
  the caller's ordinary `Bytes` code through `from_bytes` (octet 6's
  high nibble `8`, octet 8's top two bits `10`), and a special door
  would only restate 15 lines of ordinary code.
- **Entropy failures keep the rand reason.** `v4`/`v7` propagate the
  entropy source's own `(R.error, "rand: …")` — the reason names the
  package that failed; the package's own `uuid:`-prefixed reasons are
  for its own refusals (text, length).

## Tasks

- [x] **T80.1** — The package: `stdlib/registry/uuid/0.1.0` — the
      `Uuid` class, `UuidVariant`, the four constructors' doors, the
      two conversions, and the four namespace IDs, pure Emo over
      `crypto` and `rand`; the `source_of` map shared by `parse` and
      `to_string` so both directions read the same 36-character
      shape.
- [x] **T80.2** — The golden: `examples/uuid_demo` — the RFC's Figure
      1 example, the Appendix A.2/A.4 name-based vectors (verified
      against Python's standard implementation before freezing), the
      Table 3 namespaces, Nil/Max and their order, the byte round
      trip, the strict refusals with their byte offsets, and the
      random doors printed structure-only (version, variant, the
      A.6 timestamp read back, two draws differing, the order) so the
      golden rides every target byte for byte.
- [x] **T80.3** — The registration: `uuid_demo` onto the wasm, beam,
      and c golden lists in `test/emo_cli`, the typescript golden
      list and the bootstrap list in `test/emo_project`; verified
      byte-identical on the interpreter, `c`, and `typescript`
      before landing.
- [x] **T80.4** — The docs: `docs/stdlib/uuid.md` EN+zh; the
      `docs/stdlib.md` row and section EN+zh; the README reference
      lists EN+zh; TASKS/plan/CHECK updated.
