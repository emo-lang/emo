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
  builder statements outnumber widget calls), at which point this
  verdict is the first thing to revisit.

## The open questions (recorded 2026-11-24)

- [x] **Q3** — How a backend that keeps its widgets tells which old node
  a new one continues, and what names a node across renders — the
  assessment's first remaining question, reconciliation
  ([`docs/emo-ui.md`](../../../docs/emo-ui.md)). Settled 2026-11-24:
  **position and kind, with a key on the node to override position.**
  The decision, in three parts. *The diff is the core's, once:*
  `ui.diff(old, next)` matches the tree a backend last saw against the
  next one and answers a `Patch` for every slot of the new tree, so the
  rule is written one time and — rendered as text by the debug backend
  — pinned byte for byte on every hosted target, the way the tree itself
  is. *Identity is position and kind:* a child without a key continues
  the unkeyed child that held its position among its unkeyed siblings
  when the two are of the same class, so an unkeyed list keeps its
  widgets while nothing moves and a keyed sibling arriving or leaving
  leaves the unkeyed positions alone. A key overrides position:
  `ui.keyed(key, node)` names a child across a reorder, an arrival or a
  leave. A slot whose class changed is replaced, not continued, whatever
  its key; two children under one key raise rather than pick the first.
  *The key is the node's own:* a field on each of the core's eight node
  classes, set through `ui.keyed`, which answers the node it is given
  carrying the key — not a slot on `Style`, because identity is not a
  layout property, and not a wrapper node class, because every backend's
  `is()` walk (the framebuffer's included) would have had to learn to
  unwrap it. The backends that keep widgets — AppKit, GTK, the DOM —
  keep what the diff keeps; the terminal and the framebuffer repaint
  whole, as before. The rule is the package reference's
  ([`ui.md`](ui.md), "Keys and the diff"). What the question's other
  half named, the compiler's targeted refresh, did not land with it and
  stays the long-term form. This line checks off.

## The open questions (recorded 2026-11-24, from the first application)

- [ ] **Q4** — what the first application could not say. The calculator
  ([`apps/calculator`](../apps/calculator/README.md)) is the smallest
  application a person uses, and it needed four things EmoUI has no
  word for. Each is a question for the core; the application works
  around it and decides nothing. *A length with a unit:* a `Style`
  number is a cell on a terminal, a point in a window and a pixel on
  the web, so the calculator takes its gaps as an argument and each
  entry passes its platform's number. *A node's equal share:* `grow`
  divides what is left after each child's own width, so keys are one
  width only where a label is measured in characters — in a browser an
  operator's key is 40 px against a digit's 46. *A label by code
  point:* the terminal measures and the framebuffer paints a label a
  byte at a time, so no key can read `×`, `÷`, `±` or `⌫`. *A leaf's own
  height:* a key is one line tall wherever a cell grid or a glyph's
  line box is the unit, and a `height` in a `Style` would be as many
  cells as pixels. The application's README carries each with its
  evidence, beside two gaps the assessment
  ([`docs/emo-ui-missing.md`](../../../docs/emo-ui-missing.md)) already
  named and the calculator confirmed: no keyboard, and a `Style` that
  says layout and nothing else. Like Q1 and Q2 this is a design
  decision and not a scheduled task; it settles in the core's package
  references and blocks nothing.
