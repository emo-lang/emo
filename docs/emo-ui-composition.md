# EmoUI composition — how a tree gets written

Written 2026-10-15. This is a discussion record, not decided design. The
composition decision is settled and unchanged: **children are an explicit
`Array[Node]`** ([`emo-ui.md`](emo-ui.md), decision 3 — and
[`visualization.md`](visualization.md) decision 14 chose the same shape
for plot). What this note records is the argument underneath that
decision: how a component tree can be spelled, which mechanisms are open
and which are closed, and the one question that is genuinely still open.

It exists because the question keeps coming back in two forms — *should
components emit into a context instead of returning values?* and *does
EmoUI need a template language?* — and both have answers whose reasons
are not recoverable from the decision alone.

## The question

[`README.md`](../README.md) publishes this as illustrative EmoUI syntax:

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user User) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}
```

[`emo-ui.md`](emo-ui.md) says of it: **this cannot work as written.** The
reason is narrow and worth stating exactly, because almost every argument
in this note is a consequence of it. `text(user.name)` as a statement is
a discarded expression: it produces a `Node` that reaches nothing. The
block is `Void`, the values are dropped, and the enclosing component
receives no children.

So the question is not "how do blocks work". It is one step further in:
**when a block's statements discard their values, how does a leaf find
the container it belongs to?**

## What a block delivers today

Five facts from the language, all of them current:

- **An attached block is the call's final argument.** `page(title:
  "Home") { ... }` passes a zero-parameter block; `list(users) -> (user
  User) { ... }` passes a parameterized one ([syntax.md](intro/syntax.md)).
  There is no separate block slot — the callee receives it as a declared
  parameter.
- **A parameter that receives a block is declared `Block`**
  ([type-system.md](intro/type-system.md)), and `Block` is
  `Unknown`. A block argument's body is therefore not checked against
  anything.
- **A discarded expression statement is legal and silent.** The checker's
  whole rule for it is `ignore (check_expr ctx env e)`
  (`src/emo_check/emo_check.ml:2541`). This is why the README's tree
  type-checks and still delivers nothing.
- **A `Void` body takes no `return` at all** — "it takes no `return` at
  all, its body simply ends" — while a typed body must `return` on every
  path; there is no implicit "last expression is the value"
  ([syntax.md](intro/syntax.md)).
- **Control flow is statement-shaped.** `if` and `case` are statements,
  with one exception: the one-line `if` expression picks a value, and it
  must stay on one line with exactly one expression per branch
  ([syntax.md](intro/syntax.md)). `for` and
  `while` are statements ([syntax.md](intro/syntax.md)) and have
  landed on every target (T26, T27).

The last one matters for spelling, not mechanism: it means conditional
and iterated children have to be *bound* before they can appear in a
child array, or expressed through the one-line `if`.

## The trilemma

A block whose statements discard their values can only be put to work if
something tells each discarded value where to go. There are exactly three
ways to supply that, and no fourth:

1. **An ambient collector.** Some "current container" reachable from
   anywhere — dynamic scope, a process-level sink. A leaf appends to it
   without being told about it.
2. **A compiler-threaded implicit parameter.** The callee's signature
   gains a hidden context parameter injected by the compiler; the leaf
   emits into it.
3. **An explicit collector parameter.** The block declares it, the
   component passes it, and the call sites name it.

## Why the first two are closed

**The ambient collector contradicts the mutability rule outright.**
[`syntax.md`](intro/syntax.md) defines the mutable surface as a
closed set — `var`, `Box`, `Bytes`, `List`, `Map`, `ArrayBuilder` — "and
nothing else mutates in place". A process-global and implicit collector
would be the largest single violation in the language: every one of the
six named types is constructed by an explicit call and reaches its
mutations through a name the code writes down, while an ambient
collector is reached by nobody and written by anybody. It also collides
with the concurrency model: nested containers need a stack of
collectors, and `send` delivers snapshots, so the collector cannot cross
a process boundary with the tree it is filling.
[`emo-ui.md`](emo-ui.md) already rejects this shape ("implicit state,
against the design philosophy").

Adding `ArrayBuilder` to that set does not reopen this: what the rule
closes is *unnameable* mutability, not the count. A builder is built by
`ArrayBuilder.new()`, bound to a name the author chose, and appended to
through that name — so it is exactly as visible as the `List` beside it,
and the objection above is about visibility, not about how many types
may mutate.

**The implicit parameter costs a second calling convention.**
[`syntax.md`](intro/syntax.md) states the rule it breaks: "Parameter
types are always explicit". A component whose signature reads
`def text(s String) Void` would emit — and a reader could not see that it
emits, or into what. It is also the largest single language change on the
EmoUI table, larger than the checked block/function type that
[`emo-ui.md`](emo-ui.md) already prices as "a language change of real
size": the closure representation, the `Block` type, the checker, and
every one of the six backends would carry the extra parameter, and
`Block` would need a second form that takes it. Compose pays exactly this
price — the Kotlin compiler plugin adds a `$composer` parameter and a
changed-flags bitmask to every `@Composable` function — and it is worth
being clear that the price buys something there: positional memoization
in a slot table, which is what makes Compose's fine-grained
recomposition work. EmoUI decided the opposite mechanism (see
"Emission does not change the data model" below), so it would pay the
price without the benefit.

## Prior art

The claim that Compose, SwiftUI, and Flutter all compose by emission does
not hold up. Two of the three are on the return pole:

| | How components compose | Pole |
|---|---|---|
| **Compose** | `@Composable` functions return `Unit` and emit into the composition; the compiler injects `$composer` | emit |
| **SwiftUI** | `var body: some View` returns a value; `@ViewBuilder`'s `buildBlock` collects each statement's value into a `TupleView` | return |
| **Flutter** | `Widget build(BuildContext context)` returns a `Widget`; children are an explicit `children: [...]` list | return |
| **React / JSX** | `createElement` returns an element tree; JSX desugars to those calls | return |
| **Elm** | `view : Model -> Html msg` returns a tree | return |

Two corrections worth keeping:

- **SwiftUI is not emission — it is the rejected mechanism spelled
  without `return`.** A result builder gathers the *values* of the
  block's statements. That is precisely the "implicit child collection"
  [`emo-ui.md`](emo-ui.md) rejects as ask 2 and as its option 4. The tree
  it produces is an immutable value, and SwiftUI diffs it — the same pole
  as EmoUI's `patch`.
- **Flutter is the array model.** `BuildContext` is not a collector; it
  is the inherited-widget lookup (theme, media query), passed explicitly
  because Dart has no ambient context. Flutter's element tree does
  register elements with a parent, but that is inside the framework's
  reconciliation and invisible to application code.

So the emit camp is real, but only one of the three named languages is in
it — and every language whose components compose by something other than
returning a value paid for the style: Compose with a compiler plugin,
Kotlin's type-safe builders with receiver lambdas, Ruby's DSLs (Sinatra,
`Rack::Builder`, `Builder::XmlMarkup`, Shoes) with `instance_eval`.

That last group is worth separating out, because it is the mechanism that
actually makes a Ruby-style tree work. `yield` is *not* it: `yield` is
how a callee invokes the caller's block, which Emo already has —
`syntax.md` makes the block the final argument and the component calls
it by its declared name. Ruby's DSLs work because the block is
`instance_eval`'d *on the container*, so a bare `navbar` resolves as a
method of that container. That is self-rebinding, and it is the one
mechanism Emo can least afford: it makes every bare identifier in the
block mean something different depending on where the block is passed,
which is the definition of structure the reader cannot see.

## Emission does not change the data model

The backend seam consumes a `Node` **value**:

```emo
interface Backend {
  def mount(root Node) Void
  def patch(old Node, new Node) Void
  def run() Void
}
```

([`emo-ui.md`](emo-ui.md), Layer 6; reconciliation with keys is named
there as the growth edge.) An emitter therefore has to materialize the
tree as a value internally regardless — so emission changes who builds
the array and how the call site is punctuated, not what the program
computes.

That is the whole trade. Against it: an emit-shaped tree has no type
checking at all, because its body is a `Block` and `Block` is `Unknown`
([`type-system.md`](intro/type-system.md)). EmoUI's published promise
is that props *are* checked — "props are checked by the built-in type
checker (gradual typing)" — and the array child form is the only spelling
that keeps it. Emo's own rule for syntax closes the case: "Brevity alone
never earns a construct."

## Template languages: three shapes

"Template language" is not one thing. Three shapes behave differently,
and only one of them threatens the type checker:

- **Text with holes, evaluated by an engine** — ERB, Handlebars, Vue
  single-file components. The expressions are evaluated by a runtime with
  its own scoping; the host's checker never sees them.
- **A template compiler with its own checker** — Angular's
  `strictTemplates` checks template expressions against the component's
  declared types.
- **A translator to host source** — Templ to Go, Svelte to JS, JSX to JS.
  The host's own checker runs on the generated code, so static checking
  survives intact.

The first shape is what README's "**no template language — the UI is
plain Emo code**" was written against, and what
[`configuration.md`](intro/configuration.md) settled for configuration
when it faced the same temptation: "Because the type checker is built in,
configuration schemas are just type declarations checked by the same
pass — no second schema language needed."

The third shape is a real option, and it does not split the checker. That
part of the objection was too broad, and the decision is legitimately
open to review at this narrow point.

## Templ, and what does not transfer

Templ is the worked example of the third shape: `.templ` files are parsed
by Templ's own parser and `templ generate` emits `.templ.go`, which
`go build` then type-checks. Type safety in Templ *is* the Go compiler
checking generated Go.

What Templ preserves is narrower than it looks. It checks the Go
expressions you embed; it does not check the document. `<div>` inside
`<tr>` is not an error, and spread attributes are `templ.Attributes` — a
`map[string]any` — which Templ's own documentation calls out as
unchecked. So the property that transfers is *expression-level* typing,
not structural typing.

Two things do not transfer to Emo at all:

- **Templ exists as a separate tool because Go's grammar cannot be
  extended.** Go rejects syntax extension by design, which is why the
  template has to live in its own files with its own parser, formatter,
  LSP, source maps, and a `generate` step in the build. Emo's grammar can
  be extended — that is the premise README states as "Emo's syntax is
  shaped to serve it". Adopting Templ's *shape* would import a workaround
  invented for a constraint Emo does not have, along with all of its
  costs.
- **Templ's generated code is unreadable** — magic-prefixed temporaries,
  writes into a buffer, per-statement error propagation — because it is
  emit-shaped. That is what makes source maps necessary. An Emo
  desugaring would target a plain expression: nested calls with an
  `Array[Node]` children argument, no temporaries, no buffer, no error
  plumbing. Generated Emo would be readable, which means the natural home
  for the desugaring is Emo's own parser rather than a generator.

And one property would be *better* than Templ's: because the desugaring
target is a typed tree constructor rather than a byte buffer, the
children argument is genuinely `Array[Node]`, so the tree's structure is
checked as well as its expressions.

## The options

- **A — array children, no sugar.** Settled (decision 3). Zero language
  change. Verbose in the dynamic case.
- **B — array children, plus a cheap container.** `List` is the O(1)
  deque that mutates in place, and `push_back` returns the list, so a
  loop can fill one; the missing piece is a `List -> Array` conversion
  ([arena-scope](../spike/arena-scope), "A side finding for EmoUI").
  Zero syntax change, and it removes the verbosity that makes A expensive:

  ```emo
  def view(users Array[User]) Node {
    const kids = List.new([])
    kids.push_back(navbar(children: [logo(), menu(routes)]))
    for var i = 0; i < users.length(); i = i + 1 {
      kids.push_back(card(
        user: users[i],
        children: [text(users[i].name), text(users[i].bio)]
      ))
    }
    return page(title: "Home", children: children_of(kids))
  }
  ```

  `children_of` is spelled as a call rather than a `kids.to_array()`
  method because no such conversion exists in the language; writing it in
  Emo means writing it on top of `append`, which is where B's quadratic
  cost goes instead of away. `spike/emo-ui-spelling` measures all of this
  and finds that `Map.set` plus `Map.values()` is the one container route
  that does no array growth at all — so the conversion belongs in the
  runtime, walking the deque, not in a library def.

  **That reading closed on 2026-10-15 (T49.3), and not in either shape
  named here.** The language gained a third container: `ArrayBuilder`
  grows in place by `push` in amortized O(1) and `to_array()` is the
  copy-out, so B's cost profile no longer needs a conversion added to
  `List` — and the measurement above is part of why it is not the deque.
  The settled choice stands as written (A, whose static case needs no
  container at all; whether the children representation moves off the
  decided `Array[Node]` is T48.1's to settle). What changed is that the
  piece B was missing is no longer missing.

- **C — a tree literal form in Emo's own grammar.** Parser-level
  desugaring to exactly the nested calls of A. Keeps the checker, the
  `Array[Node]` child list, `patch`, and every backend; costs a real
  language change (parser, checker, six backends, formatter, LSP) and
  makes Emo's grammar markup-aware.
- **D — an external translator to `.emo`.** Templ's shape: its own
  parser in its own files, emitting Emo that the existing checker then
  checks. No compiler change at all, which is what makes it cheap to
  prototype — and it can live in the EmoUI repository, so the language
  repository stays untouched. Costs a second syntax, a second toolchain
  (formatter, LSP, error mapping to the source file), and a build step.

A and B are compatible: B is A with the container question answered. C
and D desugar to the same target, which is the reason B is not wasted
work under either.

One thing a translator makes clear: **a tree literal dissolves the block
problem by desugaring it.** `navbar() { logo(); menu(routes) }` becomes
`navbar(children: [logo(), menu(routes)])` as a text transformation with
full knowledge of the target — not as emission. That is why the
attraction is real, and it is also why it changes nothing about the
trilemma above: the desugared result is A.

## What is closed, and what is open

**Closed.** Emission, self-rebinding, and an ambient collector — each
fails for its own reason, given above. Implicit child collection stays
rejected as a language rule ([`emo-ui.md`](emo-ui.md), ask 2): there is
no construct that collects a block's expression statements. And a
template language in the first shape — an engine with its own
evaluation — contradicts both README's stated principle and the
configuration precedent.

**Open.** Whether EmoUI gets a tree literal at all, and if so whether it
is C (in Emo's grammar) or D (an external translator). The narrow form of
the question is: *does Emo's grammar grow markup-aware, or does EmoUI
ship a second syntax?*

**The evidence gap.** Neither branch has been tested against real code.
No one has written a screen of array-style EmoUI and measured how bad it
is; the samples in this note are illustrative. The cheap, reversible
order is: do B, write the T48.1 portable core and a screen or two of real
UI in the A spelling, and decide C versus D from that — at which point
the question can be answered with line counts instead of arguments, and
neither answer wastes B, because both desugar to the same tree.

**The evidence, measured 2026-10-15.** `spike/emo-ui-spelling` wrote the
T48.1 core (portable, `Array[Node]` children) and the two screens above
in both spellings, plus a headless debug backend so the trees render:

- **A is 95 lines, B is 40**, for byte-identical renders — the same two
  screens, with every fixed-child-list widget shared verbatim between
  them, so the delta is exactly how the dynamic lists are assembled.
- **44 of A's 95 lines are iteration builders** (`no_nodes`, `concat`,
  `field_rows`, `action_buttons`, `message_rows`, `each_from`). These
  exist to turn an `Array[Field]` into an `Array[Node]`, which is a
  data-driven transform, not tree shape.
- **A tree literal deletes brackets and nothing else here**: 72 bracket
  tokens in A, 18 in B, and **0 `children:` labels in either** — the
  constructors take children positionally, so the label this note's
  option-B sample is built around does not appear in real code.
- The `each_from` idiom this note's sibling doc publishes (`[f(xs[i])].append(each_from(...))`) is **wrong**: `Array.append` takes one element, so it builds a nested array, and it type-checks only because the element comes through a `Block`. It is caught by nothing; the two screens render differently and only a child-count assertion notices. The corrected collector carries an accumulator.
- **B's asymptotic win does not exist yet.** `List` is O(1) to fill, but the hand-written `List -> Array` conversion is a loop over `append`, so its copy count is identical to the naive accumulator's (4480 cells at k=32). `Map.set` + `Map.values()`, by contrast, does **0** array appends and **0** copies at every k on the ladder — the linear route already exists in the runtime, so the conversion should be a runtime primitive over the deque.

What that decides: **B is the step that pays, and it is a container
question rather than a syntax question.** C's price — parser, checker, six
backends, formatter, LSP, a grammar that knows about markup — buys the
brackets, and leaves the 44 builder lines untouched, because a literal
that "desugars to exactly the nested calls of A" inherits them. C earns
its price only if the literal also grows a loop form, at which point the
thing being priced is no longer a tree literal. D can do better than this
note assumed, for the reason this note gives for D: a text transformation
with full knowledge of the target can lower a loop *inside* the literal
straight to B's container form, deleting the brackets and the builders
with no language change at all.

So: **do B; then D if the ergonomics still hurt; C only if D's second
toolchain turns out to cost more than a markup-aware grammar.** One
experiment on two screens supports a claim that size, and no more. The
target matrix there is not incidental either — of the five hosted
targets, only `typescript` compiles the core today.

## References

- [`emo-ui.md`](emo-ui.md) — the assessment; Layer 1 is the composition
  discussion, decision 3 is the settled spelling, ask 2 is the implicit
  collection ban.
- [`visualization.md`](visualization.md) — decision 14, the same shape
  chosen for plot.
- [`intro/syntax.md`](intro/syntax.md) — attached blocks, explicit
  parameter types, the `return` discipline, the statement forms, and the
  mutable six.
- [`intro/type-system.md`](intro/type-system.md) — `Block` is `Unknown`.
- [`intro/configuration.md`](intro/configuration.md) — config as an Emo
  expression, the precedent for "no second language".
- [`emo-ui-check.md`](emo-ui-check.md) — the spikes; `spike/components`
  is the React/Elm-style application that already runs byte-identically
  through AppKit and GTK 4.
- `spike/arena-scope` — why children arrays want a different container.
  That container now exists: `ArrayBuilder` answers this ask, which is
  why the composition example no longer has to accumulate with
  `Array.append` (whose one-element copy is
  `src/emo_eval/emo_eval.ml:2147`); the discarded-statement fact it was
  weighed against is `src/emo_check/emo_check.ml:2639`.
- `spike/emo-ui-spelling` — the measurement the evidence gap above asked
  for: the T48.1 core and two real screens in both spellings, the
  child-array builder ladder, the two `src/` codegen defects the core
  hits, and the checker's coverage of a wrong child literal.
