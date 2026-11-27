# Step 95 — emosh's line editor

**Milestone:** M44 · **Prereq:** steps 92–94 (the everyday surface, the
background jobs, the control flow) · **Status:** landed 2026-11-23
(code, fixtures, docs; the eleven fixtures byte-identical on both
targets, the editor's key suite pty-driven by hand on both, the
os_demo tty legs byte-identical across the three hosts)

## Why this step exists

The guide named the line editor the next milestone since the control
flow landed: a shell without one reads through the terminal's own
cooked line discipline — no recall, no editing, no completion. The
CLI's repl editor (step 79) rode vendored linenoise behind dune's
foreign_stubs; that road is closed to an Emo program, so emosh's
editor is written in Emo over an os terminal tier grown for it, and
the user's three calls set the scope: history persists across
sessions like the repl's, completion covers commands and files, and
blocks edit one line at a time.

## Decisions settled here (the trail)

- **The os owns raw mode, not the flags.** `tty_raw(fd)` answers the
  state that was there as opaque words, `tty_restore` hands them
  back; `cfmakeraw` is the portable door because the flag bits
  themselves differ between macOS and Linux (`IEXTEN` `0x100000` vs
  `0x200`) — a get/setattr pair of flag words would be wrong on one
  platform by construction. Each runtime's blob answers only to
  itself (packed one int per eight bytes of the kernel's struct),
  `TCSADRAIN` the set, ENOTTY the byte-identical refusal on a pipe.
- **The editor is a module, the session drives the discipline.** Raw
  around every read, restored before anything runs — children keep
  the classic cooked terminal, Ctrl-C in raw mode (ISIG off) is a
  byte the editor reads: the half-typed line is abandoned and the
  prompt asks again fresh, while a running command dies to Ctrl-C as
  always.
- **Bytes, not escapes.** The string escape table has no byte-literal
  form, so the editor builds its ESC with `Bytes.new(1).set(0, 27)
  .to_string()` and reads with `to_bytes().get(i)`. The cursor only
  ever stands on a UTF-8 character boundary — every move and edit
  walks the continuation bytes — so multi-byte characters insert,
  erase, and step whole; column math counts the East-Asian-Wide
  ranges as two columns.
- **Three outcomes.** Accepted (an empty line is accepted too), end
  of input (Ctrl-D on an empty line, or the read's own EOF), and
  abandoned (Ctrl-C) — the driver folds them so abandon and an empty
  line both land back at a fresh prompt while only end-of-input ends
  the session.
- **Completion asks the session's names.** The word under the cursor
  completes to every candidate's common prefix; a second Tab lists
  them. The first word rides the command vocabulary — the builtins'
  roster, the session's functions (refreshed into the editor's box
  before every read, keeping edit out of the session's dependency
  lane), then every command the PATH serves — a later word rides the
  working directory's files. Quoting defeats completion as it defeats
  keywords.
- **`EMOSH_ASSUME_TTY` skips the raw pair only.** The keys and the
  rendering run over a pipe exactly as on a terminal — the hook the
  goldens drive, the repl's `LINENOISE_ASSUME_TTY` precedent. The
  editor engages on `isatty(0) && isatty(2)` or the hook alone, so
  the eleven fixtures stay byte-identical.
- **History is the repl's, in Emo.** The last 1000 lines ride
  `emosh-history` under `EMO_STATE_DIR`, else `$XDG_STATE_HOME/emo`,
  else `$HOME/.local/state/emo` — loaded at the session's start,
  written once at its end; a concurrent save wins the file, a hard
  kill loses what came after.

## The shape

- `stdlib/registry/os/0.1.0/os.emo` — `tty_raw`/`tty_restore`, the
  twelve landing points (both stub files, both runtimes' arms, the
  checker's empty_env, the c runtime + header + emitter, the wasm
  raise list, the os_demo golden, the docs, the eighteen locks).
- `projects/emo-shell/edit.emo` — bytes, UTF-8 walks, the key decode,
  the render, history browsing, completion, the history file.
- `exec.emo` — `read_prompted` (the raw/restore pair, the hook), the
  interactive loop's three outcomes, gather and drive_line's
  continuation reads through the editor.
- `shell.emo` — the history box + load/add, the function roster,
  `assume_tty`.

## Found on the way, fixed in step

- The probe discrimination lesson: every "completion is broken"
  reading came from the prefix `pw` — the PATH's passwd, pwdx and
  friends legitimately stop the common prefix at `pw`. The
  discriminating prefix (`ech` → `echo 42`) answered green in
  seconds. Debug probes must be able to distinguish the answers they
  claim to test.
- `assume_tty`'s first probe compared the getenv tuple against the
  bare `R.error` enum — always true, engaging the editor on pipes and
  smearing every fixture; the case arms tell the two shapes apart.
- The key verdicts' mapping to outcomes started one off (Ctrl-C
  answering "end of input", Ctrl-D "abandoned"); the verdicts became
  the outcomes' own numbering.
- The c emitter refuses a typed-array unbox (`Array[Int64]` out of
  the dynamic world) — the array arg rides `as_dyn`, the way execvp's
  argv always has.

## The honest limits (the guide states them)

One line at a time: a block's `>` continuation edits alone and ↑
recalls single lines, never whole blocks. A line longer than one
terminal row wraps and the single-line redraw smears. Completion's
PATH candidates arrive as the directories list them — no ranking, no
fuzzy matching.
