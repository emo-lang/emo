# Renumbering — commit-message work log

Tracking the alignment of the `Task No` references baked into the **commit
messages** on `develop` with the final task numbering in `docs/TASKS.md`.

## Goal

- Every `T<step>.<n>` in a commit message matches the task it actually
  implements in `docs/TASKS.md` (the tree was already renumbered; the
  messages were not).
- Every `step NN` / `Step NN` / `step-NN` reference in a commit message
  points at the current step number.

## Why the messages were stale

The step/Task renumbering (`docs/temp-renumbering.md`, branch
`task/renumbering`) renumbered the **tree** — `docs/TASKS.md`, `plan/`,
the source comments — but did not rewrite the commit messages of the task
commits already in history. Those still carry the pre-renumber scheme, one
step off in every range the reordering touched.

## Mapping (old → new)

Identical to `docs/temp-renumbering.md`:

```
01–06 → 01–06
07 → 08     08 → 09     09 → 10     10 → 11     11 → 12     12 → 13
13 → 14     14 → 15     16 → 16     15 → 17     17 → 18     18 → 07
19 → 20     20 → 21     21 → 22     22 → 19
24 → 23     25 → 24     26 → 25
27 → 26     28 → 27     29 → 28     30 → 29     31 → 30
32 → 31     33 → 32     34 → 33     35 → 34     36 → 35     37 → 36
38 → 37     39 → 38
40 → 39     41 → 40     42 → 41     43 → 42     44 → 43     45 → 44
46 → 45     47 → 46
```

(The phantom `23` takes no number.)

Samples:

| commit subject (old) | commit subject (new) |
| --- | --- |
| `T10.1 — require parsing …` | `T11.1 — …` |
| `T15.4 — sockets and HTTP on the TypeScript target` | `T17.4 — …` |
| `T20.5 — LEB128 …` | `T21.5 — …` |
| `T24.5 — classes, enums, interfaces …` | `T23.5 — …` |
| `T27.1 — Reserve for / while …` | `T26.1 — …` |
| `T30.5 — the docs learn the tuple convention` | `T29.5 — …` |

## Scope

- **214** commits carry a `T<step>.<n>` task id in the message; all of
  them are remapped (single pass, so the swaps `15↔17`, `18↔07`,
  `19/20/21/22` do not collide).
- **Step-reference-only** commits (`Close out step 13`, `Step 39 — …`,
  `Decompose step 21 …`, the tracker check-offs) are remapped too.
- Padding is normalized on the way (`T6.6` → `T06.6`, `T8.10` → `T09.10`).
- **Deliberately left untouched:** the renumbering-operation commits, whose
  numbers are *historical facts about the operation*, not task labels —
  `Renumber the …` (`3086c69`, `593c381`, `0af37f6`, `f7ce41f`),
  `Backfill zh-CN …` (`49c467b`), `Make the milestone step ranges
  continuous`, `Move the … step into M4`, `Fix the phantom step-23 …`
  (`ecab804`, the phantom keeps no number). Their old → new prose is
  superseded history and must not be remapped.
- **Out of scope here:** `M`-milestone labels inside commit messages
  (e.g. `Plan M10 — target independence`). The task asked for `Task No`
  only; the `M`-labels in the tree were item 5 of `temp-renumbering.md`.
  A follow-up can align them the same way if wanted.

## Execution

Two `git filter-branch --msg-filter` passes over `develop`:

1. **Pass 1 — task IDs.** Rewrites the whole message (subject + body:
   `T`-ids, `step NN`, `step-NN` filenames) for every commit whose message
   contains a `T<step>.<n>`. Messages without a task id are returned
   byte-identical, so the renumbering meta-commits are never touched.
2. **Pass 2 — step references.** For messages that still carry no task id
   (pass 1 left them alone), remaps the `step NN` references, skipping the
   `Renumber` / `Backfill` / `Fix the phantom` / `Move the` / `Drop the
   EmoOS` / `Mirror the step` / `Track the remaining` / `Make the
   milestone` subjects.

Both passes are single-pass (one lookup per token), so the identity and
swap ranges are safe. Original commit hashes are preserved in
`refs/original/refs/heads/develop` and in the branch
`backup/pre-commit-renumber`.

## Verification

- `git diff backup/pre-commit-renumber develop` is empty — **no tree change**;
  this rewrites messages only.
- Every `T<step>.<n>` in every `develop` commit subject now exists in
  `docs/TASKS.md` (before: 26 ids did not).
- Spot checks confirm the remapped task text matches the tracker, e.g.
  `T27.1 — IR: the loop statements …`, `T28.1 — the built-in R { ok, error }`,
  `T29.1 — file and os return tuples …`, `Step 38 — the sqlite3 …`,
  `Step 46 — Unit test framework …`.
- Remaining `step` references are either current or the intentionally
  preserved renumbering-operation / phantom ones.

## Follow-up — not done

- [ ] Push: `develop` has fully diverged from `origin/develop`, so syncing
      the remote needs an explicit **force-push** (separate authorization).
- [ ] Optional: align the `M`-milestone labels inside commit messages.
- [ ] Optional: drop `refs/original/refs/heads/develop` once the rewrite is
      accepted (the standalone `backup/pre-commit-renumber` branch remains).
