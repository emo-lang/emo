# Open bugs carried out of CHECK.md

Four open items, extracted 2026-11-24 from `CHECK.md`'s round entries. Each one
was reproduced by hand on this tree (the CLI rebuilt from the working copy);
none was pinned by a golden, which is why they stayed open. This file is a
working list, not a design document — the decisions belong in `CHECK.md`
until they are settled.

The numbers are stable: items 1, 2 and 3 are closed and keep their
numbers, items 5 and 6 were found on 2026-11-25 while closing item 1,
items 7 and 8 while closing item 2, and item 9 while closing item 3.
Item 4's (b) closed the same day and item 9 with them; its (c) was refuted
(there is no disagreeing byte — the parked note compared the live dock's
strip against a corpus chain with a different starting state); its (a) is
closed for the crypto engines and open again for the desktop corpus, whose
gate faults on a `Bytes` crossing a spawn/exec boundary. Item 5 closed the
same day, and its beam deadlock end (E3012) closed with it on 2026-11-26.
Item 10 was found while closing item 9.
**Open: 4 (a, the desktop edge), 6, 7, 8, 10.**

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

## 3. wasm: the gradual paths the shape tests never learned — closed 2026-11-25

Fixed on wasm — and on the beam, which turned out to carry the same
field-read gap.

**(a) A field read on an unknown class** lowers through the runtime now:
one `ref.test` per class on wasm, one pattern per class on the beam (an
instance there is `{'emo_inst', ClassAtom, fields…}`). A class carrying the
field reads its own slot; a class without it, and a value that is not an
instance, answer the interpreter's own words — `` `Point` has no field `z`
`` and "a member access must be a call, like `x.read()`" — where the build
used to die with an internal error (exit 125). Inside a class member the
read no longer assumes the receiver is `self`: the old code read any open
receiver at self's class, an internal error when self's class lacked the
field and a failed cast on wasm when it had one.

**(b) The gradual Map's whole surface** — `has`, `keys`, `values`, and
`set` beside the two doors that already answered — takes the Map's door
through a `$vmap` test, and a receiver that is not a Map answers the
interpreter's words (`Int64 has no method `has`` for a value, ``NoMethodError:
`Point` has no method `has``` for an instance).

| target | a sent instance's `p.x` | a field no class carries |
|---|---|---|
| wasm | `3`, `4` | `ABORT: `Point` has no field `z``, exit 1 |
| beam | `3`, `4` | `runtime error: `Point` has no field `z``, exit 70 |

The decision and its verification are in `CHECK.md`'s entry of that date;
`cross_target_gradual` pins six rows across the two. What the round found
on the way and left is item 9.

## 4. riscv64: three walls — (b) closed, (c) refuted, (a) closed for the crypto engines and open again for the desktop corpus (2026-11-25)

