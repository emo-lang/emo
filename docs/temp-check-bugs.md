# Open bugs carried out of CHECK.md

Four open items, extracted 2026-11-24 from `CHECK.md`'s round entries. Each one
was reproduced by hand on this tree (the CLI rebuilt from the working copy);
none was pinned by a golden, which is why they stayed open. This file is a
working list, not a design document — the decisions belong in `CHECK.md`
until they are settled.

The numbers are stable: item 1 is closed and keeps its number, and items 5
and 6 were found on 2026-11-25 while closing it. **Open: 2, 3, 4, 5, 6.**

## 1. beam: a Pid does not render — closed 2026-11-25

Fixed; the decision and its verification are in `CHECK.md`'s entry of that
date. A Pid on the beam is now the emo number beside the BEAM's own pid, so
every door answers `<pid N>` the way the interpreter does, and
`examples/processes` is pinned in `beam_goldens`. The rest of the Pid family
on the other targets is item 5.

## 2. A mixed-kind refusal says something different on every target

**Symptom.** The width rule (settled 2026-11-24, `CHECK.md`) refuses an
Int64/Float64/Byte mix through the gradual path everywhere, but the refusal
text and mechanism differ:

| target | what a mixed addition answers |
|---|---|
| interpreter | `E3001: operator + expects two numbers or two strings, got Int64 and Float64` |
| typescript | the same sentence as an `EEmoException` |
| c | `runtime error: + needs two numbers or two strings` |
| beam | `{emo_bad_type, 7, 7.000000e+00}` |
| wasm | a bare trap (`RuntimeError: unreachable`) |
| riscv64 | `emo runtime: arithmetic on values of these kinds` |

**Where.** The interpreter and typescript name both kinds; the c runtime has
its own text; beam raises a tagged tuple; wasm's `rt_arith`/`rt_add`/`rt_cmp`
end in `Unreachable`; the metal calls `emo_fail` with a fixed message.

