# Emo and a Lua backend — an assessment

Written 2026-10-14. This is a technical feasibility assessment, not
decided design; project-state claims reflect the repository as of the
date above, and Lua-version claims reflect Lua 5.4 (the release a
backend would target) and Lua 5.5.1 (released 2026-08-03), with
LuaJIT 2.1 and the derived dialects noted where the distinction
decides the answer. Settled 2026-10-14: the backend is shelved
behind the re-evaluation triggers below — see CHECK.md.

The question: should Emo grow a code-generation backend that emits Lua
source — an eighth target beside the interpreter, C, OCaml,
TypeScript, wasm, BEAM, and the freestanding riscv64?

## The conclusion

**Feasible, and on three axes a closer fit than any target Emo already
has — but the fit holds only on Lua 5.3 and later, and that floor lands
exactly on the hosts that make a Lua target worth having.** Lua 5.3's
integer subtype satisfies Emo's Int64 wrap-around invariant natively;
Lua's coroutines are the same stackful cooperative process model the C
target implements with `ucontext` fibers; and Lua has proper tail
calls, which the C and TypeScript targets both approximate rather than
have. Against that: the embedders that make "an Emo artifact someone
else's process `require`s" interesting — Neovim, OpenResty, Redis,
Love2D, Roblox — are LuaJIT, Lua 5.1, or Luau, and none of those has an
integer subtype, so none can honor the invariant.

The recommendation: do not schedule the backend; shelve it behind the
re-evaluation triggers below. The gain that would justify it — an
artifact a host can load into an existing process — is served for less
by an embedding surface on the C target or the wasm target.

## What emitting Lua would involve

Repository facts, as of the date above:

- **Backend shape.** Backends share no module signature; each is a
  standalone emitter with a hand-written dispatch arm in `build_file`
  (`src/emo_cli/emo_cli.ml:166`; the arms run from `:186` for wasm to
  `:492` for riscv64). The smallest emitter is the TypeScript target,
  `emo_ts.ml`, 726 lines, emitting one `.ts` file; the largest
  single-language one is `emo_c.ml`, 3,230 lines, emitting `main.c` and
  `emo_defs.h` with the runtime riding the compiler as generated data
  (`emo_c_runtime.c`, 3,114 lines, plus a 445-line header, packed by a
  dune rule). A Lua target is `emo_lua.ml` plus a Lua port of the
  runtime, wired up with one dispatch arm, a doctor line, and a cache
  key — the same shape as every other target.
- **Emitter size.** The TypeScript emitter's 726 lines is a floor, not
  an estimate: TypeScript hands classes, `instanceof`, and string
  handling to the host language, while Lua has to build classes,
  interfaces, enums, and function groups out of metatables by hand.
  Budget 900–1,300 lines of OCaml.
- **Runtime size.** C 3,114, OCaml 3,715, TypeScript 2,414. Lua's own
  library is thin — no bytes type, no map, no date formatting worth the
  name — so a Lua runtime sits at the top of that range: 2,000–2,600
  lines.
- **Tests.** A `lua_goldens` list and runner in
  `test/emo_cli/emo_cli_test.ml` beside `c_goldens`, `wasm_goldens`,
  and `beam_goldens`; a golden suite in
  `test/emo_project/emo_project_test.ml`; and the 43
  `examples/*/expected.txt` files, which are shared. The house
  tradition that every target reproduces the interpreter's output
  byte-for-byte extends to an eighth implementation — and it is the
  expensive part here, because Lua's arithmetic and formatting defaults
  are not Emo's (see below).
- **Stdlib surface.** Package manifests gate per target
  (`targets = [...]`), and refusal is settled, accepted behaviour
  rather than a gap: ten of the seventeen registry packages are pure
  Emo and declare all five hosted targets, so they would work
  unchanged; `os`, `file`, and `bufio` declare `ocaml, c`; `net`,
  `http`, and `slog` declare `ocaml, c, typescript`; `sqlite3` is `c`
  only. A Lua target would implement the `os_*`/`file_*` group (20 and
  2 runtime implementations) or refuse it as TypeScript does —
  `ts_runtime.ts` implements no `os_*` or `file_*` runtime
  implementation at all.
