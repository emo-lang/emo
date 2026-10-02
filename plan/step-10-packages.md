# Step 10 — Packages & Version Resolution

**Milestone:** M2 complete · **Prereq:** steps 01–09 · **Status:** done

## Goal

Packages as the README specifies: a package name is a module-path prefix,
`require` is a file-level statement strictly paired with the manifest,
manifests are Emo config files in the restricted profile, dependencies are
exact versions resolved by MVS into a checksummed lockfile, fetched from a
configurable central registry into a global content-addressed cache.

## Scope

### In

- **`require` syntax** (parser addition): file-level
  `require "acme/json_tools"` bringing the package's short name into scope.
  Not allowed inside functions/blocks; duplicates in one file are errors.
- **Manifest, phase A — schema parser:** the manifest file (name pending,
  `CHECK.md`; provisional `package.emo`) is read by a strict, fixed-schema
  parser accepting exactly the README shape:
  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["native", "wasm"]

    deps {
      json = "2.3.1"
      http = "1.4.2"
    }
  }
  ```
  Unknown fields, missing fields, and non-literal values are errors — the
  manifest is data, not program logic, in this phase.
- **Manifest, phase B — restricted evaluator:** upgrade the parser to a real
  restricted-profile evaluation (the README's configuration story): the
  full expression language minus unbounded iteration, with an evaluation
  step budget, no I/O builtins in scope, hermetic by construction. The
  budget-exceeded error must be precise ("manifest evaluation exceeded N
  steps"). This restricted mode is a reusable interpreter flag — the same
  machinery later serves user-facing config files.
- **Strict pairing** — a `require` whose package is absent from `deps` is a
  compile error naming both the file and the manifest (README: strictness
  first; the manifest changes only by explicit action).
- **Resolution (MVS)** — exact-version requirements; when multiple packages
  require different versions of the same dependency, the highest exact
  version named wins (MVS over exact pins). Target compatibility is checked
  at resolution time: a dependency lacking the current build target in its
  `targets` list fails resolution with a clear error, before compilation.
- **Lockfile** (name pending, `CHECK.md`; provisional `emo.lock`) — records
  the full resolution: package, version, source checksum; belongs in
  version control; regeneration is an explicit command. A mismatch between
  lockfile and manifest requirements is an error prompting explicit
  regeneration — never a silent re-resolution.
- **Registry & cache** — minimal central-registry client: fetch version
  manifests and package tarballs over HTTPS, keyed `name@version`;
  content-addressed global cache (shared across projects, no per-project
  vendored copies), checksum-verified against the lockfile. Registry
  endpoint configurable globally and per project. A local `file://` /
  directory registry serves tests and offline development — the same
  protocol, no special-casing in the resolver.
- **Scoped names** — third-party packages carry a scope prefix
  (`acme/json_tools`) whose short name (`json_tools`) is what `require`
  binds; the official standard library alone owns top-level short names.
  Scope-prefix format is pending (`CHECK.md`); implement with the current
  `owner/name` shape and keep it centralized for a later swap.
- **CLI** (names provisional, `CHECK.md`): `emo deps resolve` (write
  lockfile), `emo deps update <name>` (explicit upgrades only),
  `emo deps list`. Building (`emo run` / future `emo build`) resolves
  automatically when the lockfile is satisfied — no install step.

### Out

- Publishing tooling, registry server implementation, auth (separate
  infrastructure work).
- Version-range expressions beyond exact pins (pending, `CHECK.md`).
- Private registry authentication beyond endpoint configuration.

## Tasks

- [x] `require` parsing + scope rules.
- [x] Manifest phase A: strict schema parser, errors with spans.
- [x] Strict require/deps pairing check.
- [x] MVS resolver with target-compatibility gate; unit tests over version
      lattices.
- [x] Lockfile read/write/verify; mismatch errors.
- [x] Registry client + content-addressed cache + directory registry for
      tests.
- [x] Manifest phase B: restricted-profile evaluation with step budget.
- [x] End-to-end fixture: two local packages, one requiring the other,
      resolved, locked, built, run.

## Acceptance

- The README's `require "acme/json_tools"` / `json_tools.parse(text)`
  scenario runs against a fixture registry.
- Removing a dep from `deps` while its `require` remains → compile error.
- Two packages pinning different exact versions of a shared dep → highest
  wins, recorded in the lockfile, checksums verified on a second run.
- A dep whose `targets` exclude the current target → resolution-time error.
- **M2 exit criteria:** a multi-package project with a manifest, lockfile,
  internal modules, and full type checking builds and runs with `emo run`.

## Open design items

None — the provisional names settled during this step (`package.emo`,
`emo.lock`, `owner/name` scopes, exact pins, `emo deps *`) now live in the
README; `CHECK.md` keeps only what is still pending.