**The open question.** Unifying wants a message mechanism on wasm and beam —
wasm has `i_abort(ptr, len)` and the wasi cycle, the metal has `emo_fail` —
and a decision on whether the sentence includes the two kinds (the
interpreter's shape) or just the rule.

## 3. wasm: the gradual paths the shape tests never learned

Two gaps in the same family, both *loud* — neither answers a wrong value:

**(a) A field read on an unknown class refuses at build time.**

```
emo: internal error, uncaught exception:
     Failure("wasm: field read without a known class")
```

A class instance that arrives through a mailbox binding has no static class,
so `p.x` cannot pick a struct layout. The instance already carries its class
at run time (the `$vinst` struct's class field); the lowering needs a runtime
field walk — a chain of `ref.test` per class carrying the name, the shape the
builtin-method dispatch already uses — instead of the build-time failure, and
the CLI's internal-error exit (125) is the wrong surface for a program the
checker admitted.

**(b) The gradual Map has `get` and `length`, not the rest of its surface.**

```
emo build: wasm: method `has` has no static dispatch (in __recv_131,
self type: Unknown)
```

`get` (with `$vmap` ahead of the builder and Bytes arms) and `length`'s
`$vmap` count arm landed 2026-11-24; `has`, `keys`, `values`, `set`, and
`remove` still refuse by name at the build. Their static arms exist — each is
a `$vmap` test plus the runtime function the static path already calls.

**Repro.** `m.get("k")` off a mailbox Map answers; `m.has("k")` on the same
binding refuses at the build. A sent instance's `p.x` refuses at the build.

## 4. riscv64: three open walls

**(a) A `Bytes` is a permanent bump cell.** The metal's bump allocator never
gives bytes back, and the crypto engines construct per operation
(`Bytes.new(80)` per field element in Ed25519, a fresh digest buffer per
PBKDF2 round). `crypto_sign`, `crypto_sign_sweep`, and `crypto_kdf` therefore
die of arena exhaustion mid-pass — every line they print is byte-correct, the
memory model is the limit. The counted-`Bytes` experiment was attempted and
rolled back: the deaths moved to the tail crossings (a tail call retains for a
frame that dies at the jump) and then to the entry edges (spawn thunks and
assembler-entered services park no marker). The shape the next round should
start from is the registration-by-refcount variant: pool-register a parameter
only when its count already sits above one, so a tail crossing's claim is the
only thing a drain gives back. It needs no register, no ABI, and no marker.

**(b) A cross-process Array copy is written out of bounds.** A worker that
receives an Array and writes into it (`a[i] = v`) dies
`emo runtime: index out of bounds`, while the same literal write inside one
process works (the probe prints `[1, 20, 3]`). The break is the copy's shape —
`emo_send`'s `emo_copy_deep` or the receive-side re-copy — so the received
array is not the array the sender's word describes. The same family as the
hash twin's metal-Array wall.

**Repro.** The array-mutability probe: sender writes 77 into its own binding
after sending, worker writes 55 into the received copy and sends it back; the
interpreter, c, typescript, wasm, and beam answer `[55, 2, 3]` then
`[77, 2, 3]`, the metal dies at the worker's write.

**(c) The dock's hover is one digest off.** The metal's `paint_tile` hover
byte disagrees with the corpus by one digest; the corpus's own tile and
`tiler` rows pass. The single byte the carve and the canvas disagree on has
not been found, and the dock's hover is parked on the metal until it is.

**Where.** `emo-desktop` M32's record (`CHECK.md` 2026-11-20): "the dock's
hover parked on the metal, the walk's strip one digest off the corpus's, the
byte the carve and the canvas disagree on unfound."

## 5. The rest of the Pid family, off the beam

Found 2026-11-25, while checking item 1's fix against every hosted target
with one probe. None of it is the beam's rendering, and none of it is pinned.

**typescript — a Pid equals nothing, not even itself.** `self_pid() ==
self_pid()` prints `false`, and a process sending back its own pid compares
`false` against the spawner's handle, so a `receive` guard `who == a` falls
through to the next branch. `E.self()` builds a fresh `EPid` on every call,
and the equality answers `a === b` for two of them — it has an arm for the
Float, Char, Builder, Enum, Bytes, Map, and List, none comparing `id`
(`ts_core.ts`). Beside it, `pid.to_string()`
raises `NoMethodError: '<pid 1>' has no method 'to_string'`; `println` and
interpolation render right.

**wasm — the root is pid 0, and it prints as one.** `println(self_pid())`
prints `0`, not `<pid 1>`; equality holds. The scheduler suite's own pid
program (`theirs == pid` inside a receive branch) dies at the build with exit
125: `Failure("wasm: unbound local pid in __recv_131 …")` — the entry binding
is not visible to the receive handler.

**c — `examples/processes` is not byte-identical.** `low` and `high` arrive
as `1` then `5` (`expected.txt` says `5` then `1`), and the six carriers end
in `runtime error: deadlock: 1 process(es) waiting`, exit 70 — the entry
cannot join `c_goldens` yet. Two smaller refusals on the same probe: a
`receive` guard naming a pattern-bound variable (`who == a`) — "does not
support the variable `who` here yet" — and `do` of a block value — "does not
support spawning a first-class block yet yet" (the word is doubled).

**beam — an all-blocked program waits forever.** A top-level `receive` with
no process left to answer: the interpreter raises E3012 and exits 70; on the
beam the `receive` has no `after` and never returns.

**Where the beam does hold.** The same probe's 23 lines — numbering through
a child's own `do`, identity across the boundary, a dead pid, List, Tuple,
Map, and Box carriers, a loop's spawns, a block-value spawn — are
byte-identical to the interpreter's on the beam, and c matches once the block
spawn is removed.

## 6. An entry binding that a const's initializer reads lowers to a type name

**Symptom.** A const the entry keeps as a plain binding — its initializer
holds a `do` — reads back as an atom when another const's initializer names
it.

```
def worker(boss Pid) {
  boss <- 1
}

const a = do worker(self_pid())
receive {
  n then {}
}
const wrapped = { "k": a }
println(wrapped.get("k") == a)
println(wrapped.get("k"))
```

| target | what it answers |
|---|---|
| interpreter | `true`, then `<pid 2>` |
| typescript | `false`, then `a` |
| beam | `false`, then dies `{emo_no_to_str, a}` — an atom has no render |
| c | refuses at the build: `does not support this expression form (Type_ref) yet` |

**Where.** `lower` in `src/emo_ir/emo_ir.ml`: an entry-module const keeps its
plain binding when its initializer is `thunk_unsafe` — it holds the spawn
marker, or names a top-level binding made by destructuring. The rule that
keeps a *mentioning* const plain covers only the destructured names, so a
const thunk reading a spawn-initialized const finds no symbol for it and
`Ast.Ident` falls to its last arm, `Type_ref name`. Every compiled target
takes that path; only the interpreter's own walk resolves the name.

**Why it stayed hidden.** E5016 refuses the same read from a `def` on every
target ("a top-level const whose initializer reads another script binding (or
a `do`) cannot become the module const a def could call"). A const's
initializer is the one reader it does not cover, and `examples/processes`
reads its `gone` only from entry statements.
