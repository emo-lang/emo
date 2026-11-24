# Open bugs carried out of CHECK.md

Four open items, extracted 2026-11-24 from `CHECK.md`'s round entries. Each one
was reproduced by hand on this tree (the CLI rebuilt from the working copy);
none is pinned by a golden today, which is why they stayed open. This file is
a working list, not a design document — the decisions belong in `CHECK.md`
until they are settled.

## 1. beam: a Pid does not render

**Symptom.** `println(pid)` dies `{emo_no_to_str, <0.87.0>}` on the beam target.

**Where.** `emo_to_str` in `src/emo_codegen/emo_beam.ml` has arms for the
integers, floats, binaries, the Bytes/List/Builder/Map/Array/Box/Atomic tags,
enums, tuples, and instances — no pid arm, so an Erlang pid falls to the
`{'emo_no_to_str', _other}` error.

**Repro.** `examples/processes` on the beam: the program now runs to its last
two lines and dies on `println(gone)` (the entry is not in `beam_goldens`, so
no pin caught it). The c target's `println` of a Pid lowers to
`emo_println_pid` and answers `<pid N>`.

**The open question.** The other targets print the *emo* pid number
(`<pid 7>`), and that numbering is theirs — on the beam a Pid is the Erlang
pid, whose own print form is `<0.87.0>`. Rendering it needs either a
target-specific spelling (the target's own pid text) or a logical pid carried
beside the Erlang pid (an extra cell in every spawn path). The interpreter,
c, and the metal share one spelling today; the beam does not.

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
