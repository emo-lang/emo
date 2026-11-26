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
closed for the crypto engines and, since 2026-11-26, the desktop corpus
too — the stale word the desktop gate surfaced was the release walk's
field loop losing its cursor across a nested walk, and the fix turns the
gate green on both legs. Item 5 closed the
same day, and its beam deadlock end (E3012) closed with it on 2026-11-26.
Item 6 closed on 2026-11-26. Item 10 was found while closing item 9.
Item 7's boolean operators, wrong answers and c warning closed on
2026-11-26; its (a), (b), (e) and (f) stay open inside the item.
Items 8 and 10 closed on 2026-11-26, and item 4's (a) closed with them —
the EmoOS smoke is green on both legs. Item 7's (a) closed 2026-11-26 —
the beam's every runtime refusal now rides the envelope (stderr,
`runtime error: …`, exit 70, no crash report); 7(b)'s death scope closed
the same day (the beam already answered, c and ocaml scoped their
children, the metal's split rides the proven death machinery — wasm's
constraint stands); 7(e) closed too — the sentence already named the
Char and printf's `%c` learned the tagged shape. **Open: 7 (f).**

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

## 4. riscv64: three walls — (b) closed, (c) refuted, (a) closed 2026-11-26

**(a) A `Bytes` is a permanent bump cell — closed for the crypto engines
and the desktop corpus (2026-11-26).** A `Bytes` is a counted kind
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

