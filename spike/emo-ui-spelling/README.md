# EmoUI spelling: what one real screen costs, in A and in B

A spike off [step 48](../../docs/TASKS.md) (EmoUI), closing the evidence gap
[`docs/emo-ui-composition.md`](../../docs/emo-ui-composition.md) names as the
reason its last question is still open:

> EmoUI children are an explicit `Array[Node]` (option A). Should Emo's
> grammar grow markup-aware (C, a tree literal in the parser), or should
> EmoUI ship a second syntax (D, an external translator emitting `.emo`)?
> The note's own answer is "write a screen and count the lines". This is
> that screen, counted.

**Verdict: do B, and the numbers say the tree literal does not earn its
price — at least not the price C charges.** Two real screens are 95 lines in
the A spelling and 40 in B, same tree, byte-identical render. A tree literal
deletes **72 bracket tokens in A and 18 in B, and zero `children:` labels in
either** — because the constructors are positional, so the label the
composition note's option-B sample hinges on (`children: kids.to_array()`)
never appears in real code. Worse, the 44 non-blank lines of `screens_a.emo`
that actually hurt are the *iteration builders*, which a literal that
"desugars to exactly the nested calls of A" inherits unchanged. B is the
step that pays, it is a container question rather than a syntax question, and
it is not wasted under either C or D because both desugar to the same tree.
C's remaining case is ergonomic, not measurable here; D's is stronger than
the note assumed, because a translator can lower a loop *inside* a literal
straight to B's container form.

One caveat, since the task was to answer with numbers: **the experiment
measured A and B. The claims about C and D are what follows from those two
columns, not measurements of C or D** — neither was built, and building
either is the next experiment, not this one.

