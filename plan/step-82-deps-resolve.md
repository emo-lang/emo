# Step 82 — `emo deps resolve`: resolve honestly, refresh cheaply

**Milestone:** M43 — The lock refresh · **Prereq:** none (the plumbing
exists; this step repoints it) · **Related:** `src/emo_cli/emo_cli.ml`
(the resolve command's `~target:"c"` hardcode), `src/emo_project/emo_project.ml`
(`resolve_deps` already carries `~target`; `registry` already honors
`EMO_REGISTRY`), the eight family `check.sh` staging lists,
`CHECK.md`'s "The `emo deps resolve` resolves under the `c` target alone"
note (retired here) · **Status:** done — T82.1–T82.5 landed 2026-11-14;
the acceptance rehearsal ran (a package source touched, `just
lock-refresh` re-pinning the tree, the source restored and the lock
returning), and the full `dune runtest` waits for a requested run per
the auto-test rule, T82.4's five cases compiled into the suite.

## Why this step exists

On 2026-11-14 the `then` syntax migration changed 168 `.emo` sources and
with them every package digest; all 118 `package.lock` files pinning
those packages went stale, and `emo run` refuses a stale lock (E5007)
long before anything else runs. Repaying that by hand measured the debt
precisely, and the measurement named three gaps:

1. **`emo deps resolve` resolves under the `c` target alone** — the CLI
   passes `~target:"c"` where the whole pipeline below already carries a
   target, so a project whose deps are `riscv64`-only (every metal-side
   family package) cannot be served at all. Recorded as found-not-fixed
   in CHECK.md (T4.3's note); this step retires it.
2. **The staging lists are scattered.** Forty-eight family-package
   projects (the `emo-ui`, `fb`, and `emo-db` trees, `emo-os/hello`,
   `examples/ssr_page`, `examples/tui_menu`) pin packages that live in
   this repository, not in the bundled standard library. Each consumer's
   gate hand-stages a registry with its own `cp` lines — eight copies of
   what is really one mapping, and a lock refresh for those projects
   means re-reading eight scripts before any command can run.
3. **There is no lock-refresh entry.** After any package-source change,
   the question "which locks are stale, and how do I re-pin them" has no
   first-class answer; the 2026-11-14 repayment was three ad-hoc passes
   (69 default resolutions, 42 against a hand-built staged registry, 6
   offline digest recomputations).

## Goal

`emo deps resolve` resolves a project against its own declared targets
(or an explicit `--target`), honoring `EMO_REGISTRY` as every other
command does; the family staging lists live in one script both the gates
and the refresh entry use; and one `just lock-refresh` walk re-pins every
stale lock in the tree, so the next package-source change costs one
command instead of an afternoon.

## Decisions settled here

- **A lock's checksum is target-free, so resolution checks every declared
  target.** The checksum hashes package content; the target only decides
  whether a pinned version qualifies at all ("no build for target `c`").
  The honest rule: `emo deps resolve` with no flag solves the manifest
  once per declared `targets` entry and refuses when any target lacks a
  build for any dep — the lock records a digest the project can trust on
  every target it claims. `--target <t>` narrows the check to one target
  for the exceptional workflow (staging a not-yet-declared target), and
  says so in the lock-writing output.
- **`EMO_REGISTRY` keeps winning, as it already does.** The registry
  chain (`EMO_REGISTRY`, then the manifest's `registry` field, then the
  bundled standard library) is shared code the resolve path already
  calls; nothing to build, only to document and test. The 42 successful
  staged-registry resolutions of 2026-11-14 are the evidence it works.
- **One staging script, eight consumers.** `scripts/stage-registry.sh`
  holds the family staging map (package → source directory → file set,
  verbatim from today's `check.sh` lists) and materializes a registry
  directory; every family `check.sh` sources it instead of carrying its
  own `cp` block, byte-identical in what it stages. The script is the
  single source of truth, and `just lock-refresh` uses it for the
  family projects the bundled library cannot serve.
- **The refresh entry is a just recipe, not a CLI flag.** Walking the
  tree is a repository concern (which directories hold locks, which
  registry each family needs), not a package-manager one;
  `emo deps resolve` stays per-project and honest. `just lock-refresh`
  iterates every tracked `package.lock`'s directory, runs
  `emo deps resolve` there with `EMO_REGISTRY` passed through, and
  reports the per-directory results; `REGISTRY=<dir>` hands a staged
  registry to the walk.

## Tasks

- **T82.1** — Resolve against the project's targets: drop the
  `~target:"c"` hardcode (`emo_cli.ml`, the resolve handler), solve once
  per declared target, refuse on any target's missing build with the
  target named per dep, add `--target <t>`, and retire the CHECK.md
  note. (Found-not-fixed: T4.3's c-target-only resolution.)
- **T82.2** — `scripts/stage-registry.sh`: the family staging map in one
  place; repoint the eight `check.sh` staging blocks at it; verify each
  gate's staged file set is byte-identical to what it staged before
  (the digests must not move).
- **T82.3** — `just lock-refresh`: the tree walk, per-directory results,
  `REGISTRY=` passthrough for the family projects; document the
  after-a-package-source-change workflow beside it.
- **T82.4** — Tests: a manifest declaring multiple targets resolves only
  when every target qualifies; a `riscv64`-only dep in a
  `riscv64`-only project resolves; a stale digest is detected and
  re-pinned to the same value a second resolve produces (idempotence).
- **T82.5** — Docs: `docs/toolchain.md`'s dependencies section (and the
  zh-CN mirror) states the targets rule, the `EMO_REGISTRY` chain, and
  the refresh workflow; CHECK.md's retired note points here.

## Acceptance

The step's own rehearsal is the 2026-11-14 scenario replayed: touch one
standard-library package's source, run `just lock-refresh`, and every
lock in the tree — the 69 bundled-library pins, the 42 family pins
through the staged registry, and the 6 `riscv64`-only pins — re-pins to
a fresh digest with one command, no hand-built registries, no offline
digest arithmetic. `dune runtest` green with T82.4's tests; the eight
family gates still pass with the shared staging script feeding them.