- **CI.** The release matrix is four platforms (linux x86_64/aarch64,
  macos x86_64/arm64, `release.yml:26-32`); each would install a Lua
  interpreter, and Lua is the only candidate target whose *minor*
  version silently changes integer semantics.

## The version wall

This is the section that decides the question. README makes Int64
wrap-around a cross-target invariant — 64-bit two's complement on
every target, wrapping modulo 2⁶⁴, identically everywhere (README,
Numeric types, line 205) — and `docs/numeric-width.md` is the
reasoning behind it. Only two generations of the Lua lineage satisfy
that: **Lua 5.3 introduced a distinct 64-bit signed integer subtype**,
kept through 5.4 and 5.5, with two's-complement wrap-around on
overflow and native bitwise operators. Everything else in the family
has one numeric type, a double:

| Host | Lua | Integer subtype |
| --- | --- | --- |
| Neovim | LuaJIT 2.1 | no |
| OpenResty | LuaJIT 2.1 (`luajit2` fork) | no |
| Redis | 5.1 | no |
| Love2D | LuaJIT | no |
| Roblox | Luau | no |
| Wireshark | 5.2 | no |
| World of Warcraft | 5.1-derived | no |
| standalone | 5.4 / 5.5 | **yes** |

Every host a Lua target exists to reach is in the "no" rows. Emulating
64-bit integers on doubles is the two-word hi/lo scheme the
numeric-width settle records as **never taken** (CHECK.md, numeric
width); reviving it for the target whose whole point is the host
process would be the worst of both.

The version spread does not close on its own, either. Lua 5.5.0
(2025-12-22) reserves `global` as a keyword — an Emo identifier named
`global` would need sanitizing, where `sanitize_ident` today rewrites
only `?` — makes a `for` loop's control variable read-only, and breaks
binary chunk compatibility with earlier versions. Targeting 5.1
through 5.5 plus LuaJIT plus Luau is not one target; it is the Zig
churn tax with two extra dialect axes.

## Mechanism by mechanism

| Emo mechanism | Lua counterpart | Verdict |
| --- | --- | --- |
| Tagged value model (low-bit tags) | Lua's own dynamic values, one per Emo kind | smooth — Lua is dynamically typed and the encoding is the backend's business |
| Int64 wrap-around (cross-target invariant) | 5.3+ integer subtype | smooth at 5.3+, impossible below it — the version wall |
| `Float64` = IEEE 754 binary64 | Lua's number subtype / doubles | smooth, but see the last row |
| `Float64` rendered by OCaml's `%g` rule | `string.format` gives C's `%g` | friction: the BEAM runtime and the wasm host each hand-implement OCaml's rule, and C's is not it |
| String is a byte sequence | Lua strings are byte sequences | smooth — the one target where String's representation needs no encoding decision at all |
| `Bytes` (mutable) | Lua strings are immutable; no byte buffer | friction: a table of ints, or a userdata with `__index`/`__newindex` |
| `Array` | a table's dense 1..n part | smooth, with an index bias of one; Emo arrays are dense, so `#t` stays well-defined |
| `Tuple` | a table | smooth |
| `Map`, insertion-ordered and observable | a table, unspecified iteration order | friction — order is observable output (README:64, `examples/map/expected.txt`), so Map needs a side key array and hand-written iteration |
| `List` | table plus explicit head/tail discipline | smooth |
| `Box` | a one-element table | smooth |
| class / interface / enum / function group | metatables and `__index` | friction, but real encoding freedom: `is(Interface)` is structural on every target, so nothing forces a layout |
| Cooperative process model (`send` as an explicit yield point) | coroutines | smooth and structurally isomorphic — the C target's `ucontext` fibers play exactly this role |
| `receive` | yield/resume with an explicit scheduler | smooth; the interpreter's deterministic scheduler is the model |
| Proper tail calls | Lua guarantees them | smooth, and better than C (goto-rebind) or TypeScript (a driver loop with a recorded limitation) |
| `raise` ends the process; no `catch` construct | `error()` plus `coroutine.resume` returning `false, err` | smooth — the settled split needs one `pcall` at a coroutine's top, because there is no unwinding construct to implement |
| `foreign def` | C, through the Lua C API | refuse (see below) |
| printf byte-identical everywhere (README:68, C17 §7.21.6.1) | `string.format` delegates to C's `sprintf` | smooth — the one place Lua's C lineage pays off exactly where Emo needs it |

