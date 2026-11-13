# Step 76 — `emo wasm run`: the CLI rung

**Milestone:** M38 · **Prereq:** step 75 (the package and its execution
surface) · **Status:** done

The ladder's second rung: the CLI executes a `.wasm` artifact. The
decided direction holds — the CLI drives its own interpreter over an
embedded Emo driver, and the compiler never links the runtime: the
step-20 boundary holds in both directions. The machinery is the
toolchain's own embedded-program shape (`run_embedded`, the publish
uploader's path): a scratch project materialized in the temp
directory, its manifest pinning the bundled packages at their highest
versions, the program resolving `wasm` and `file` from the standard
library shipped inside the binary — a lone `emo` binary runs an
artifact with no registry and no project of its own.

## Decided now

**What "run" means.** `emo wasm run foo.wasm` loads the artifact,
validates it, and instantiates it — the instance's start function runs
here, as the spec says it does. Then the entry export: `_start` (the
WASI convention) when the module exports it, `main` otherwise; when
neither is exported, the module has run its initialization and the
command answers the one-line `describe` summary — a module is not
refused for having no entry, because initialization is running it.
The export's results print one per line in the runtime's own
`value : kind` format. Everything failure-shaped — a bad artifact, a
failed link, a trap — answers `(R.error, reason)` inside the driver
and reaches the user as a nonzero exit with the reason on stderr; no
raise crosses the CLI.

**The driver's data rides as host-injected bindings.** The artifact's
absolute path passes as the `__artifact` global — the publish
uploader's channel, not a new language surface, and not a path baked
into source. The driver reads the artifact through the `file` package
and feeds `wasm.load` its bytes; both packages pin at the bundled
library's highest versions.

**The exchange framing carries the verdict.** The driver prints the
numeric status line first (`0` ok, `1` error), the body after — the
same framing the fetch programs use, parsed by the same
`parse_exchange`. Captured output keeps the command deterministic: the
CLI prints the body to stdout on success, the reason to stderr on
failure, and exits with the verdict's code.

**Strictness.** The host table stays empty: a module whose imports the
package cannot serve (anything beyond `spectest`) links-fails honestly
with the import's name — WASI is step 77's rung, not a silent stub
here. No arguments reach the module (the MVP has no argv channel; a
module that wants data gets it through memory, and the CLI adds no
fiction).

## Scope

### In

- The `wasm` command group in the CLI with its `run` subcommand; the
  embedded driver; the generalized embedded-program runner (the
  existing `run_embedded` delegating to it, so the publish path
  inherits one body of machinery).
- Tests in `test/emo_cli/`: a valid module with a `_start` export
  answering its results; a module with only a start section answering
  the summary; a module importing from `env` failing the link with the
  import's name; a malformed artifact failing in the decode phase; a
  trap answering as the error verdict. Each built from hex in the test
  itself, no fixtures on disk.
- Docs: the CLI section in `docs/stdlib/wasm.md` (EN + zh); the
  `doctor` wasm line naming the command; TASKS/plan/CHECK updates.

### Out

- WASI and the `emo` host module — step 77.
- Running the output of `emo build --target wasm` (the GC proposal's
  types) — the ladder's exit sign, unchanged.
- `emo wasm inspect`/`dis` and friends — no consumer has asked.
- Arguments, environments, clocks for the module — the `emo` host
  module's surface is step 77's design, not smuggled in here.

## Tasks

- [x] **T76.1** — The generalized embedded runner: `run_embedded`
      delegates to a form that takes the dependency list; the wasm
      driver program lands as an embedded string (`__artifact` global,
      the exchange framing, the entry ladder `_start` → `main` →
      summary, the `value : kind` result format over the public
      surface).
- [x] **T76.2** — The `emo wasm run` command: the `wasm` group, the
      run subcommand (artifact argument, absolute-path resolution
      before any chdir), the status-line-to-exit-code mapping, the
      doctor line.
- [x] **T76.3** — The tests and the docs.

## Acceptance

- `emo wasm run demo.wasm` on a binary-only machine (no registry, no
  project) instantiates and runs the artifact's entry, printing
  results in the runtime's value format; every failure mode answers
  with the reason and a nonzero exit, never a raise or a backtrace.
- The publish/login embedded paths behave unchanged (the generalization
  is a refactor they delegate to).
- `dune runtest` green, `@fmt` green.
