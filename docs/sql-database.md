# Emo and a SQL database — an assessment

Written 2026-10-06. This is a technical feasibility assessment, not
decided design; project-state claims reflect the repository as of the
date above.

The question: what would it take to build an original database product
in Emo that claims SQL-standard compatibility?

## The conclusion

**Feasible, in tiers — and the difficulty is mostly not about Emo.**
Seven or eight parts in ten of the effort are language-independent:
the breadth of the SQL standard, the correctness of the storage
engine, the conformance evidence. Emo's actor model and direct-style
IO are a genuine architectural fit — closer than for most systems
categories — but the first two layers the product would stand on,
durability IO and exact numerics, are precisely what Emo cannot do
today: the `file` package offers two functions, and the FFI admits
three types. The honest verdict, by tier:

| Tier | Product | Order of effort |
|---|---|---|
| A | Embedded, in-memory engine over a declared SQL subset | one person, 6–12 months; Emo suffices today, with the engine carrying its own data structures |
| B | Single-node persistent OLTP — WAL, B-tree, MVCC, a wire protocol, a SQLLogicTest-scale subset | 3–6 person-years; four Emo gaps must close first, adding a third to a half over a mature language |
| C | A product defensibly called standards-compliant — declared conformance tier, competitive performance, backup, security, HA | hundreds of person-years in any language; Emo adds a pre-1.0 dependency and an unmeasured performance ceiling |

## What "SQL-standard-compliant" actually pins down

ISO/IEC 9075 runs to over a dozen parts in the SQL:2023 edition; the
Foundation part (Part 2) alone exceeds a thousand pages, and Core
SQL:1999 is commonly counted at roughly 170 mandatory features.
PostgreSQL — the shipping system that tracks the standard most
closely — does not claim full conformance, and neither does any other.

The official conformance-testing regime died with NIST's SQL
validation program (FIPS 127-2), withdrawn in the 1990s. What
"compliant" means in practice today is a bundle: a declared dialect
tier, diff testing against SQLite's SQLLogicTest corpus (millions of
queries), the PostgreSQL wire protocol as the de facto interop
standard, SQLSTATE error codes, and an `information_schema`. The first
product decision is to reduce "compatible" to one of these decidable
tiers — otherwise the project has no end state.

## Effort anchors

- **SQLite** — on the order of 150,000 lines of C after more than two
  decades, and the test corpus dwarfs the source.
- **DuckDB** — sits on 25+ years of CWI research (the MonetDB
  lineage); a core team of about ten took roughly five years to 1.0,
  in C++.
- **TiDB, CockroachDB** — hundreds of person-years each, and both
  outsource the storage layer to RocksDB; neither builds a B-tree.
- **H2** — proof that a garbage-collected language can host a
  credible SQL engine with a small team.
- **Mnesia** — proof that the actor-model shape (per-process state,
  message passing) runs a production database; it never grew a SQL
  layer.

The self-built path — own parser, planner, executor, B-tree, WAL,
MVCC, server protocol — is on the order of 50–150k lines and
single-digit person-years to *usable*; an order of magnitude more to
*certifiably compliant*.

## Where Emo's design genuinely fits

- **The actor model maps onto the database's control plane.**
  Processes own connections, the lock manager, MVCC snapshot tables —
  the Erlang/Mnesia-proven shape, and one of the few systems
  categories where Emo's concurrency is an advantage rather than a
  neutrality.
- **The wire-protocol server is existing scaffolding.** Direct-style
  async networking on io_uring/kqueue/IOCP is exactly what
  `http.serve` and the tcp/http benchmarks already exercise.
- **The encoding raw material exists.** `Bytes` (mutable,
  fixed-length), `Int64` with wrap-around identical on every target,
  `Float64` as IEEE 754 everywhere — page and record encodings can be
  written today.
- **Immutability-first is MVCC-shaped.** Immutable pages share safely
  across processes by construction, `Box` mutability never crosses a
  process boundary, and a snapshot is a value rather than a discipline.

And the SQL front-end itself is proven territory: the wasm decoder
and validator already written in Emo (about 3,900 lines so far) are
the same genre of work — grammars, binary formats, index-space
validation — at a tenth to a fiftieth of the scale.

## The gaps, in blocking order

1. **Durability IO is a hard gate.** The `file` package is
   `read(path) String` and `write(path, contents String)` — no
   `fsync`, no append, no seek or positional write, no `Bytes`-level
   IO. No fsync, no WAL; no WAL, no database. The FFI admits
   `Float64`, `String`, and `Bool`, native-only — mmap, `O_DIRECT`,
   and sendfile are unreachable. The same gate the industrial-software
   assessment found.
2. **Exact numerics.** SQL's NUMERIC(38) needs 128-bit arithmetic;
   Emo has neither `Int128` nor a bignum. Hand-rolling 128-bit
   multiply, divide, and modulo on `Int64` is possible — thousands of
   lines plus the famous tail of edge cases.
3. **Collections and the performance floor.** No general-purpose Map
   or Set and no sort in the standard library; no generics; every
   value carries a runtime type tag; immutable arrays transform by
   allocation. First-version join/sort hot loops will trail C++ and
   Rust peers by a factor nobody has measured yet — the specialization
   story ("types feed performance") is stated design, not a number.
4. **GC tail latency.** The native backend shares one heap, so major
   GC work can land on p99; BEAM's per-process heaps avoid that but
   cap throughput. Latency versus throughput is a backend choice to
   make deliberately and early.
5. **The churn tax.** Global renames are still landing — the
   implementation used to spell `Int` and `Float` where the decided
   surface says `Int64` and `Float64`, and group syntax is undecided.
   A hundred thousand lines on a pre-1.0 language means moving house
   whenever the language does.

## What would have to land in Emo first

- `file`: fsync, append, seek and positional write, `Bytes` IO.
- FFI admits `Bytes` (pointers eventually), native target first.
- `Int32`/`Int128` — the numeric-width document's future widths become
  prerequisites the day NUMERIC enters scope.
- A collections package (Map, Set, sort) — though a database always
  ends up carrying some of its own.

That is several step-sized chunks of the roadmap — months, not days —
and every one of them is generally useful, not database-only.

## Positioning

The hard part of a database is correctness breadth and storage
engineering, not the language; no language choice buys that down. What
Emo can do is remove friction on the concurrency and networking
planes, where most databases still hand-roll threads and callbacks,
and the actor model is a real structural fit for the control plane of
an MVCC engine. If a tier-A engine exists and the durability gate
closes, tier B is an honest multi-year project rather than a research
gamble — and a credible database would be Emo's own most persuasive
ecosystem proof. Until then, the defensible scope is the
declared-subset embedded engine, and "SQL-standard-compliant" stays a
target tier with a test suite attached to it — not a phrase in the
pitch.

## References

- ISO/IEC 9075 (SQL), latest edition SQL:2023: <https://www.iso.org>
- SQLLogicTest, SQLite's corpus-based test harness:
  <https://www.sqlite.org/sqllogictest/>
- SQLite: <https://www.sqlite.org>
- PostgreSQL wire protocol documentation:
  <https://www.postgresql.org/docs/current/protocol.html>
- DuckDB: <https://duckdb.org>
