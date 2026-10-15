# `dune test` at the repository root stalls intermittently

**Status:** open. Not reproduced on demand; cause not identified.
**Reported:** 2026-10-15 by the maintainer, as a recurrence ("stuck again").

This is a working note, not design. It records what was measured, what was
ruled out, and where a silent unbounded wait can still be hiding, so the next
occurrence can be caught rather than re-argued.

## Symptom

`dune test` run from the repository root occasionally stops making progress.
Nothing is printed, nothing fails, and the command never returns. There is no
outer timeout anywhere in the chain, so the only way out is to interrupt it.

It is intermittent: the same command on the same tree completes in roughly
80–95 seconds at other times. `dune test` is a slow suite even when warm — the
`emo_project` suite alone reports ~83s — and dune prints an action only when it
*completes*, so a long stretch of quiet is normal. That is what makes the stall
hard to distinguish from ordinary slowness while it is happening.

## What was measured (2026-10-15, HEAD `d1a232b`)

| Run | Result |
| --- | --- |
| `timeout 300 dune test` (root) | exit 0, `Test Successful`, 18:52:29 → 18:53:56, 87s |
| `dune build @test/emo_cli/runtest --force` | `Test Successful in 94.277s. 183 tests run.` |
| `timeout 400 dune test` (root, after the guard fix below) | `Test Successful in 79.181s. 183 tests run.` |
| `dune test` (root, tree up to date) | replayed from cache, exit 0, ~1s |
| `./projects/emo-ui/check.sh` | all five targets `ok`, exit 0 |

The stall did not reproduce in any of them.

## Ruled out

- **The T48.1 commit (`c6c2a27`).** `find projects spike -name dune` is empty,
  so `projects/emo-ui/` is outside dune's view entirely and cannot enter any
  alias. Of the tree, only `test/emo_cli` and `test/emo_project` link `emo_cli`,
  and both ran green in the runs above. The `src/emo_cli/emo_cli.ml` change is
  one string literal in `emoji_build`'s output path, reachable only from
  `emo emoji build`.
- **The waits inside the code that commit touched.** `Emo_tool.run_status`
  reaps with `waitpid WNOHANG` in a poll loop against a wall-clock deadline and
  then SIGKILLs the child's whole process group
  (`src/emo_tool/emo_tool.ml:118-145`). It cannot block on a pipe that never
  closes, by construction.
- **Build-lock contention.** With another dune already running, a second
  `dune test` prints `Error: Another Dune instance is currently running.
  Aborting...` and exits immediately. Contention produces a fast error, not a
  silent stall — so a stall is *not* "someone else's dune holds the lock".
- **"It is just slow."** Bounded at ~80–95s warm, as measured above.

Also found while investigating, unrelated to the stall, and fixed in
`d1a232b`: the T48.1 test `emoji build honors every target the manifest
declares` declares `beam`, and a beam build shells out to `erlc`, but the test
carried no environment guard where every other beam test in that file skips on
a missing Erlang. Without `erlc` the gate exits 70, so the test went red rather
than skipping. That was a test-hygiene defect, not a hang.

## Where a silent unbounded wait can still exist

Ranked by how well each fits the symptom.

1. **`runtime/wasm/dune` — 13 `(run %{emo} run <fixture>.emo)` actions under
   the `runtest` alias.** These waits are owned by dune itself, so
   `Emo_tool`'s deadline does not apply to them and dune has no per-rule
   timeout. A fixture that never returns stalls `dune test` with no output at
   all, forever. **This is the leading candidate.**
2. **`step_deadline = 600.0`** (`src/emo_tool/emo_tool.ml:19`). Every toolchain
   step that *is* covered can still sit silently for ten minutes before the
   deadline fires. Ten quiet minutes reads exactly like a hang.
3. **`deadline = 120.0` per command** (`test/emo_test_support/emo_test_support.ml:11`).
   The test executables are bounded, but per command and not per test: a child
   that blocks is killed after two silent minutes, and a test that makes many
   such calls can spend a long time quiet before it fails.
4. **Deadline-free `Sys.command` probes** in `test/emo_cli/emo_cli_test.ml`:
   `node_available` (:282), `erl_available` (:318), `erlc_available` (:324),
   `cc_available` (:518), `riscv64_available` (:2086, three tools). `Sys.command`
   has no deadline of its own.
5. **`emo run --target riscv64`** deliberately wraps qemu in a wait with no
   deadline (`src/emo_cli/emo_cli.ml:738-745`: "how long it runs is the
   program's business").

## Leading hypothesis

`test/emo_test_support/emo_test_support.ml:1-9` records the property that makes
this plausible:

> A program under test can block: the `beam`, `wasm` and node-hosted targets
> have no deadlock detection, so where the `c` target and the interpreter print
> `deadlock` and exit 70, those simply never return.

A deadlock in one of those targets is timing-dependent, so it would appear and
disappear between runs — matching the report. The test executables would catch
it after 120s and fail loudly, but the dune-owned `runtime/wasm` rules in item 1
above would not catch it at all. That combination — intermittent cause, silent
unbounded surface — fits the symptom better than anything else found so far.

Not investigated: the suite spawns `erlc`, `erl`, `node`, `cc`/`clang`,
`ocamlfind` and qemu, and dune runs aliases in parallel, so several run at once.
A tool blocking on a resource of its own rather than on our pipe would look
identical from the outside. Nor was the parallel scheduling of the aliases
examined.

## What to capture on the next occurrence

The single most useful datum is a **process snapshot taken while it is stuck**,
not the output, because there may be no output:

```sh
ps -eo pid,ppid,etime,state,command | grep -E 'dune|emo|node|erl|clang|qemu'
sample "$(pgrep -n emo)" 5 -file /tmp/emo-stall.txt   # stack of the live child
```

Along with:

- which phase it stopped in — the build (`ocamlopt …`) or the runtest aliases;
- the last line printed (with `--display short`, the last completed action names
  the neighbourhood);
- whether any other dune was running (the editor's OCaml integration runs
  `dune ocaml-merlin` continuously — one was observed resident during this
  investigation);
- machine load at the time.

Until this is closed, run long suites under an outer deadline — `timeout 600
dune test` (macOS: `gtimeout`, or coreutils under `/opt/homebrew`). Note that
`timeout` itself lives in `/opt/homebrew/bin`, so a test that narrows `PATH`
must call it by absolute path.
