# EmoUI — the task tracker

EmoUI's landed work is the compiler track's Step 48: the fourteen tasks
T48.1–T48.14 (M15), all complete, listed in the Emo tree's
[`docs/TASKS.md`](../../../docs/TASKS.md) and not renumbered here — this
tracker does not write into the compiler's numbering. What this file
holds is the project's own open questions, registered 2026-11-05 so
they carry numbers and a home the way [EmoOS's](../../emo-os/docs/TASKS.md)
and [emo-desktop's](../../emo-desktop/docs/TASKS.md) trackers hold
theirs; the root `CHECK.md` "remaining work" list mirrors it.

The two are design decisions, not scheduled tasks — they block nothing,
and each settles where undecided design settles, the
[composition record](../../../docs/emo-ui-composition.md). Registering
them here gives the decision a number, a trigger, and a line to check
off. The specs behind them: the project [`README.md`](../README.md),
the assessment [`docs/emo-ui.md`](../../../docs/emo-ui.md), and the
package references beside this file.

## The open questions (recorded 2026-11-05)

- [ ] **Q1** — Whether the array-children spelling earns a literal at
  all. The settled base is explicit `Array[Node]` children (the
  assessment's decision 3) with `ArrayBuilder` as the dynamic
  collector (settled 2026-10-15, T49.3 — option B's missing piece, no
  longer missing), so the question stands exactly as the composition
  record narrows it: does Emo's grammar grow markup-aware (C), does
  EmoUI ship a second syntax (D), or does neither earn its place. The
  evidence in hand is the `spike/emo-ui-spelling` measurement
  (2026-10-15): A is 95 lines against B's 40 for byte-identical
  renders, and 44 of A's 95 are iteration builders a literal
  inherits — a tree literal deletes brackets (72 tokens to 18) and
  nothing else, no `children:` label among them — so C's price
  (parser, checker, six backends, formatter, LSP) buys the brackets
  and leaves the builders, earning it only if the literal also grows
  a loop form, at which point the thing being priced is no longer a
  tree literal. The record's standing order: B, landed; then D if the
  ergonomics still hurt; C only if D's second toolchain turns out to
  cost more than a markup-aware grammar. Settling is a dated update to
  the composition record's "What is closed, and what is open", and
  this line checks off.
- [ ] **Q2** — Where the `.emoui` translator sits in that question. D
  exists as a working prototype (2026-10-18,
  [`translator/`](../translator)): a stdin-to-stdout filter, 1,239
  lines of Emo across four modules, no compiler change, its demo
  holding the literal form to the A spelling through `debug.render`
  with `check.sh` regenerating and diffing the committed render. The
  prototype settled that the translator itself stays cheap — leaf
  expressions are opaque spans, it never parses Emo — and that D's
  real cost lives elsewhere: editor support for `.emoui` and
  span-accurate error mapping, both still undone. Where it sits — a
  demo until Q1 decides, or the seed of a shipped D growing the
  editor half and a place in the build — follows Q1; this entry
  exists so the prototype's standing is on the record rather than
  implied.
