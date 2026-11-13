# Step 79 — The repl's line editor (linenoise)

**Milestone:** M40 · **Prereq:** step 08 (the repl itself) · **Status:** done

The repl's input seam (`repl_loop ~input ~output`) has always been
injectable — the tests drive it with queued lines and no terminal at
all. This step gives the interactive seat a real editor: the vendored
upstream linenoise reads a line with arrow-key history recall, edits
long input across wrapped display lines (multi-line mode), persists
the history to a state file across sessions, and indents the
continuation prompt by the depth of the open brackets. The seam's
shape absorbs the change: the input function now receives the prompt
text (the editor renders it itself), and its answer distinguishes a
completed line from Ctrl-C's abandonment and the input's end.

## Decided now

**The editor is vendored, not fetched.** Upstream linenoise
(`antirez/linenoise`, BSD-2) rides in the repository at
`src/emo_cli/linenoise.c` / `linenoise.h`, pinned at upstream commit
`a473823d74b93eab2ba83480df16ed37617493f2` (2026-05-01, "Add bracketed
paste folding"), compiled into the CLI through dune's
`foreign_stubs` — the first C the OCaml CLI itself links. Local
patches ride the vendor, marked `emo:` in place: the edit session's
temporary history entry is popped on the Ctrl-C and end-of-input
exits exactly as ENTER pops it — upstream leaks one empty entry into
the history per Ctrl-C — and end-of-input sets `ENOENT`; and the
blocking read's verdict errno is captured before the stop's cleanup
and restored after, because that cleanup probes the terminal
(`isatty`, `tcsetattr`) and would clobber the verdict the binding
maps onto its variants.

**The gate is the tty, both ways.** The editor takes the seat only
when stdin *and* stdout are ttys (the refresh needs both); everything
else — pipes, redirected files, the tests — keeps today's plain
`read_line` path byte for byte. linenoise's own degradation (the
unsupported-terminal list, non-tty stdin) sits below the gate and is
never reached by it.

**History rides per line.** Every non-empty line as typed joins the
history (upstream dedups against the entry before it), up to 1000
entries, saved once at the session's end. The file is
`repl-history` under the state directory — `EMO_STATE_DIR` overrides,
else `XDG_STATE_HOME/emo`, else `$HOME/.local/state/emo`; with no
`HOME` there is no history file and the session still edits. A
history the file system will not carry (unreadable on load, unwritable
on save) is one warning on stderr naming the path and the reason — the
session continues — while a missing file is a first session's normal
shape and says nothing. Upstream stores the file 0600 and encodes
embedded newlines; entries are lines, so none occur.

**Ctrl-C abandons, it does not kill.** linenoise consumes Ctrl-C in
raw mode and reports it; the repl answers by discarding the pending
input and rendering a fresh prompt — the Python semantics — where
today's cooked-mode Ctrl-C killed the process. Ctrl-D on an empty
line ends the session as today's EOF does.

**The continuation prompt indents by bracket depth.** The
`unbalanced` check already lexes the pending source for open
brackets; the same count now sizes the continuation prompt —
`... ` plus two spaces per open `{`/`(`/`[` — so the prompt shows
where the block stands. An unlexable pending source (an unterminated
string) keeps the plain dots; the indent is visual guidance, not a
cursor the editor places.

**The seam owns its bytes.** `repl_loop` passes the prompt text to the
input function and renders nothing itself when the editor reads; the
plain path prints as it always did (prompt, then EOF's newline). The
editor's end-of-line and Ctrl-C newlines come from linenoise's own
stop sequence.

## Scope

### In

- The vendored linenoise (C sources, the one patch), the C stubs, the
  `emo_linenoise` binding module, the dune wiring.
- The `repl_loop` seam change (`string -> answer`), the bracket-depth
  refactor of `unbalanced`, the continuation prompt, the editor
  session (load, per-line add, save, warnings).
- Tests: the seam updated, the depth/indent unit, and an editor smoke
  riding upstream's `LINENOISE_ASSUME_TTY` hook — a pipe carries the
  keystrokes (Enter as CR, an up-arrow recall, Ctrl-C) so the real C
  editor runs under `dune test` with no terminal.
- Docs: the repl section in `docs/toolchain.md` (EN + zh); TASKS
  M40/step-79; `plan/README.md`; CHECK.md.

### Out

- TAB completion — the completion callback rides the binding for free,
  but what completes (keywords, the session's names, required
  packages) is a design of its own; a later step.
- The `emosh` shell's editing — the shell is an Emo program reading
  through `bufio`; a different surface entirely.
- History at block granularity, hints, mask mode — per-line is the
  decided shape; the rest have no ask.

## Tasks

- [x] **T79.1** — The vendored editor: `linenoise.c`/`linenoise.h` at
      upstream `a473823d74b93eab2ba83480df16ed37617493f2` (2026-05-01)
      with the two marked patches — the edit session's temporary
      history entry pops on the Ctrl-C and end-of-input exits exactly
      as ENTER pops it, end-of-input answers `ENOENT` (upstream leaks
      one empty entry per Ctrl-C into the history otherwise), and the
      blocking read's verdict errno is captured before the stop's
      cleanup and restored after (that cleanup probes the terminal and
      would clobber the verdict). The C stubs and the `emo_linenoise`
      binding module — the stubs follow OCaml's mixed-variant
      encoding, constants and payload constructors numbered
      independently; dune's `foreign_stubs`.
- [x] **T79.2** — The seam: the prompt text passes to the input
      function, the answer gains `Aborted` and `Eof`, `unbalanced`
      shares its depth with the continuation prompt, and the editor
      session loads, adds, and saves the history with its warnings.
- [x] **T79.3** — The tests: the repl suite on the new seam, the
      depth/indent units, the history-path resolution, and the
      `LINENOISE_ASSUME_TTY` editor smoke — typed lines, the up-arrow
      recall, the interrupt that leaks no empty history entry, the
      input's end, and a two-session persistence round-trip through
      the state file; the live pty run on a real terminal verified the
      indented continuation prompts, the Ctrl-C abandon, and the
      cross-process recall.
- [x] **T79.4** — The docs: the repl section in the toolchain guide
      (EN + zh), TASKS M40/step-79, plan/README's step row, CHECK.md's
      decision record.

## Acceptance

- Interactive: up/down recall across sessions persists through the
  state file; Ctrl-C abandons the pending input and survives; long
  lines wrap and edit; the continuation prompt indents with the open
  brackets.
- Piped and redirected: the plain path's bytes are unchanged.
- `dune runtest` green, `@fmt` clean.
