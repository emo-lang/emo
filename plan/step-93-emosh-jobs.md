# Step 93 — emosh's background jobs

**Milestone:** M44 · **Prereq:** step 92 (the shell's everyday
surface), the os package at 0.1.0 · **Status:** landed 2026-11-22
(code, fixtures, docs; the os demo byte-identical on the interpreter
and both targets, ten fixtures byte-identical on both, the pty-driven
notification run by hand on both)

## Why this step exists

The shell could not put anything in the background — `&` refused by
name — and the os surface had carried the discipline's tools unused
since the playground landed them: `setpgid`, `kill`, the negative-pid
group shot, the `wait_*` decoders. One door was missing: a wait that
answers without parking, so a shell can poll its jobs the way it
polls nothing else. This step lands that door (`os.waitpid_nohang`)
and spends it: `&`, the job table, the notification line, and the
five builtins a background job is no good without.

## Decisions settled here (the trail)

- **The nohang answers `(R, (pid, raw))`, not `Void` with a raise.**
  `waitpid`'s raw word is a raise-carved shape (its failure raises);
  the nohang's failure is data a poller consumes — ECHILD is an
  expected answer in a poll loop, not an exceptional one — so it
  rides the kill/setpgid `(R, …)` shape, the errno reason carried by
  `os_result`/`emo_os_fail` byte-identically
  (`os: waitpid_nohang: No child processes`).
- **Children-but-none-exited answers `(R.ok, (0, 0))`.** The
  kernel's own zero, not an error — a poll loop asks "is it done"
  and the honest no is a value.
- **The stub answers `(pid-or-0, raw)` as a tuple.** The blocking
  stub answers only the status word (the asked pid is the answer's
  pid); the nohang needs the kernel's zero-or-pid beside it, so the
  stub allocates the pair and the runtime arms pass it through.
- **The parent pins the group.** Each background member is
  `setpgid`ed into the first member's group from the parent, the
  moment that child is forked — no child-side race, no ceremony in
  the child, and the discipline the os package documented ("the fork
  child's first call") finally has its consumer. A foreground
  command keeps the v0 shape: no group of its own, Ctrl-C lands on
  it.
- **The notification is the report.** A finished job is announced
  (`[1] done sleep 5`, the status after `done` when it is not zero)
  and removed in the same poll — being reported and being dropped
  are one act. Interactive only: a script's background jobs are
  silent, the classics' way. The poll runs before every prompt.
- **`fg` waits, honestly.** Without a terminal-handoff call the job
  keeps its own process group, so a Ctrl-C aimed at the shell's
  group cannot reach a job `fg` brought back — the guide states it,
  and `tcsetpgrp` is the os half waiting for a milestone to name it.
- **`bg` answers bash's own line.** Nothing in this shell ever stops
  a job — a job is born running in a group of its own — so `bg`
  answers `already in background` with status 1, the truthful
  version of the classic's refusal.
- **`kill %n` is the negative pid.** The group id the job's first
  member made is the whole pipeline's death in one call — the
  os package's documented discipline, aimed by the job number.
- **A fixture never lets a background child speak.** The first cut's
  `echo back &` interleaved its bytes with the next lines at
  different moments on the two targets — a divergence the diff
  caught between two runs of the same fixture. Every background
  child in `bg.esh` is silent (`sleep`), every answer waited on
  before the fixture speaks again, and the `jobs` row's pid is cut
  by `awk` (the pid is the one thing a golden must not pin).
- **`os.sleep_ms` is the c runtime's alone.** The os_demo poll's
  first cut parked its child with a sleep and died on the
  interpreter (`E3009`) and the ocaml target (`E3007`) — the pipe
  park with a wake byte is the deterministic shape all three hosts
  share.

## The shape

- `os.emo` + the seven runtime/checker sites — the kill/setpgid
  checklist, one name longer.
- `shell.emo` — `Job` (n, representative, the unreaped rest, the
  text, the final status), `decode_status`, the table on the session
  (`job_new`'s smallest-free-number, `find_job`, `drop_job`,
  `notify`, `list_jobs`, `wait_all`), `$!` riding `last_bg`.
- `lex.emo` — the `&` operator. `parse.emo` — the item's `bg` flag,
  the amp-as-separator. `exec.emo` — `spawn_pipeline` (the setpgid
  pin, the shared fork-and-wire), `run_background`, `item_text`,
  the pre-prompt poll.
- `builtin.emo` — `jobs`/`fg`/`bg`/`wait`/`kill` and the job-spec
  reader (`%n` or a bare number).
- `expand.emo` — `$$` and `$!` in the `$`-form walk.
- `fixtures/bg.esh` (new), `fixtures/errors.esh` (the `&` refusal
  row retired to `2>&11`), `examples/os_demo` (the poll section).

## Found on the way, fixed in step

- `a & b` parse: the first cut demanded a connector after the `&`
  and refused every `sleep 5 & wait %1` — the spawn is itself the
  separator, the next item riding behind it.
- The `echo back &` fixture interleaving (above) — silent children
  only.
- The `os.sleep_ms` c-only discovery (above) — the pipe park
  instead.
- `docs/stdlib.md`'s os section had said `["ocaml", "c"]` since the
  wasm half shipped — fixed while growing the docs.

## The honest limits (the guide states them)

Background jobs exist but the terminal does not negotiate: no
`tcsetpgrp` (a `fg`-brought-back job cannot receive Ctrl-C), nothing
stops a job (`bg` always answers already-in-background), a
background job's stdin stays the shell's, and the shell exits
leaving running jobs behind. The os half of the first is the
named next candidate.