The numbers are below, under [The measurement](#the-measurement); the
argument they support is under [Verdict](#verdict).

## Where this starts from

`docs/emo-ui-composition.md` settles that a component's children are an
explicit `Array[Node]` (option A, `docs/emo-ui.md` decision 3), rejects
emission, self-rebinding and an ambient collector, and leaves exactly one
question open: **does Emo's grammar grow markup-aware, or does EmoUI ship a
second syntax?** Its closing section admits why it is open — "neither branch
has been tested against real code" — and prescribes this experiment, in this
order: do B, write the T48.1 portable core and a screen or two of real UI in
the A spelling, and let the line counts decide.

This spike is that, plus the B spelling written for real so the comparison is
between two programs rather than between a program and a proposal.

Writing it turned up three things the note could not have measured, all of
which change what "the A spelling" costs:

1. **`Array.append` appends one element, not an array**
   (`src/emo_eval/emo_eval.ml:2055`). The iteration idiom published in
   `docs/emo-ui.md` Layer 1 and copied into
   `spike/emo-ui-probe/probe3_iteration_and_messages.emo` —
   `[head].append(each_from(...))` — therefore builds
   `[n0, [n1, [n2, []]]]`, a *nested* array, not a flat `Array[Node]`. It
   type-checks because the element arrives through a `Block`, `Block` is
   `Unknown` (`src/emo_check/emo_check.ml:294`), and `conforms` is true
   whenever either side is `Unknown` (`emo_check.ml:1011`). Probe 3's
   printed `2` was the masked symptom: `2` for any list of length ≥ 2, and
   nothing in the output said so. `screens_a.emo:96` reproduces the idiom
   faithfully and `main.emo` shows it on a real screen; both probe 3 and
   the Layer 1 example have since been corrected.
2. **There is no `List` → `Array` conversion.** `grep to_array src/` is
   empty, so option B as written in the composition note does not compile,
   and the conversion has to be hand-written — on top of `append`, i.e.
   still quadratic. `ui.emo:279` writes it; `measure.emo` prices it.
3. **A mixed child literal is not checked.** A homogeneous one is:
   `spine.column(["not a node"])` is `E4004: argument 'children' expects
   Array[spine.Node], got Array[String]`. But
   `spine.column([spine.text("ok"), "not a node"])` is accepted, because
   the literal degrades to `Array[Unknown]` and `Unknown` conforms to
   everything. A's "props checked at construction"
   (`docs/emo-ui.md:274`) holds only as far as this hole, and it is the same
   hole the Block idiom hides in.

## The two screens

Two screens, chosen so that between them every portable primitive appears and
both hard cases are present on purpose. `screen_profile` is a form: a title,
an avatar band, a **conditional** error banner, a **column of iterated**
field rows, a row of iterated buttons, a spacer, a licence block.
`screen_inbox` is a list: a toolbar, a **conditional around an iteration**
(the empty state when there are no messages, otherwise the message rows), a
footer.

The second one is the case that decides the shape. Emo arrays do not
concatenate, so "a conditional child between two fixed children" cannot be
built by splicing two arrays — the whole list has to come out of one
branching builder. `screens_a.emo` answers it two ways and both are on
record: `screen_profile_dup` writes the entire children array twice (21
lines), `screen_profile` writes an explicit `concat` builder (6 more lines of
machinery). `screens_b.emo` answers it with a `List` and an `if`.

`components.emo` holds everything the two spellings share **verbatim** —
every widget with a fixed child list, and `root_style()`. So the A-versus-B
delta is exactly how the *dynamic* lists are assembled, not a diff between
two independently written screens. That is what makes the line counts below
mean something.

The two spellings, side by side — the field column of `screen_profile`:

```emo
// A (screens_a.emo) — a builder def per element type, because no generics
def field_rows(xs Array[model.Field], i Int64,
               into Array[ui.Node]) Array[ui.Node] {
  if i == xs.length() {
    return into
  }
  return field_rows(xs, i + 1, into.append(components.field_row(xs[i])))
}
const rows = field_rows(m.fields(), 0, [])
```

```emo
// B (screens_b.emo) — one loop, one container
const rows = List.new([])
const fields = m.fields()
for var i = 0; i < fields.length(); i = i + 1 {
  rows.push_back(components.field_row(fields[i]))
}
```

```emo
// A-naive (screens_a.emo) — the idiom docs/emo-ui.md Layer 1 publishes
def each_from(xs Array[model.Field], i Int64, f Block) Array[ui.Node] {
  if i == xs.length() {
    return []
  }
  const head = f(xs[i])
  return [head].append(each_from(xs, i + 1, f))
}
```

The third is the same seven lines as the first, looks *simpler* — no
accumulator to thread through the recursion — and builds the wrong tree.
`main.emo` asserts all three, and prints the result: the naive column has
`length() = 2` where B's has `3`, and its `child[1]` is a nested
`[#ui.Row(...` array rather than the second field row.

## The measurement

Everything here is produced by the scripts in this directory; see
[Reproducing](#reproducing).

### Source cost

Lexical counts per file: non-blank, non-comment lines `L`; bytes; the labels
and brackets a parsed tree literal would delete outright; and the same as a
fraction of `L`.

```
file                    L   bytes  children:  brackets    sugar   sugar/L
ui.emo                212    4902          3        46       49     0.231
components.emo         65    2254          0        18       18     0.277
debug.emo              81    2200          0         4        4     0.049
model.emo             133    3645          0        20       20     0.150
tags.emo               26     553          0         8        8     0.308
app.emo                23     720          0         0        0     0.000
features.emo          104    2432          1        24       25     0.240
measure.emo           186    5213          0        90       90     0.484
screens_a.emo          95    3091          0        72       72     0.758
screens_b.emo          40    1533          0        18       18     0.450
main.emo               63    2754          0        20       20     0.317
naive_crash.emo         1      79          0         0        0     0.000
```

These are lexical proxies, not a readability proof, and they are meaningful
here for one reason: `main.emo` asserts that both spellings render
byte-identical trees, so a lexical difference between `screens_a.emo` and
`screens_b.emo` cannot be a difference in what the program builds.

### What a tree literal would erase

Read the `children:` column first, because it is the surprise. **It is 0 in
both screens.** The constructors take children positionally
(`def column(children Array[Node], style Style) Node`), so the label the
composition note's option-B sample is built around — `page(title: "Home",
children: kids.to_array())` — does not appear in the code at all. The only
files carrying `children:` are `ui.emo` (3, the constructors' own
definitions) and `features.emo` (1, a probe). A tree literal on these screens
deletes **brackets only**.

Second, the bracket count is a *lower bound* and it is not where A's cost
is. A literal also deletes the local arrays and the `concat` calls — on
`screen_profile` three locals and two `concat` calls, and in
`screen_profile_dup` the entire duplicated array, 21 lines — and none of
that is in the table, because a lexical count cannot see it. So `sugar/L`
understates the literal for the *static* parts of a screen. Fine.

But it does not touch the parts that dominate:

| what | `screens_a.emo` | `screens_b.emo` |
|---|---|---|
| total non-blank lines | 95 | 40 |
| builder machinery (A: lines 14–56, 96–102; B: 3 inline `for` loops) | **44** | **0** |
| conditional splicing (A: `concat` + the dup variant; B: an `if`) | 6 + 21 | 3 + 7 |
| brackets | 72 | 18 |

The 44 lines are `no_nodes`, `concat`, `field_rows`, `action_buttons`,
`message_rows`, and `each_from` — builder defs that exist to turn an
`Array[Field]` into an `Array[Node]`. A tree literal that "desugars to
exactly the nested calls of A" (the composition note's own description of C)
inherits every one of them, because the iteration is a *data-driven
transform*, not tree shape: a literal gives you a nicer way to write a child
list you already know, and these builders exist because you do not know it
until you have walked `fields()`. The literal only removes them if it also
grows a loop form — which is a considerably larger language change than a
tree literal.

So the honest ledger for the literal is: it deletes the brackets and the
static plumbing, and it leaves the 44 lines that make A 2.4× B.

### Child-array build cost

Five strategies, same input, same element builder, same declared return, over
a doubling ladder. `copies` models `emo_array_append`'s `8·(len+2)` cell.

| strategy | k=32 appends | k=32 copies | result |
|---|---|---|---|
| `build_cons` — the docs' `each_from`, faithfully | 32 | 768 | **`len == 2`, nested** |
| `build_acc` — `into.append(mk(x))` | 32 | 4480 | correct, quadratic |
| `build_concat` — a concat helper over `append` | 496 | 51584 | correct, worse quadratic |
| `build_list` — `List` builder + hand conversion | 32 | 4480 | correct; identical to `build_acc` |
| `build_map` — `Map.set` then `.values()` | **0** | **0** | correct, **no array growth at all** |

Two results matter.

`build_list` is *identical* to `build_acc`. That is the whole point: `List`
itself is O(1) (`push_back` at k=32 is 32 pushes and 0 copies — the `pushes`
column), but the hand-written conversion at `ui.emo:279` drains the list into
an array one `append` at a time, so the quadratic cost simply moves into the
conversion. B's ergonomic win is real and free; B's *asymptotic* win does not
exist until the conversion does.

`build_map` does no array growth at all — 0 appends, 0 copies, k `set`s — so
the runtime already has an O(k) route from a keyed collection to an array,
via `Map.values()` and its insertion-ordered backing list. Caveat, stated
because the meter does not measure it: `copies` counts only the bytes
`Array.append` would move, so this says the linear path exists, not that
`Map.set` is free. The point stands either way — a `List` → `Array`
conversion should be a runtime primitive walking the deque, not an Emo loop
over `append`.

### The nested-array bug, on a real screen

`screens_a.emo:104` (`screen_profile_naive`) is the published idiom, applied
to the profile screen. `main.emo` asserts against it and prints:

```
naive  field column, length   = 2
       field column, child[1] = [#ui.Row(style: #ui.Style(padding: 0.0, gap: 8.0, align: start, grow: fa...
B      field column, length   = 3
       field column, child[1] = #ui.Row(style: #ui.Style(padding: 0.0, gap: 8.0, align: start, grow: fal...
```

`naive_crash.emo` is the same tree handed to the backend, and it is the
symptom's real shape: `E3007`, exit 70. The nested array is not an instance,
so the render walk's first `is()` raises before any branch is reached. The
`Unknown ${n}` fallback in `debug.emo` — written exactly to make a non-node
visible instead of type-erroring — is unreachable for a non-node, because
`is()` raises rather than returning false. That is worth knowing on its own:
**a backend cannot defensively render a tree it does not trust.**

### Checker coverage

`mismatch/` holds a cut-down spine and two files with the same mistake — a
`String` in a child slot:

- `mismatch/homogeneous.emo` — `spine.column(["not a node"])`. **Diagnosed**,
  E4004, and it is the only diagnostic the package produces.
- `mismatch/mixed.emo` — `spine.column([spine.text("ok"), "not a node"])`.
  **Not diagnosed**, and it draws no line of its own.

Note what E4004's message says: it names `children`, the parameter, and
compares `Array[String]` against `Array[spine.Node]`. That is the check
working exactly as it should, and it is available *only* because the child
slot has a declared array type to compare against. The mechanism that
defeats it in the mixed case is the one from finding 3: the mixed literal
infers `Array[Unknown]`, `conforms` recurses into the element types, and
`Unknown` conforms to `Node`. So the A spelling
closes the props-checked hole for a literal that is wholly wrong and leaves
it open for a literal that is *partly* wrong — which is the more likely
mistake and the more expensive one, since the good element makes the tree
look right.

Any tree literal has to preserve the promise at least this well, and
preferably better: since the literal knows the child slot's declared type, it
is the one construct that *could* check each element against `Node` instead
of against a freshly inferred array element type. That is an argument for C
or D, not against — but it is a fix for a checker hole, and a checker fix is
a much smaller change than markup-aware grammar.

### The target matrix

The core is supposed to be portable. `emo build` on the package, by target:

| target | result |
|---|---|
| interpreter | runs; golden byte-exact |
| `typescript` | builds |
| `ocaml` | builds |
| `c` | builds |
| `wasm` | fails on the package (Map only); builds without `measure.emo` |
| `beam` | fails on the package (Map only); builds without `measure.emo` |

Two were the core's fault and one is a spike-only file's, and none of the
three was fixed while this spike ran — it changed nothing under `src/`. The
two codegen defects were fixed afterwards (2026-10-15, folded into T48.1);
each fix left its fixture behind as the regression that keeps it fixed, and
`check.sh` now asserts the build *and* the run on the target that used to
refuse. The `Map` refusal is still live. The descriptions keep their
original numbering:

1. **`c` — a class's field-name table collides with a method named
   `fields`.** The generated C named the field table
   `<module>__<Class>__fields` and a method `fields` the same, so they
   collided: `error: redefinition of 'main__Holder__fields' as different
   kind of symbol`. The table's name was fixed —
   `<module>__<Class>__fields`, whatever the fields are called — so the
   collision needed only a *method* named `fields` anywhere in the package,
   and this spike's own `Model.fields()` (`model.emo:92`, an ordinary
   accessor name on a form model) was one, which is why the whole core
   failed to build for `c`. `codegen/field_table/` isolates it; the other
   four targets build that file. **Fixed** by moving both metadata tables
   out of the `<cname>__<member>` namespace: they are `vt_<cname>_fields`
   and `vt_<cname>_methods` now, joining the `vt_<cname>` and
   `iface_<name>` single-underscore convention. The fix suggested here
   originally — `__field_names` — would not have worked: a member named
   `field_names` emits exactly that symbol, so the rename would only have
   moved the collision to the next ordinary accessor name.
2. **`ocaml` — native `String` `+`.** The emitted OCaml was
   `(Int64.add (v_a) (v_b))` for two `String` locals:
   `Error: This constant has type string but an expression was expected of
   type int64`. Root cause was `src/emo_codegen/emo_codegen.ml:654-656`: the
   unboxed `emit_native_expr` had a `Float64` branch (`+.`) and an else
   branch (`Int64.add`) and **no `String` branch**. The boxed `emit_expr`
   path routes `Add` through `Emo_runtime.add`, which does handle Strings —
   so this was the specialization only, reached when every operand is
   natively representable (two `String` locals; a self-recursive `String`
   call, which `debug.emo`'s `indent` is). `codegen/native_string_add/`
   isolates it; the other four targets build that file. **Fixed** by adding
   the `= Emo_check.String` branch emitting `(^)`, exactly as suggested —
   and `check.sh` runs the fixture on `ocaml`, because a numeric `+` that
   still compiles would pass a build-only assertion.
3. **`wasm` and `beam` — `Map`.** `the wasm target does not support Map
   yet`. The only `Map` in this spike is `measure.emo`'s `build_map`, so the
   core itself is fine on both; with `measure.emo` removed, the package
   builds for `wasm` and `beam`. Recorded rather than worked around, because
   it is a real limit on which targets can host a T48.1 core that uses a
   `Map` anywhere.

`check.sh` asserts each row of this table, so a change in `src/` turns into a
FAIL here rather than a stale paragraph.

## Verdict

**Do B. The measurement does not earn C, and it makes D look better than the
note assumed.**

**B is the step that pays, and it is a container question, not a syntax
question.** Two real screens: 95 lines against 40, identical trees, identical
render. B costs zero syntax and removes both the builder defs and the
conditional-splicing problem — `ui.column(concat(head, concat(banner, tail, 0), 0), style)`
becomes an `if` and a `push_back`. It needed exactly one language-side thing
to be more than an ergonomic win, and that thing arrived as `ArrayBuilder`
(2026-10-15, T49.3) — a new container, not the `List` → `Array` conversion
this note predicted. And B is not wasted under either C or D: both desugar to
the same tree.

**C's price buys less than the note assumed.** The literal deletes brackets
— 72 in A, 18 in B, 0 labels — plus static plumbing, and it leaves the 44
lines of iteration builders untouched, because those exist to walk
`fields()`, which is not tree shape. C's stated cost is a real language
change: parser, checker, six backends, formatter, LSP, and a grammar that is
markup-aware. Paying that to delete brackets and a `concat` call is not a
trade the numbers support. C becomes worth it only if the literal grows a
loop form, and then the thing being priced is no longer "a tree literal".

**D is stronger than the note allowed, for the reason the note itself
gives.** The note's case for D is that it is a text transformation with full
knowledge of the target, so it can dissolve the block problem by desugaring.
That same property lets a loop *inside* the literal lower straight to B's
container form — a `for` in the markup becoming `List.push_back`, not
`append` — so D deletes the brackets, the static plumbing, *and* the 44
builder lines, with no language change and in the EmoUI repository, leaving
the language repository untouched. D's cost is a second syntax and a second
toolchain (formatter, LSP, error mapping), which is real but is a toolchain
cost, not a grammar one.

**What T48.1 should ship.** Children as `Array[Node]` — settled, and the
measurement supports it: the child list is checked at construction, backends
narrow with `is()`, `patch` compares trees. But the *construction* side must
not be `Array.append` in Emo: that is both the quadratic path and the nesting
bug, and the docs published exactly that until this round.

The fix this section first named — a runtime `List` → `Array` conversion,
shipped as `children_of` — is **superseded**, and the conversion half was
refused on purpose. `ArrayBuilder` landed on 2026-10-15 (T49.3): a
language-level mutable buffer that appends in amortized O(1) and copies out
with `to_array()`. A T48.1 core builds children into one of those; nothing
is added to `List`, because nothing in the language reads a deque by index
and a conversion would give the deque a second job
(`docs/emo-ui-composition.md:300-308`). `ui.emo`'s `children_of` is the
measurement's scaffold, not a proposal — it is how the A spelling reached a
flat `Array[Node]` with the containers the language had at the time. Either
way the A spelling's worst cost — 44 lines and O(k²) — goes away without a
syntax change.

**The order this suggests: B, then D if the ergonomics still hurt, and C only
if D's second toolchain turns out to cost more than a markup-aware grammar.**
That is a smaller claim than the note hoped to settle, and it is the claim
the numbers support — one experiment on two screens, not a survey.

## Corrections to the docs

Recorded here first, then applied:

- **[`docs/emo-ui.md`](../../docs/emo-ui.md) Layer 1, the `each_from`
  example is wrong.** `Array.append` appends one element, so
  `[head].append(each_from(xs, i + 1, f))` builds `[n0, [n1, [n2, []]]]`.
  It compiles only because the element comes through a `Block`, and `Block`
  is `Unknown`; the "This works (probe 3)" sentence under it is the masked
  `2`. Replaced with a builder that actually produces a flat `Array[Node]`,
  and the probe-3 claim corrected.
- **[`docs/emo-ui.md`](../../docs/emo-ui.md) Layer 0's `interface Node` has
  only `style()`.** The spike's `Node` also declares
  `def children() Array[Node]` and checks — the layer-0 sketch predates the
  recursive-interface finding recorded at `docs/emo-ui.md:116`, which already
  says an interface naming itself in a signature works. Layer 0 updated to
  match what is now known.
- **[`docs/emo-ui-composition.md`](../../docs/emo-ui-composition.md) option
  B calls `kids.to_array()`.** No such conversion exists. The sample is
  corrected to the conversion this spike had to write, and the evidence-gap
  section gets these measurements appended.
- **[`spike/emo-ui-probe/probe3_iteration_and_messages.emo`](../emo-ui-probe/probe3_iteration_and_messages.emo)
  and its READMEs document the masked `2`** as the expected output. The probe
  is rewritten to produce a flat array; the expected-output block updated.
- **Recorded, not corrected:** the `src/` defects in
  [the target matrix](#the-target-matrix), and the mixed-literal checker
  hole. Both are findings for the language, not doc errors, and nothing under
  `src/` changed while this spike ran. The two codegen defects were fixed
  afterwards and their fixtures now serve as the regression; the `Map`
  refusal and the checker hole are still open. `check.sh` pins all of them.

## Reproducing

From this directory, with the repo's compiler
(`../../_build/default/src/emo_cli/emo.exe`, overridable as `$EMO`):

```sh
./count.sh    # the source-cost table
./run.sh      # main.emo and naive_crash.emo, diffed against the goldens
./check.sh    # 24 assertions: what checks, what does not, which targets build
```

`run.sh` compares `emo run main.emo` and `emo run naive_crash.emo` against
`expected_main.txt` and `expected_naive_crash.txt`, so a change in the core
or in either spelling shows up as a diff. `naive_crash.emo` ends in `E3007`
and exit 70 — that *is* its result, so the exit code is part of the compared
output. Both scripts strip absolute paths before comparing, so the goldens do
not carry whoever ran them last.

`check.sh` states every expectation before comparing against it, which is the
point: the target results, the two codegen regressions and the two checker
results are pinned, so a change in `src/` turns into a FAIL here rather than a
stale paragraph above.

Nothing here is wired into `dune test` or CI, and running the spike changes
nothing under `src/` — the two codegen fixes are T48.1's work, not this
directory's. `.emo-build/` holds the intermediates and is gitignored globally.

## Files

| file | what it is |
|---|---|
| `ui.emo` | the T48.1 portable core: `Style` + `with_*` copies, `Node`, eight widgets, `Backend`, `children_of` |
| `components.emo` | every widget the two spellings share verbatim (fixed child lists only) |
| `screens_a.emo` | the two screens in A, plus `screen_profile_dup` and `screen_profile_naive` |
| `screens_b.emo` | the same two screens in B, in 40 lines |
| `debug.emo` | the T48.3 headless backend: node tree → stable indented text |
| `model.emo`, `app.emo`, `tags.emo` | `Field`/`Message`/`Model`/`Msg`, `update`/`view`, the event-tag registry |
| `measure.emo` | the five-strategy child-array builder ladder |
| `main.emo` | assertions, the golden report, the measurement |
| `naive_crash.emo` | the nested-array bug's real symptom: `E3007`, exit 70 |
| `features.emo` | the five language features the core rests on, each load-bearing |
| `mismatch/` | the checker's coverage of a wrong child literal (nested package) |
| `codegen/field_table/`, `codegen/native_string_add/` | the two `src/` codegen defects, isolated (nested packages) — fixed, and kept as the regression that pins the fix |