**(a) A `Bytes` is a permanent bump cell — closed for the crypto engines,
open again for the desktop corpus (2026-11-25).** A `Bytes` is a counted kind
now: kind 10 keeps its tag, the header's high half carries the refcount, and a
release that reaches zero goes straight to the freelist — the cargo is raw
bytes, so there is no holdings walk. The birth serves the freelist first and is
born with one claim, the two copy paths (`emo_copy_deep`'s snapshot,
`emo_copy_out`'s receive) settle a clone's count explicitly instead of copying
the source's, and the emitter treats a `Bytes` the way it treats an identity: a
birth pools, a read claims, every container store retains (the array literal's
fill, `Set_field`, an element write, a Map's entries, and the runtime's own
word-copying stores — the builder's tagged push and `to_array`, the append, the
Map's `keys`), and a non-self tail jump that carries a claim-bearing word takes
the plain road instead, because the callee borrows and a link claim would
outlive its owner.

Measured on the demos' own engines:

| measure | before | after |
|---|---|---|
| `Bytes.new(80)` in a loop, per iteration | 96 B | 0 |
| `crypto_sign`'s whole run | 13.5 MB (dead at the 8 MiB grant) | 58 KB |
| the three blocked demos at 8 MiB | 11 / 1 / 0 lines, then `the value heap is exhausted` | 21 / 13 / 2 lines, byte-identical |

Three pre-existing bugs the counting flushed, each fixed:

- **The constructor took the instance's claim twice** — the birth, an explicit
  entry retain, and the caller's retain, one of which the exit's unwind gave
  back. No constructed object could reach zero, so every construction leaked
  its instance and (through the walk) its fields.
- **The emitter's bound list was never pruned at a block's exit.** A name bound
  by a `const` stayed "already bound" past its scope, so a sibling block's
  same-named binding took the write barrier over a dead slot — releasing a
  block nobody owned, which the freelist then handed out twice (item 9's Map).
- **Three statements under-counted their temp depth** — `Assign_index`, `Raise`,
  and the children of `Make_exception`, `Bytes_new` and `Map_lit` — so a deep
  initializer could write past the frame's slots.

**What the desktop corpus then found.** `projects/emo-desktop/fb/check.sh` is
green where it measures bytes (interpreter, ocaml, c, typescript, wasm; its
eight red rows are the beam leg's timeouts, the tree's own long-standing
`frame`-family hang, and they are red on the tree before this round too). The
EmoOS smoke case is red, and on this tree it is red
*earlier* than on the tree before this round: the boot's shell presents its
second frame and then a pass faults inside `emo_release_walk` (`user fault 25
cause 13 at 0x871004ac addr 0x83890008`). Two temporary diagnostics narrowed it
(both reverted): the faulting instruction disassembles to `ld a0, 0(t6)` in the
walk's field/captures loop — the recursive release of a counted block's
holdings running off the arena's end page — and the block, printed with its
slot's own words, stands **below the pass's `end` but above its `cursor`**: an
address inside the pass's arena that this pass never allocated, i.e. a stale
pointer into a run the allocator had handed on. Before this round that release
was a no-op for a `Bytes`, so nothing was dereferenced; now it is, and the
stale word's "count" walks the fields past the run. So the counting is not the
bug — it surfaces a pre-existing stale counted word on the desktop's
spawn/exec path, one the gate alone exercises. The crypto engines, the 26 metal
goldens and `native_image` are all still byte-identical, so the counting itself
holds; what is open is that stale word. The gate also carries two pre-existing reasons to be red, reported
for the record: its kernel copy list was missing the eight files `user.S`
incbins (fixed in `test/emo_os` this round), and run.sh still pins the frame
budget at `frames 1918 1674` while the tree counts `1925 1681`.

**(b) A cross-process Array copy is written out of bounds — closed
2026-11-25.** The copy was sound: the worker read `[77, 2, 3]` and its length.
The death was `a[i] = v`'s own lowering — the index rode a temp register across
the value's evaluation, and a value that allocated (a call, a box, a nested
read's own index) left the arena cursor or a stray word there, so the bounds
check read it and refused or wrote the wrong slot. The index now spills into a
frame slot of its own before the value evaluates. `a[0] = five()`,
`a[i] = i + 40`, a native frame's `a[0] = 55` and `a[1] = a[0]` all died or
miswrote; a literal value in a dynamic frame was the one shape that survived,
because nothing allocated between the two reads.

**Repro.** The array-mutability probe: sender writes 77 into its own binding
after sending, worker writes 55 into the received copy and sends it back; the
interpreter, c, typescript, wasm, beam and now the metal answer `[55, 2, 3]`
then `[77, 2, 3]`.

**(c) The dock's hover is one digest off — refuted 2026-11-25: there is no
such byte.** The premise was that the metal's carve and the hosted canvas
disagree on one pixel of a hovered tile. Measured directly: a kernel-profile
program paints the golden's own chains onto a `ui_fb_winbuf.Win` over plain RAM
(the carve's `carve_*` walks, the same ones the desktop calls) and folds the
strip with `ui_fb_frame.digest`/`round_digest`. Every digest the corpus pins
comes back:

| chain | corpus | carve |
|---|---|---|
| the desk era's three `paint_tile` rows | `2705446303`, `1028097810`, `1695040239`, `tiler 1222847109` | identical |
| the launcher's hover row, lifted | `532476419`, `2615177506`, `tiler 1465435319`, `329071474` | identical |

The same program built with `c7645471` prints the same numbers, so the two
painters have always agreed when they start from the same strip. What the
parked note compared was the **live** dock buffer's walk digest against a
corpus chain that starts from a strip the golden painted — different starting
states, therefore a different digest, and no disagreeing pixel anywhere. The
hover stays parked because run.sh asserts only the ten `frame` rows; un-parking
it needs a corpus row for the state the desk loop is in at the beat (or a beat
that repaints the strip first), a corpus addition rather than a fix.

**Where.** `emo-desktop` M32's record (`CHECK.md` 2026-11-20): "the dock's
hover parked on the metal, the walk's strip one digest off the corpus's, the
byte the carve and the canvas disagree on unfound."

## 5. The rest of the Pid family, off the beam — closed 2026-11-25 (the beam's deadlock end closed 2026-11-26)

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

**Fixed 2026-11-25 — typescript, wasm, and c.** The typescript runtime's
deep-equality gained the EPid arm (`a.id = b.id` — `E.self()` builds a fresh
EPid per call, so the object identity `a === b` was always false across
calls) and the dispatch's `to_string` answers `<pid N>`; `println` and
interpolation rendered right already. The wasm's value model gains the
**$vpid shape** — the Pid used to BE an Int64, so `println` printed `0`
where the interpreter prints `<pid 1>` — with two consequences the shape's
own words record: the struct is two words because a lone mutable i32 is
$vchar's exact shape and the engine's canonical maps would let `ref.test
$vchar` claim a Pid (the char arm then rendered the pid number as a code
point — the NUL-and-U+0001 prints the probe caught); and the root numbers
itself 1, the first spawn 2, the interpreter's count. The family now answers
`<pid 1>` / `true` / `false` / `true` / `<pid 2>` / `<pid 2>` byte-for-byte
on typescript and wasm, pinned in the `pid_spawn` group. **And the c
target's three refusals were one bug and one gap:** a receive guard naming
a pattern binding (`who == me`) refused because the scan had no bindings —
the scan now *peeks* the candidate's projections (borrowed, the candidate's
own claim covers the read; the branch body's assignment takes the claims
that live past the take) — and that same peek fixed `examples/processes`
byte-for-byte on c (the guards' stale reads were the wrong low/high order
and the six carriers' deadlock), while `do blk(..)` spawns the closure
value (the block rides the spawn's arguments as word 0, the child calls it
through the runtime's `emo_closure_callN`, 4 args at most). The
spawning-a-first-class-block refusal and its doubled word retire with the
lowering.

**The beam's deadlock end closed 2026-11-26, on the second attempt.** The
rolled-back first build raised from inside the polled gate's after-arm and
hung the VM (`erlang:raise/2` answers `undef`; the doors use
`erlang:error/1`, and switching did not help — the pieces live in
`protected/tmp/20261125-*emo_beam-gate-error1.ml`). The landed gate never
raises from the after-arm. The receive lowers to one hoisted gate function
(`__recv_gate_N`, its parameters carrying every binding live at the
receive, the loop continuations' threading); a scan with no matching
message parks 1 ms, marks the process in the `emo_blocked` set, and — when
the set's size reaches `emo_procs`'s — answers `{'emo_deadlock', Ref, N}`,
with N read at the poll (the frozen total: equality means every registered
process is parked or in the poll's own window, so nothing can run, send,
or exit and the count cannot move). The statement site matches the tuple
against its own `make_ref` and calls `emo_runtime_fail` **directly** —
print + `halt(70)` at the first detector, whichever process it is. The
envelope route (raise, let `main`'s arm print) loses twice: a child
detector dies unregistered before the root can poll, shrinking the
sentence's count, and the raise itself was the first build's hang. The
mark persists through the wait and comes down only at a matching delivery
(`emo_send` unmarks the receiver — a send makes the receiver runnable, the
interpreter's own rule), a consumed branch (the door's unmark), or the
process's exit (`emo_unreg`); the false arm re-enters the gate without
unmarking, and the re-entry rescans the mailbox first. The spawn registers
the child in the parent (`emo_spawn_and_reg`, before the parent can park),
the tables are created at `main` (a simultaneous first park double-created
`emo_blocked` and badarg'd), the root registers itself and unregisters on
its way out (`emo_root_exit`, so the kill sweep spares the process running
it), and the atomic holder keeps its old no-registration (it parks forever
in a hand-written receive; a row would keep the sizes apart forever) while
its spawn drops the dead `self()` that drew erlc's "no effect" warning on
every beam build.

Core Erlang grammar facts the landing pinned: bare parentheses are not a
form (every `(case … end)` in the working corpus is an `apply`/`call`
argument list), an `apply` to a module-level function needs its arity
label (`apply 'f'/2 (…)` — the bare name is letrec-local), and a `receive`
carries no `end` while a `case` does. `fresh_var` pushes its name onto the
local map as a side effect, so the gate's enclosing-map snapshot must be
taken before the gate's parameters are minted.

Verified: a lone parked process says `runtime error: all 1 waiting
processes are blocked; no message will ever arrive`, exit 70 (the
interpreter's E3012 sentence in the beam's own envelope); three parked
processes say 3; the ping-pong probe (`<pid 1>`, `<pid 2>`, `false`,
`true`, `ping`) is byte-identical with the interpreter five runs over; the
`processes` and `atomic_cell` examples are byte-identical with their
expected files; a program with one child spinning forever never hears the
sentence.

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

## 9. riscv64: a Map never answers — closed 2026-11-25

Fixed by item 4's round, and its symptom was the clue that named the bug.

**Symptom (as filed).** A program that constructs a Map literal never printed
again:

```
const m = { "a": 1 }
println("built the literal")
```

printed nothing under QEMU and never returned, and a Map sent to another
process parked its sender inside the send. The control through the same
mailbox, an Int64, answered.

**Cause.** The metal's freelist had a cycle: a block released twice entered the
list twice (the constructor took its instance's claim twice, and the emitter's
bound list outlived its block, so a sibling scope's write barrier released a
dead slot's word). The Map's own birth — the first allocation wide enough to
walk past the corrupted head — looped forever inside the freelist scan, which
is why the literal never returned and why *every* door behind it hung while a
scalar message answered. The same corruption explained item 4's (b) crash.

**Verified.** With the double release gone the whole surface answers the
interpreter: `length`, `get`, `has`, `keys`, `set`, `remove` — `2, 1, true,
false, [a, b], 3, 10, 2, false, [a, c]` — pinned in the `metal_memory` group
("a Map literal's doors answer on the metal"). A compiler built from
`c7645471` still hangs the same way (QEMU killed at 60 s, no output), so the
round is what closed it.

**What is still missing on the metal:** a Map's *rendering*. `println(m)` and
`println(m.set("a", 10))` answer `cannot convert this value to a string yet` —
`emo_to_string` has no Map arm there. Recorded as item 10.

## 10. riscv64: a Map has no rendering

**Symptom.** `println(m)` and `println(m.set("a", 10))` — a Map through any
door that answers the Map itself — refuse at the run: `emo runtime: cannot
convert this value to a string yet`. Every other target renders a Map as
`{"a": 10, "b": 2}` and the interpreter's own order.

**Where.** `emo_to_string`'s kind dispatch in `src/emo_codegen/emo_riscv.ml`
has arms for the numerics, the String, the Tuple, the Array, the Bytes, the
builder, the Atomic, the Pid and the instance; kind 13 (Map) falls to the
refusal. The fix is one arm over the entries array `emo_map_keys` already
walks, in insertion order, with the key's and the value's own `to_string`.

Found 2026-11-25 while closing item 9 (the doors answer now; the rendering
never did).
