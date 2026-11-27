# Step 92 — emosh's everyday surface

**Milestone:** M44 · **Prereq:** step 63 (the shell, its fixtures,
its docs) · **Status:** landed 2026-11-22 (code, fixtures, docs; both
targets built and the nine fixtures byte-identical by hand-run)

## Why this step exists

emosh v0 could run a line, but not a script by name — the only way
in was stdin redirection, and with no positional parameters there was
nothing for a script's arguments to be. The everyday shapes a shell
gets asked for first were all outside the v0 contract: `./emosh
script.esh args`, `./emosh -c 'line'`, `$1`, `${var:-default}`,
`2> err.txt`, `cmd > f 2>&1`, `echo *.emo`. This step lands them on
the `os`+`bufio` face emosh already rides — no stdlib work at all —
and fixes the three latent defects the survey of the v0 code turned
up before they could bite.

## Decisions settled here (the trail)

- **Three openings, one session.** Bare, a script file, or `-c` —
  the `Shell` gains the positional list, the reader's descriptor, and
  (for `-c`) the line itself; every field set in `init`, per the
  fields-are-init-only rule. A script's session is never interactive;
  its unopenable file reports the os reason and leaves 127 (the
  POSIX answer); `-c` without a command and an unknown option refuse
  with 2; only `argv[1]` is read as an option, `-` included — a
  strict refusal beats guessing stdin.
- **A `$` form the rules cannot name stays literal — the whole
  form.** `${1x}` runs as the text `${1x}`; the v0 behavior (silent
  `getenv`, answering empty) hid the mistyping. The same scan now
  finds the closing `}` from the form's own position, so `a}b${SETV}c`
  expands instead of computing a negative substring length — the
  latent bug, found by reading, fixed with the rule.
- **`${var:-word}` is the only new braced form.** Unset **or empty**
  answers the word; the word expands (one more `dollars` pass), the
  braces do not nest — the first `}` ends the form, the guide says
  so. `${var-word}` without the colon stays literal: one form, not
  two near-identical ones.
- **Quoting is remembered as a flag.** The v0 lexer resolved quotes
  and forgot them, which meant `"~"` expanded to `$HOME` — a v0 bug
  found the moment the glob needed the same distinction (a quoted `*`
  must stay a star). `Part` gains `quoted`; the tilde rule reads it;
  the words fixture pins the literal `~`.
- **The glob reads where every character came from.** Only bare,
  unquoted, unescaped `*`/`?` can glob; an expansion that produced a
  star stays literal, so `$x` never surprises. The pattern walks path
  segments (`src/*.emo`), a dead branch dropping silently, the last
  segment matching files as readily as directories (the literal
  existence probe is an open, not a list — a file is a match). The
  matches sort, so both targets answer the same bytes. No match
  refuses the command with status 1 — passing the pattern as a
  literal argument would hide the miss.
- **The `2` counts only when the whole bare word is the digit.**
  `echo hi 2> log` captures stderr; `echo hi2> log` passes `hi2` to
  `echo` and redirects stdout — the classic reading, one condition:
  the pending bare run is exactly `"2"` and nothing came before it in
  the word. `2>&1` lexes whole (no file follows), and a `2>&` that is
  not `2>&1` refuses by name instead of wandering into a stray `&`.
- **The order is the meaning.** Redirections apply in order, so
  `> f 2>&1` lands both descriptors in `f` and `2>&1 > f` leaves
  stderr where stdout was — no special case, the classic semantics
  falling out of the list walk.
- **One expansion, not two.** The single command's words expanded in
  the parent and again in the fork child; the child now receives the
  expanded argv. A pipeline stage still expands in its own child —
  the status a stage's words see is the one its fork inherited, the
  v0 behavior the pipes fixture already pins.
- **Glob refusal is a status-1 value, not a syntax error.** It is an
  expansion outcome, sibling to a failed open (1), not a malformed
  line (2). In a pipeline child it prints and `_exit(1)`s, the
  pipeline's status carrying it.

## The shape

- `expand.emo` — `Part.quoted`, the positional forms, the braced
  forms (`is_name`/`is_digits`/`digits_value`/`positional`/`braced`),
  the fixed `${` scan.
- `glob.emo` (new) — `patterned` reads the parts, `matches` walks the
  segments, `walk_level` lists or probes, `match_segment` the
  iterative `*`/`?` walk with the star remembered for the backtrack.
- `lex.emo` — the `quoted` flag at every `Part.new` site, the
  `2>`/`2>>`/`2>&1` tokens, the digit-word condition.
- `parse.emo` — `Redir` gains `fd` and `dup`, `redirect_fd` maps the
  operator to its descriptor, the grammar line grows the `2>` family.
- `exec.emo` — `start` reads the command line (the three openings,
  the refusals, `_exit` on a broken invocation), `main_entry` runs
  the one-shot line, `expand_words` is the one expansion (words +
  glob), `run_simple` hands the expanded argv down, `apply_redirs`
  rides `fd`/`dup`.
- `shell.emo` — `args`, `one_shot`, `command`, the reader over the
  session's descriptor.
- `fixtures/` — `globs.esh`, `defaults.esh`, `redirs2.esh` join;
  `words.esh` pins the quoted tilde and the empty positionals. The
  harness's emosh case also pins `-c` with name and positionals, the
  two refusals, a script run, and a missing script — both targets,
  byte for byte.

## Found on the way, fixed in step

- `"${" + body + "}"` — the string literal `"${"` opened an Emo
  interpolation and the literal form printed as ` + body + `; the
  pieces assemble now (`"$" + "{" + body + "}"`), the comment saying
  why.
- The glob's literal **last** segment probed with `list_dir`, which
  only directories survive — `dir/*/deep.emo` dropped every file
  match; the last segment probes with an open instead.
- The quoted tilde (above) — the v0 lexer's forgetting was already a
  bug before the glob needed the flag.

## The honest limits (the guide states them)

No control flow, no background jobs, no line editor, no IFS
re-splitting, no `~user`, no `shift`/`$#`/`$@`, no `<&`/`>&` and no
fd numbers beyond the `2>` family, no subshell parens, no here-docs,
no traps, no aliases. The os half of each (process groups, `WNOHANG`,
the stat family) is already in place; the shell grows into them.
