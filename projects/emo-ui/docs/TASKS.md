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

- [x] **Q1** — Whether the array-children spelling earns a literal at
  all. Settled 2026-11-06: **neither earns its place.** The standing
  order's gate was "then D if the ergonomics still hurt", and the
  evidence gap the composition record named — real code in the
  spelling — has filled itself: the tree's EmoUI views are the corpus
  application and the desktop's three apps, five-to-nine-node trees
  whose fixed child lists are array literals (the clearest spelling
  for fixed data) and whose builder statements appear in exactly one
  view in the wild (the corpus's scroll items, exercising the
  vocabulary on purpose), five lines — the spike's feared 44-of-95
  builder proportion never showed up in real code. B's last missing
  piece landed on the metal (T8.25, 2026-11-05), so the spelling is
  one on every target. D's costs are still what the 2026-10-18
  prototype named — editor support, span-accurate error mapping, a
  place in the build, a second syntax documented across six backends
  — real money with no customer in the tree; C's price buys brackets
  only and is dominated. So: B, landed; the ergonomics do not still
  hurt; D stays a prototype (its demo unchanged), C stays out. The
  question reopens with a measurable trigger, named in the
  composition record's dated update: a real screen whose data-driven
  child lists make builder statements outnumber widget calls — the
  spike's 44-of-95 shape appearing in real code. Settling is the
  composition record's dated update ("A decision, 2026-11-06") and
  this line checks off. Q2's disposition follows: the translator's
  standing is the demo's.
- [x] **Q2** — Where the `.emoui` translator sits in that question.
  Settled 2026-11-06, following Q1: **the translator's standing is the
  demo's.** D exists as a working prototype (2026-10-18,
  [`translator/`](../translator)): a stdin-to-stdout filter, 1,239
  lines of Emo across four modules, no compiler change, its demo
  holding the literal form to the A spelling through `debug.render`
  with `check.sh` regenerating and diffing the committed render. The
  prototype settled that the translator itself stays cheap — leaf
  expressions are opaque spans, it never parses Emo — and that D's
  real cost lives elsewhere: editor support for `.emoui` and
  span-accurate error mapping, both still undone. Q1's verdict (same
  day: neither earns its place) leaves those costs without a customer,
  so the prototype ships nothing and grows nothing — it stays in the
  tree exactly as it is, the working answer to "what would D look
  like", kept green by its own demo gate. It becomes the seed of a
  shipped D only when Q1's named trigger fires (a real screen whose
  builder statements outnumber its widget calls), at which point this
  verdict is the first thing to revisit.
