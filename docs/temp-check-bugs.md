# Open bugs carried out of CHECK.md

Four open items, extracted 2026-11-24 from `CHECK.md`'s round entries. Each one
was reproduced by hand on this tree (the CLI rebuilt from the working copy);
none was pinned by a golden, which is why they stayed open. This file is a
working list, not a design document — the decisions belong in `CHECK.md`
until they are settled.

The numbers are stable: items 1 and 2 are closed and keep their numbers,
items 5 and 6 were found on 2026-11-25 while closing item 1, and items 7 and
8 while closing item 2. **Open: 3, 4, 5, 6, 7, 8.**

## 1. beam: a Pid does not render — closed 2026-11-25

Fixed; the decision and its verification are in `CHECK.md`'s entry of that
date. A Pid on the beam is now the emo number beside the BEAM's own pid, so
every door answers `<pid N>` the way the interpreter does, and
`examples/processes` is pinned in `beam_goldens`. The rest of the Pid family
on the other targets is item 5.

## 2. A mixed-kind refusal says something different on every target — closed 2026-11-25

Fixed. The question this entry left open — the interpreter's shape with both
kinds, or just the rule — went to the interpreter's shape: every target now
answers the interpreter's own sentence for `+ - * / % < <= > >= & | ^ << >>`
and the unary `-` and `~`, each in the envelope it already had.

| target | `println(i + f)` through a mailbox binding | exit |
|---|---|---|
| interpreter | `error[E3001]: operator `+` expects two numbers or two strings, got Int64 and Float64` + the source span | 70 |
| ocaml | `Fatal error: exception Failure("operator `+` expects …")` | 2 |
| c | `runtime error: operator `+` expects …` | 70 |
| typescript | `error[E3010]: uncaught exception: operator `+` expects …` | 70 (it was 0) |
| wasm | `ABORT: operator `+` expects …` | 1 |
| beam | `runtime error: operator `+` expects …` | 70 |
| riscv64 | `emo runtime: operator `+` expects …` | the image's fail tail |

The decision and its verification are in `CHECK.md`'s entry of that date;
`cross_target_refusal` pins three rows on five targets. What the round found
on the way and left is item 7.

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

## 7. What the operator round found and left

Found 2026-11-25 while closing item 2, each one reproduced by hand on the
seven targets. None of it is the mixed-kind sentence — that one is the
interpreter's everywhere now — and none is pinned.

**(a) The envelope is still each target's own.** The sentence is one; the
prefix, the code, and the exit status around it are not (the table is in
item 2). On the beam only the operator family is clean: every other runtime
refusal there still dies as an Erlang crash report, and a spawned process's
report is written to *stdout*.

**(b) A refusal inside a spawned process ends a different thing.** The same
`i + f` in a `do` process: the interpreter and typescript end the offending
process silently and the root goes on — the interpreter's root then deadlocks
with E3012 once it waits for the message, typescript exits 0 with nothing
printed; ocaml, c and the metal end the whole program with the sentence;
beam prints an `=ERROR REPORT====` on stdout carrying the sentence and the
root goes on — forever, when it was waiting for the message. wasm refuses the
program at the build (a `receive` must be the last statement of its body).

**(c) The boolean operators are the one family still in every target's own
words.** `!"s"` through a mailbox binding:

| target | what it answers |
|---|---|
| interpreter | `error[E3001]: operator `!` expects a Bool, got String` |
| c | `runtime error: a value of the wrong type was used where a type was expected` |
| ocaml | `Fatal error: exception Failure("expected Bool, got String")` |
| typescript | prints `true`, exit 0 |
| wasm | `RuntimeError: illegal cast` |
| beam | `{emo_bad_type,<<"s">>,<<"s">>}` |
| riscv64 | prints `1Bytes[]`, exit 0 |

`s && t` answers the same way where it refuses — the interpreter says
"operator `&&` expects two Bools, got String", naming the left kind alone —
and typescript and beam print `false`; the metal refuses `&&` on a dynamic
value at the build. `t || s` is `true` everywhere: the right side never runs.

**(d) Three wrong answers and one early death in the same operators.**
`7.5 % 7.5` as mailbox Floats answers `0.0` on the interpreter, typescript and
beam, `nan` on c, and `7.5` on wasm; the metal refuses a dynamic `%` at the
build. c refuses the static form too — `7.5 % 2.0` does not build there
("does not support this Float64 operation yet") where the interpreter, ocaml,
typescript and beam answer `1.5`. A Byte shift by a count at or past eight —
`3 << 70` as mailbox Bytes — answers `0` on the interpreter, ocaml, typescript
and beam, `192` on wasm. A gradual Float's negation on c — `-f` — dies
"runtime error: a value of the wrong type was used where a type was
expected": the checker types the result Int64 and c unboxes the Float answer
as one.

**(e) A Char reads as a String in the beam sentence.** `ch + i` says "got
Char and Int64" on six targets and "got String and Int64" on the beam, where
a Char is its UTF-8 bytes.

**(f) The build refusals are unchanged.** c refuses the bitwise operators
and `~` on a dynamic value ("does not support the bitwise operators in the
dynamic world yet"); the metal refuses `/`, `%`, the bitwise operators and
`&&`/`||` on one ("does not support this operator on a dynamic value yet").

**(g) The c emitter warns on an unused receive binding.** A tuple binding
the body never reads lands as a variable: `warning: variable 'b__r1_0' set
but not used [-Wunused-but-set-variable]`, three to a probe.

## 8. The TLS hint names a flag form the build rejects

**Symptom.** When the c target cannot link OpenSSL, `emo build` says to pass
`--cclib -L<dir> --cclib -lssl --cclib -lcrypto`. Given exactly that, the
build answers `emo: unknown option -L<dir>`. The option takes its value
through `=` — `--cclib=-L/opt/homebrew/opt/openssl@4/lib` builds
`examples/http_roundtrip` — and the help spells it `--cclib=LIB`, "link
against C library (-lLIB)".

**Where.** The fix message in `src/emo_cli/emo_cli.ml` (the TLS link
failure) and the comment above it in `src/emo_codegen/c/emo_c_runtime.c`
("rides --cclib -L<dir>"). The suite never meets it: it passes the flags
through `build_file`'s `cclibs`, not the command line.