### Where Lua's arithmetic differs silently

Four rules differ from Emo's, each producing a wrong answer rather than
a diagnostic, and each needing a hand-written helper:

- **Division.** Emo's `/` truncates toward zero (`emo_div_i64`,
  `emo_c_runtime.c:2498`, with the `INT64_MIN / -1` guard returning
  `INT64_MIN`). Lua's `/` on integers yields a float, and Lua's `//` is
  *floor* division. `-7 / 2` is `-3` in Emo and `-4` in Lua.
- **Modulo.** Emo's `%` is the truncated remainder (`emo_mod_i64`,
  `emo_c_runtime.c:2504`); Lua's `%` is floored. `-7 % 2` is `-1` in Emo
  and `1` in Lua.
- **Right shift.** Emo's `>>` is arithmetic and sign-fills
  (`emo_shr_i64`, `emo_c_runtime.c:2618`; `docs/TASKS.md:445`); Lua's
  `>>` is logical and fills the vacant
  bits with zeros, and converts a float operand to an integer first.
  Every `>>` on a possibly-negative value needs the helper.
- **Float rendering.** Emo prints floats by OCaml's `%g` rule, which
  neither Erlang's nor JavaScript's native formatting matches — the
  BEAM runtime and the wasm host each hand-implement it. Lua's
  `string.format` delegates to C's `sprintf`, so it is available for
  printf and not, without checking, for floats: C's `%g` is not
  OCaml's.

## What a Lua target would refuse

- **`foreign def`.** The capability table admits `Float64`, `String`,
  and `Bool` on every target and reserves `Int64` and `Void` to `c`
  (CHECK.md, `foreign def` on non-native targets), and a bare symbol
  declaration has no Lua equivalent — Lua reaches C through the C API,
  which would mean a shim the backend emits and the user compiles.
  TypeScript, wasm, and BEAM all refuse foreign defs outright today; a
  Lua target joins them. (That wasm and BEAM refuse at the checker but
  carry no emitter-level guard is recorded separately in CHECK.md.)
- **`sqlite3`.** `targets = ["c"]` with `link = ["sqlite3"]` and
  package-carried native sources; nothing about Lua changes that, and
  the resolution gate is the first line.
- **`Bytes`.** Implementable, but at a real cost, since Lua strings are
  immutable and there is no buffer type.
- **`Int32`/`Float32`.** Not a Lua cost: the checker has no `Int32` or
  `Float32` at all today, so numeric width is the same story on every
  target.

One settled-by-nobody question a Lua target would inherit rather than
answer: README promises a snapshot copy of Map, Box, and List at the
process boundary (lines 195–198), while the `c` backend shares the
cell. The interpreter deep-copies. A new target has to pick a side, and
the divergence is recorded in CHECK.md as a decision to settle.

## The core dilemma

