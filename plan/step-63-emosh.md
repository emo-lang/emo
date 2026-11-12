# Step 63 — `emosh`, the shell in Emo

**Milestone:** M26 · **Prereq:** step 56 (the `os` surface on every
target it declares) · **Status:** landed 2026-11-12 (code, fixtures,
docs; the full hosted suite ran green — 398 tests, exit 0)

## Why this step exists

The language has had every part of a Unix program's life except the
one program that ties them together: the shell. `os` carried fork,
exec, wait, pipes, and raw descriptors, but nothing could wire a
child's stdout to a pipe (`dup2`), find a command on `PATH`
(`execvp`), read its own arguments (`argv`), tell a terminal from a
file (`isatty`), pass an environment down, or hold off a Ctrl-C — so
nothing could be a shell. This step lands the missing os surface and
`emosh`, the general-purpose command interpreter written in Emo, in
`projects/emo-shell`: the classic shape — words and operators,
`$var`/`$?` expansion, pipelines forked per stage, redirections,
`;`/`&&`/`||`, the eight builtins, exit statuses — with every
simplification stated in the guide instead of hidden.

## Decisions settled here (the trail)

- **The os surface grows in place at 0.1.0.** The net+TLS precedent:
  a bundled stdlib package extends without a version bump, and the
  examples that pin it re-resolve their locks. `dup2`, `execvp`,
  `isatty`, `argv`, `getenv`, `setenv`, `unsetenv`,
  `signal_ignore`, `signal_default`, and the `sig_*` constants join
  the package; the new process-half names raise on wasm at the call,
  the capability naming itself, like the seven that preceded them.
- **Reasons stay byte-identical across targets.** The getenv miss is
  hand-written (`os: getenv NAME: is not set`) on both runtimes — the
  c side writes the text itself instead of strerror's errno; the
  setenv/unsetenv reasons name `setenv`/`unsetenv` on both, not the
  OCaml putenv underneath; the out-of-range signal answers
  `os: signal_ignore 99: invalid signal` everywhere, a range guard
  riding ahead of the call.
- **argv rides a captured main.** The generated c main becomes
  `int main(int argc, char **argv)` and hands the pair to
  `emo_args_set`; `os.argv()` answers the cell array. isatty and argv
  are the plain-value kind (like `getpid`), never a failure.
- **Every byte through raw descriptors.** The shell never writes
  through a buffered stdout: a fork child running a builtin would
  lose its buffer to `_exit`'s skipped flushes, and the parent's
  stdio and the children's raw fds would interleave
  nondeterministically. One path — `os.write` — answers both, and
  makes the two targets' fixture runs byte-comparable.
- **No catch, so errors are values.** The lexer and the parser
  answer `(R.error, reason)`; the session prints the reason and
  carries on with status 2. The runtime's failures ride the
  `(R.error, reason)` os values. Nothing in emosh raises.
- **The ignored-interrupt discipline.** sig_pipe ignored in every
  mode; sig_int and sig_quit ignored in an interactive session; the
  fork child calls `signal_default` on all three before its exec —
  an ignored disposition survives the exec, a default's death is the
  ordinary one. Ctrl-C in cooked mode flushes the line in the
  terminal's own hands and the shell lives.
- **Expansion without IFS.** `$var` expands to one word, always —
  there is no field splitting after expansion, no globbing. A bare
  run lexes as one part so `$` reaches its name; quotes resolve at
  lex time into literal and expandable parts.
- **Strict where it costs nothing, loose where the classics are.**
  Empty pipeline stages and dangling connectors refuse; a trailing
  `;` is fine; a redirection-only command (`> log`) runs; `&` refuses
  by name (background jobs are not here yet); a line does not open
  with `|`/`;`/`&&`/`||` but may open with `<`.
- **`projects/`, not `examples/`.** The shell is a program, not a
  demo; the projects tree joins the emo_project suite's dune deps and
  the fixtures run from the project's own directory, each pinning its
  merged output and its exit status.

## The shape

- `shell.emo` — the `Shell`: status, running, the reader, the three
  raw writers. `exec.emo` — the session driver and the executor: the
  connector walk, the fork-and-wire path, `wait_status` with 128+sig.
  `lex.emo` — tokens with parts. `expand.emo` — `$`/tilde over parts.
  `parse.emo` — items (pipeline + connector). `builtin.emo` — the
  eight. `main.emo` — the entry, leaving through `_exit`.
- `fixtures/*.esh` — six scripts, six `.expected` files, six `.exit`
  files; one Alcotest case builds both targets and walks them.

## Found on the way, fixed in step

- A bare run lexing byte-by-byte put `$` and its name in different
  parts and the expansion never saw the variable — the bare run now
  accumulates as one part, quotes closing it.
- A line's first token being an operator refused `> log` too — the
  refusal narrowed to the four connectors.
- The first `pwd` golden pinned the sandbox's cwd — fixtures now
  prove `cd`/`pwd` against constant directories only.

## The honest limits (the guide states them)

No control flow (`if`/`while`/functions), no globs, no background
jobs (`&` refuses by name), no line editor (the terminal's cooked
mode reads; history waits for the raw-mode milestone), no IFS
re-splitting, no `${var:-default}` forms, no traps, no subshell
parens, no here-docs. The os half of each is already in place; the
shell grows into them.
