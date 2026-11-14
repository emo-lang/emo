# The `uuid` Package

The standard library's RFC 9562 UUID package: the identifier as one
immutable 16-byte value, the versions as named doors, and the text and
byte forms as strict conversions. Pure Emo over the shared runtimes —
the digests come from `crypto`, the entropy from `rand` — so every
target answers byte-for-byte.

The value is opaque by the RFC's own advice (Section 6.12): a UUID is
constructed, compared, ordered, and rendered, and its fields are read
back only where the RFC names them. A UUID is any 16 bytes — `parse`
is strict about the text, not about the bits, so the custom and
reserved layouts ride the same value.

## Using the package

```emo
require "uuid"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "uuid"` needs `"uuid" = "0.1.0"` in
the manifest's `deps` block.

## The value

`Uuid` is a class and an ordinary value: immutable, copied on
assignment, and `==` compares the bytes. A UUID constructed from a
byte count other than 16 raises — the type is 16 bytes by definition.

```emo
def to_string() String      // lowercase hex-and-dash, RFC 9562's own form
def to_bytes() Bytes        // the 16 bytes, big-endian field order (Section 4)
def version() Int64         // the high nibble of octet 6, 0 through 15
def variant() UuidVariant   // ncs, rfc, microsoft, future (Table 1)
def is_nil?() Bool          // all 128 bits zero (Section 5.9)
def is_max?() Bool          // all 128 bits one (Section 5.10)
def compare(other Uuid) Int64
```

`to_string` answers the identifier itself — lowercase hex-and-dash, the
form the RFC's ABNF defines, whatever case the text it was parsed from
wore; a rendered value (println, interpolation) is the structure dump,
so call `id.to_string()` for the text form.

`compare` is the RFC 9562 ordering (Section 6.11): the big-endian
bytes, compared left to right — `-1` before, `+1` after, `0` equal.
The order a database index gets for free, and the order the
time-ordered versions sort in.

`variant` reads the top bits of octet 8 as Table 1 reads them: `ncs`
(the Apollo NCS backward-compatibility range, where the Nil UUID
falls), `rfc` (this document's variant, where versions 1 through 8
fall), `microsoft`, and `future` (where the Max UUID falls).

## The constructors

```emo
def nil() Uuid                      // 00000000-0000-0000-0000-000000000000
def max() Uuid                      // ffffffff-ffff-ffff-ffff-ffffffffffff
def from_bytes(data Bytes) (R, Uuid)
def parse(text String) (R, Uuid)
def v4() (R, Uuid)
def v7(now_ms Int64) (R, Uuid)
def v3(namespace Uuid, name String) Uuid
def v5(namespace Uuid, name String) Uuid
def ns_dns() Uuid
def ns_url() Uuid
def ns_oid() Uuid
def ns_x500() Uuid
```

`from_bytes` answers the value for any 16 bytes — a UUID is the bytes,
whatever the version and variant fields hold — and refuses a length
other than 16 with `(R.error, reason)`.

`v3` and `v5` are total and deterministic: the same namespace and name
answer the same UUID on every target, forever. Any `Uuid` serves as a
custom namespace, the way Section 6.6 provides for; the four
namespace doors answer the IANA-registered IDs of Table 3, and a name
is the text its namespace's own specification states — DNS's host
name, the URL as the URL specification states it, the OID in dot
notation, the X.500 distinguished name.

## The versions

**v4** — 122 random bits over the operating system's entropy source
(`rand.bytes`, Section 6.9), the version and variant fields stamped
over the draw. The general-purpose door: a refused entropy source
answers `(R.error, reason)`, the reason the `rand` package's own.

**v7** — the Unix epoch in milliseconds, read from the caller's own
clock (`time.now()`, the `time` package) and passed in — the package
stays clock-free — with 74 random bits over it, the RFC's base shape
(Section 5.7). `v7(1645557742000)` is
the call; the caller owns the clock, and two UUIDs minted in the same
millisecond are distinct but not ordered — the generator-state
counters of Section 6.2 are the caller's to run. A negative timestamp
raises; one that does not fit the 48-bit field raises too — the field
is honest to the year 10889, and anything larger is a units mistake,
not a time.

**v3 and v5** — MD5 and SHA-1 over the namespace and the name's UTF-8
bytes, the first 16 bytes of the digest filling the layout, version
and variant stamped over it (Sections 5.3, 5.5). v3 rides
`crypto.legacy.md5` and v5 `crypto.legacy.sha1`, broken for every
security purpose and present for existing data; the RFC's own advice —
where possible, prefer v5 — stands.

The versions that are out, named: **v1, v2, v6** need a Gregorian
timestamp, a node, and a clock-sequence generator state — the MAC
address the RFC's Section 8 discourages, and generator state the
package does not hold (the RFC's Section 6.2 says systems that do not
involve legacy UUIDv1 SHOULD use UUIDv7 instead). **v8** needs no
constructor: the custom layouts are the caller's ordinary `Bytes`
code — set octet 6's high nibble to `8` and octet 8's top two bits to
`10`, fill the other 122 bits as the design pleases, and hand the 16
bytes to `from_bytes`.

## The text form

`parse` accepts exactly the canonical hex-and-dash form and nothing
else: 36 characters, a dash at 8, 13, 18, and 23, hex digits
elsewhere. The hex digits are case-insensitive, as the RFC's own ABNF
reads (both cases are HEXDIG), and the answer renders lowercase either
way. The braces of `{...}`, the `urn:uuid:` prefix, and the 32-
character undashed form are other systems' presentations — a caller
strips them itself, visibly, before the call.

Every rejection is `(R.error, reason)`, the reason naming the first
offending byte:

```
uuid: expected 36 characters, got 32
uuid: expected a dash at byte 8
uuid: expected a hex digit at byte 35
```

`MustParse` has no door because Emo already holds the construct: the
binding pattern, which raises on a mismatch.

```emo
const (R.ok, id) = uuid.parse(text)
```

## The vectors

The golden (`examples/uuid_demo`) rides the RFC's own vectors: Figure
1's example parsed, rendered, and read back; Appendix A.2's and A.4's
name-based values — DNS and `www.example.com`, v3
`5df41881-3aed-3515-88a7-2f4a814cf09e`, v5
`2ed6657d-e927-568b-95e1-2665a8aea6a2`; the four namespace IDs of
Table 3; the Nil and Max UUIDs; the Appendix A.6 timestamp read back
out of a v7 draw; and the strict refusals. The random doors print only
what the RFC fixes about them — version, variant, timestamp, order,
and that two draws differ — so the golden rides the interpreter, c,
ocaml, typescript, wasm, and beam byte for byte.