**A Lua target's whole point is the host process, and the host
processes are 5.1.** Every other Emo target produces a program that
owns its process. Lua's distinguishing value is the opposite: a `.lua`
file dropped into Neovim, OpenResty, or Redis and `require`d, running
beside code someone else wrote — which is what no current target does,
since even the wasm target needs the host to have a wasm engine. And
that is precisely the constituency that cannot honor the Int64
invariant. Compiling to standalone Lua 5.4 instead produces a program
slower than the C target's and less portable than the TypeScript
target's: it competes with Emo's own targets rather than reaching a new
host.

**The dialect space is crowded and partly abandoned.** MoonScript
(unmaintained for about a decade), YueScript, Teal, Fennel,
TypeScriptToLua, Haxe's Lua target, Amulet ML, Urn. "Emo compiles to
Lua" reads as one more entrant on that list. That conflicts with
nothing — the design philosophy governs Emo's surface, not its
substrate, and target independence is settled design — but it is an
explanation cost the C target does not pay, and it lands against the
industrial, systems, and embedded audience the project is built for.

A smaller concern, on the one axis Lua was expected to win:
**coroutines are cooperative but not uniformly yieldable.** Lua forbids
a yield across a C-call boundary; the continuation functions added in
5.2 and extended in 5.4 cover most library callbacks but not all, and
the exception set is a function- and version-level detail. An Emo
stdlib running on Lua must therefore not reach a `send` from inside a
callback the C library invoked.

## The cheaper alternative: an embedding surface, not a language

If the goal is "an Emo artifact inside a process someone else already
owns", the C target and the wasm target are much closer to it than a
Lua backend is, and neither has a version wall:

- **A documented C embedding ABI.** The C target already builds a
  single self-contained binary with a tagged value model and its own
  runtime; a published `emo_init` / `emo_call`-shaped surface would let
  a host embed Emo without generating anyone's source and without an
  interpreter on the host's side.
- **A documented wasm host interface.** The wasm target exists; what a
  host needs for embedding is a stated import/export surface, not
  another language.

This is a direction to evaluate, not a settled plan, and it is a
smaller step than a backend either way — the runtimes it would build on
are already written and verified.

## Recommendation

1. **Shelve the Lua backend.** Re-evaluation triggers, written down now
   so the bar is explicit: a concrete embedding host whose Lua is 5.3
   or later, or one that can move there; a language requirement only a
   Lua target serves; or evidence that Emo's users are in the
   Lua-dialect ecosystem. Absent one of those, the 5.1 floor and the
   crowded-dialect positioning stand.
2. **If the goal is embedding, evaluate the embedding surface
   instead** — a C embed ABI, or the wasm target's host interface — as
   its own small step. Same value, no version wall, and the runtime it
   builds on already exists.
3. **Nothing changes for the shipped targets.** This survey schedules
   no work on the interpreter, C, OCaml, TypeScript, wasm, BEAM, or
   riscv64. The three cross-target divergences it found along the way
   are recorded in CHECK.md as decisions to settle, not as work this
   assessment takes on.

The reusable finding worth keeping: truncating division, truncated
modulo, arithmetic shift, and OCaml's `%g` will each need a
hand-written helper on any host whose defaults differ. Lua differs on
all four at once, in the same direction — its operators are the
floored, logical, C-formatting branch of the family — which is why the
golden tier, not the emitter, would be the long pole.

## References

- Lua 5.4 reference manual: <https://www.lua.org/manual/5.4/>
- Lua 5.3 changes, introducing the integer subtype:
  <https://www.lua.org/manual/5.3/manual.html#8.1>
- Lua 5.5 reference manual: <https://www.lua.org/manual/5.5/>
- LuaJIT: <https://luajit.org/>
- OpenResty's `luajit2` fork: <https://github.com/openresty/luajit2>
- Luau: <https://luau.org/>
- Neovim's Lua guide: <https://neovim.io/doc/user/lua.html>
- Prior art: TypeScriptToLua <https://typescripttolua.github.io/>,
  Fennel <https://fennel-lang.org/>, Teal
  <https://github.com/teal-language/tl>, MoonScript
  <https://moonscript.org/>