**What the desktop corpus then found — and the stale word closed 2026-11-26,
below.** `projects/emo-desktop/fb/check.sh` is green where it measures bytes (interpreter, ocaml, c, typescript, wasm; its
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
holds; what was open was that stale word.

**The stale word, found and fixed (2026-11-26): the release walk's field
loop kept its cursor and count in caller-saved t5/t6 across a recursive
`call emo_release`, and a field that is itself a Closure or Instance runs
the same walk — the nested walk set t5/t6 for *its* block, and the outer
loop resumed on the inner block's cursor and count.** The desktop's view
trees nest instances, so the shell's root pass (pid 1) resumed its walk at
a field block near the arena's top and walked its remaining "fields" off
the run, faulting at the arena's end page. The evidence: a probe on the
walk's field loop printed, for every nested re-entry, `ra` back into the
loop itself (0x8710055e), and a probe on emo_release's entry printed the
released "words" — a String's raw bytes (`b minus\0`), raw doubles
(16.0, 32.0, 64.0) and packed immediates — i.e. a block's payload read as
fields. The fix is the Map arm's own pattern, which already saved s-regs
because "the release takes every temp it finds": the field loop now runs
in s2 (cursor) / s3 (count) on a sub-frame and reloads what it needs
before the freelist push. The walk's t1 (serving slot) was being clobbered
the same way and is now taken from the release frame at the push.
`projects/emo-os/run.sh`'s frame pin was stale (`frames 1918 1674` against
the tree's `1925 1681`, red before this round) and is updated; with the
fix the EmoOS smoke is **green on both legs** (legacy set_timer and sstc
stimecmp, every assertion through `frames 1925 1681` and self-exit), and
`examples/processes`, `examples/atomic_cell` and `examples/language_tour`
are byte-identical with their `expected.txt` on the metal. The kernel copy
list (the eight `user.S` incbins) was fixed earlier in `test/emo_os`. The
gate also carries one pre-existing reason to be red, reported for the
record: nothing left — the pin was the last one and it is a stale corpus
number, not a defect.

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

## 6. An entry binding that a const's initializer reads lowers to a type name — closed 2026-11-26

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

**Fix (2026-11-26).** The plain-kept set is a closure now, on both sides
that mirror it. In `lower`, `entry_script_names` seeds with a
destructuring's names and a `var`'s (both statement-scope locals a thunk
cannot see — a const reading a `var` was the same hole one shape over),
then adds every const whose initializer holds the spawn marker or names a
seeded or already-added name, until it stops growing; the file is scanned
whole, so declaration order never matters. `thunk_unsafe` tests that set,
so a const mentioning a plain-kept const keeps its own plain binding — the
value exists only after the entry's statements run, and no module-level
thunk could ever read it. The checker's E5016 scan
(`script_invisible` + `script_grow` in `check_items`) computes the same
closure from the same shapes, so a `def` reading the transitively plain
const is refused exactly like one reading the spawn-initialized const —
before the fix such a read resolved to the broken thunk and died at build
or at run, target by target.

**Verified.** The documented probe answers `true` then `<pid 2>` on the
interpreter, typescript, the beam, and c (c used to refuse the build with
`does not support this expression form (Type_ref) yet`); the `var` chain
(`var n = 5; const m = n`) snapshots `5 / 5 / 6` on the interpreter and c
alike; `def peek()` reading `wrapped` and `a` draws two E5016s, and the
direct `a` read keeps its own; `examples/processes` and
`examples/atomic_cell` stay byte-identical with their `expected.txt` on
the beam and the interpreter. A const initializer reading a *later* const
is E4003 at the checker regardless (forward reference), so the closure's
order-independence is load-bearing only for the lowering's whole-file
scan. The dune suite was not run.

## 7. What the operator round found and left — (c), (d) and (g) closed 2026-11-26

Found 2026-11-25 while closing item 2, each one reproduced by hand on the
seven targets. None of it is the mixed-kind sentence — that one is the
interpreter's everywhere now — and none is pinned. The boolean operators,
the three wrong answers and the c warning closed on 2026-11-26; (a), (b),
(e) and (f) stay below with the reasons.

**(a) The envelope is still each target's own — open.** The sentence is
one; the prefix, the code, and the exit status around it are not (the
table is in item 2). The boolean operators joined the clean family this
round; every other runtime refusal on the beam still dies as an Erlang
crash report, and a spawned process's report is written to *stdout*.
Routing the rest through the `{'emo_runtime_error', Bin}` door is its
own round — the raise sites are scattered across the runtime helpers.

**(b) A refusal inside a spawned process ends a different thing.** The same
`i + f` in a `do` process: the interpreter and typescript end the offending
process silently and the root goes on — the interpreter's root then deadlocks
with E3012 once it waits for the message, typescript exits 0 with nothing
printed. **The death scope closed 2026-11-26 — every target now answers the
interpreter's shape.** The beam already did: the child's refusal rethrows
out of the child, whose death is silent (no `=ERROR REPORT====` on stdout —
that report is gone), and the root's wait ends in the deadlock gate's own
E3012, byte-identical with the interpreter. The c runtime's fatal split
follows its raised-exception path's own precedent (T23.6): a spawned
process's refusal ends only that fiber, silently, through
`emo_process_halt_current`; the root's is the program's outcome — and its
deadlock sentence aligns with the interpreter's (`all N waiting processes
are blocked; no message will ever arrive`, exit 70). The ocaml scheduler's
effect handler gained the `Failure` arm the runtime helpers' refusals
ride: a spawned process's ends with `Exit_failed` (the scope
`Emo_eval.Error` already answered), the root's keeps raising. The metal's
`emo_fail` splits on the slot: a spawned pass's refusal ends that pass
through `emo_process_done` (the death every natural child takes), the
boot pass's announces and keeps the heap-death route. Verified with two
children — one refusing, one answering: the root prints the answer and
`root still here`, exit 0, on c and ocaml; the single-child repro ends in
the deadlock sentence, exit 70, on c, ocaml and the beam. The metal's
split is in and rides the proven natural-death machinery (its live-fire
probe parked: a spawn at the boot phase trips a *pre-existing* fault,
`user fault 1 cause 2` in `emo_spawn`, on the tree before this round
too). wasm keeps its two constraints: the repro shape refuses at the
build (a `receive` must be the last statement of its body), and the
module's instruction set has no exception handling, so a child's throw
cannot be scoped without it — the one target the death scope stays open
on, and its own round.

**(c) The boolean operators are the one family still in every target's own
words. — closed 2026-11-26.** Every target now answers the interpreter's
own sentence for `!`, `&&` and `||` on a value that is not a Bool, and
answers the Bool where it is one, with the short-circuit intact (`t || s`
never runs the right side anywhere). Each side the run actually evaluates
is checked as it evaluates, so `b && s` names the right's kind — the
interpreter's `got String`, never a two-kind sentence. Per target: the
beam gains `emo_op_not` (the generated door, `("not", 1, "!", "a Bool")`
joining the door list) and an `emo_bool_checked` helper the lowered
`&&`/`||` call per operand (the unchecked case answered `false` for any
non-Bool left); c gains `emo_bool_dyn` and `emo_not_dyn` (the runtime
checks, the sentence over `emo_type_name`) where `emo_bool_of` answered
the generic wrong-type fatal; typescript's `E.truthy` truthiness — which
printed `true` for `!"s"` — becomes `E.not` and `E.boolOf` throwing
`EEmoException`; wasm gains `rt_not_checked`/`rt_and_checked`/
`rt_or_checked` (appended last, the rt map is by position) where the bare
`ref.cast` answered `illegal cast`; the metal gains `emo_not_dyn` and
`emo_bool_checked` (the Bool tag masked at four bits — the word's value
bit rides above it — and `emo_op_fail`'s one-kind flag set, where the
bare `xori` corrupted the word into `1Bytes[]` and `&&`/`||` refused the
build); the ocaml runtime's `unbox_bool` — the bare `expected Bool` —
becomes the sentence in `and_l`/`or_l`/`not_`. Verified by hand on all
seven: the `!` refusal and the `&&`-on-String refusal in each target's
own envelope (the beam `runtime error: …` 70, c `runtime error: …` 70,
typescript `error[E3010]` 70, wasm `ABORT: …` 1, ocaml `Fatal error` 2,
the metal `emo runtime: …`), the Bool pair answering `f/true/false`
byte-identical everywhere it runs, and the metal's `&&` on a true left
and String right naming the String alone.

**(d) Three wrong answers and one early death in the same operators. —
closed 2026-11-26.** `7.5 % 7.5` answers `0.0` everywhere the Float
remainder runs: c's `emo_arith_dyn` computes `fmod` (it answered a
manufactured `0.0/0.0`) and its static form builds through `fmod` too
(where it refused the whole build); wasm's `rt_mod` is a real fmod —
binary long division, exact at every step, because WebAssembly has no
remainder opcode and the old text named `f64.rem_s` while the binary
encoded 0xA5, `f64.max`, so `7.5 % 7.5` answered `7.5` (the divisor
scales up while below the dividend's half, each subtraction runs within
one doubling step, the halvings retrace exact doublings; the NaN gate
tests `v - v == 0`, which only a finite value survives). The Byte shift
by a count at or past eight answers `0` on wasm now: `rt_shl`/`rt_shr`
carry the evaluator's count rules (a negative count refuses with
`shift count must be non-negative`, a count at the width — eight for the
Byte, sixty-four for the Int64 — answers zero, the right shift
sign-extends), where a raw `i64.shl` wrapped the count modulo the width
and `3 << 70` answered `192`; the Int64 path carries the same guard. And
the gradual Float's negation answers `-7.5` on c: the checker types a
gradual `-` `Unknown` now (it typed the result Int64 by rule, and every
consumer unboxed the Float answer as an integer — garbage; the emitters
already take their dynamic paths for an Unknown operand), while an
explicit Int64 negation keeps its type. Verified by hand: the three
remainders byte-identical with the interpreter on c and wasm (`0.0`,
`1.5`, `2.25`), the shifts `0/0` on wasm, and `-f` as `-7.5` on the
interpreter, c, typescript, wasm and the beam.

**(e) A Char reads as a String in the beam sentence — closed 2026-11-26
(the sentence was already right; the one live gap was printf's %c).**
The record's claim is stale: the beam's Chars are tagged today
(`{'emo_char', its UTF-8 bytes}` — the literal's own shape, the `chars`
method's, and the patterns'), and `emo_type_name` names the tag, so
`ch + 1` through a mailbox answers ``operator `+` expects two numbers
or two strings, got Char and Int64`` — the interpreter's sentence,
exit 70 — and the whole Char surface answers with it: the render (`a`),
the equality (`true`), the mailbox crossing, `chars()` indexing
(`true`, `3`). The one live gap the probing found: printf's `%c` met
the tagged shape and refused (`printf: the format met a value of the
wrong kind`) where the interpreter prints the character —
`emo_emit_char` gained the tagged arm (the tag's bytes are the
rendering, the width padding unchanged) and `emo_printf_kind` answers
`Char` for it, so `printf("%c!\n", [ch])` prints `a!` on both.
Verified by hand: the probe table above plus the printf leg;
`examples/processes`, `atomic_cell` and `language_tour` byte-identical
with their `expected.txt` on the beam.

**(f) The build refusals are unchanged — open.** c refuses the bitwise
operators and `~` on a dynamic value ("does not support the bitwise
operators in the dynamic world yet"); the metal refuses `/`, `%`, the
bitwise operators and the shifts on one ("does not support this operator
on a dynamic value yet") — `&&`/`||` closed this round, and the metal's
Float `%` is the same "arrives with runtime exceptions" shape. These are
missing dynamic lanes, not wrong answers; the interpreter refuses at
runtime where they refuse at the build.

**(g) The c emitter warns on an unused receive binding. — closed
2026-11-26.** Every receive branch now casts its bindings `(void)` after
the take (`pattern_void_sfx`), so a binding the body never reads costs
no warning; `examples/processes` builds with zero warnings and stays
byte-identical with its `expected.txt`.

## 8. The TLS hint names a flag form the build rejects — closed 2026-11-26

**Symptom.** When the c target cannot link OpenSSL, `emo build` says to pass
`--cclib -L<dir> --cclib -lssl --cclib -lcrypto`. Given exactly that, the
build answers `emo: unknown option -L<dir>`. The option takes its value
through `=` — `--cclib=-L/opt/homebrew/opt/openssl@4/lib` builds
`examples/http_roundtrip` — and the help spells it `--cclib=LIB`, "link
against C library (-lLIB)".

**Fix.** The hint (and the runtime comment above it) spell the `=` form
now: `--cclib=-L<dir> --cclib=-lssl --cclib=-lcrypto`. Verified by hand:
building `examples/http_roundtrip` without the OpenSSL path answers the
fixed hint (exit 69), and following it literally — the three flags, the
`=` forms, copied verbatim — links the program (`built main`; the ld's
"duplicate libraries" note is the runtime's own `-lssl`/`-lcrypto`
meeting the passed ones, harmless).

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

## 10. riscv64: a Map has no rendering — closed 2026-11-26

**Symptom.** `println(m)` and `println(m.set("a", 10))` — a Map through any
door that answers the Map itself — refuse at the run: `emo runtime: cannot
convert this value to a string yet`. Every other target renders a Map as
`{"a": 10, "b": 2}` and the interpreter's own order.

**Fix.** `emo_to_string`'s dispatch gained the Map word (tag 26, kind 13):
`.Lts_map` walks the keys through `emo_map_keys` (insertion order), composes
each entry `key: value` through a new `emo_kv_string` — the kinds through
`emo_to_string`, a String quoted and escaped (the backslash and the double
quote, the interpreter's `%S`) — with the value read at the entry's `+8`
(the stride is 24), and hands the slots to `emo_join_string` over `{` and
`}`. The walk keeps its state in s-regs only and spills above the saved
`s5` — the entry frame's `ra` slot is not scratch. Two findings rode in.
`emo_map_keys`'s key classification read five bits of the odd word and
boxed every immediate that was not a raw Int64 — every `true` key came
back the integer 17 (the word itself) and Char and Byte keys fared the
same; the classification now reads the kind in bits 1-3 and rides the
Bool, the Char and the Byte as the tagged words they are. And the
debugging detour that cost the round its first hour: the `emo` on PATH is
a symlink into the parallel `emo-syntax-sugar` checkout's build — every
`emo run` in a shell without `eval $(opam env …)` re-pinning the binary
exercises *that* tree's compiler, and its metal emitter hangs on a map
literal — three chase-the-ghost rebuild rounds before the runs were
re-pointed at this tree's `_build/default/src/emo_cli/emo.exe`.

**Verified.** Seven prints on the metal byte-identical with the
interpreter (modulo the qemu console's CRLF): the literal, `set`'s
answers, mixed keys (`{1: "one", 2.5: "two and a half", true: "yes"}` —
the Int64 bare, the Float64 bare, the Bool spelled), the nested Map, the
escaped quote inside a String value and a String value beside a Bool
value; the `has`/`keys` doors over Bool and String keys answer
`true/true/[true, false, s]` and the getter sums `3`, byte-identical
with the interpreter; and a map built as a plain `var` statement,
through a `def`'s return, and as a top-level `const` all print.
