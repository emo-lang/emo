# The `emosh` Shell Guide

`emosh` is the general-purpose command interpreter written in Emo, in
`projects/emo-shell` — a program, not a package. It reads lines, cuts
them into words and operators, expands the environment, and runs
pipelines of forked children wired through `dup2`: the shape the
classic shells have, in one language from prompt to exec, riding the
standard library's own `os` surface (`fork`, `execvp`, `waitpid`,
`pipe`, `dup2`, the environment, the signals) plus `bufio` for the
line reader.

This guide covers the surface the milestones have landed. Everything
it states is what the shell does; everything it does not state, the
shell does not do — the limits section at the bottom is the honest
list.

## Building and running

```console
$ cd projects/emo-shell
$ emo build main.emo --target c -o emosh
$ ./emosh                    (interactive on a terminal)
$ ./emosh < script.esh       (a script on stdin)
$ ./emosh script.esh args    (a script file; args are $1, $2, …)
$ ./emosh -c "echo hi $1"    (one line, its status the shell's)
```

Bare, the mode is decided by what fd 0 is: a terminal gets the
`emosh> ` prompt, anything else is a script read line by line with no
prompt. With a script file the lines come from the file, the session
is never interactive, and the file's arguments become the positional
parameters. `-c` runs the one line — connectors and all — and leaves
with its status; an optional word after the line stands as `$0` and
the rest are `$1`, `$2`, … (`emosh -c 'echo $0 $1' shell hello`).
`-c` without a command refuses with status 2, an unknown option
refuses with status 2, and a script file that cannot open reports the
os reason and leaves with 127.

The shell declares the `ocaml` and `c` targets — `emo run main.emo`
runs it under the interpreter, and the fixtures in `fixtures/` pin
the two targets' outputs byte for byte.

## One line's life

A line goes lex → parse → expand → execute, in that order, and a
malformed line never kills the shell (there is no catch in the
language, and no raise in the shell): the reason prints to stderr and
the status becomes 2.

```
line     := and_or ( ";" and_or )* ";"?
and_or   := pipeline ( "&&" | "||" pipeline )*
pipeline := command ( "|" command )*
command  := ( word | redirection )*
redirection := "<" | ">" | ">>" word | "2>" | "2>>" word | "2>&1"
```

## Words and quoting

A word is the pieces a line was cut into; quoting is resolved at lex
time and remembered as a flag, because two rules later care where a
character came from — a quoted `~` stays a tilde and a quoted `*`
stays a star:

- bare text is expandable — `$var`, `$?`, a leading `~`, and the glob
  characters grow here;
- `'single quotes'` are literal, byte for byte — nothing expands,
  no escape works, a `'` cannot appear inside;
- `"double quotes"` are expandable — `$var` grows, and `\$` `\"`
  `` \` `` `\\` escape themselves; any other backslash stays;
- a backslash outside quotes escapes the next byte into a literal;
- `#` at the start of a word comments to the end of the line;
- an empty quoted string still makes a word (`touch ''` touches).

```console
$ export NAME=world
$ echo $NAME
world
$ echo 'single $NAME stays'
single $NAME stays
$ echo "double $NAME expands"
double world expands
$ echo \$NAME-literal
$NAME-literal
```

## Expansion

- `$var` / `${var}` — the variable's value; unset answers empty.
- `${var:-word}` — the value when set and not empty, `word` otherwise
  (the word expands too; nested braces do not — the first `}` ends
  the form).
- `$?` — the last command's exit status.
- `$0` — the name the shell was started with: the program's name
  bare, the script's path with a script file, the word after the line
  with `-c` when one is given.
- `$1` … `$9` and `${N}` — the positional parameters: a script file's
  arguments or `-c`'s, empty past the last one.
- `~` at the start of a bare, unquoted word — `$HOME`; unset leaves
  the tilde as it is (`~user` is not a form here, and a quoted tilde
  stays a tilde).

A `$` form the rules cannot name stays literal — the whole form, not
just the dollar: `${1x}` runs as the text `${1x}`. The same honesty
applies when a `}` the word carried earlier sits before the form:
`${SETV}` in `a}b${SETV}c` still expands.

**There is no word splitting after expansion.** One expanded word is
one argument, always — a variable holding spaces passes them intact,
and the guide's honest trade for that is no field splitting at all.
Expansion results never glob either — the section below tells what
does.

## The glob

A `*` (any run of characters) or `?` (exactly one) typed **bare, out
of every quote**, turns a word into the names it matches, sorted:

```console
$ cd projects/emo-shell/fixtures && echo *.esh
defaults.esh errors.esh flow.esh globs.esh pipes.esh redirs2.esh redirs.esh words.esh
```

The rules, stated so nothing surprises:

- quoted text never globs — `echo "*.emo"` prints `*.emo`, and an
  expansion that produced a `*` stays literal; the glob reads where
  every character came from;
- the pattern walks path segments: `src/*.emo` lists `src` and keeps
  the matches; a directory that fails to list drops out silently, and
  the last segment matches files as readily as directories;
- a segment's leading `.` matches the hidden names; without it they
  stay hidden, and `.` and `..` never appear;
- **no match refuses the command** — `emosh: no matches: *.zzz` with
  status 1 — because running it with the pattern as a literal
  argument would hide the miss;
- a redirection's target is one name and does not glob.

## Redirections and pipelines

`<` reads a command's stdin from a file, `>` writes its stdout to a
file (create or truncate), `>>` appends, `2>` and `2>>` aim stderr at
a file the same way — each opening the file just before the command
runs, in the fork child. A `2` that a `>` follows redirects stderr
only when the whole bare word is the digit: `echo hi 2> log` captures
the errors, `echo hi2> log` passes `hi2` to `echo` and redirects
stdout, the classic reading. `2>&1` makes stderr follow wherever
stdout is already aimed, and the order is the meaning:
`cmd > f 2>&1` lands both in `f`, `cmd 2>&1 > f` leaves stderr where
stdout was. A command of redirections alone is a command: `> log`
truncates `log`, `2> log` empties it just the same.

A pipeline forks one child per stage, wired through pipes: `a | b`
runs `a` with its stdout on the pipe and `b` with its stdin on the
pipe. The pipeline's exit status is the last stage's. A builtin found
in a pipeline runs in a fork child like everything else.

```console
$ printf 'b\na\nc\n' | sort
a
b
c
$ echo first > f.txt
$ echo second >> f.txt
$ cat < f.txt
first
second
$ nosuch-cmd 2> err.txt
$ cat err.txt
emosh: nosuch-cmd: command not found
```

## Connectors and status

`;` separates unconditionally, `&&` runs the next only on success,
`||` only on failure. A skipped item's status carries forward, so the
classics behave as expected:

```console
$ false && echo no || echo rescued
rescued
$ true
$ echo status=$?
0
$ false
$ echo status=$?
1
```

A signal death counts as `128 + signal`, the kernel's own encoding
decoded by `os.wait_signal`. `exit` takes an optional status (no
argument means the last one), folding through the kernel's low byte —
`exit 300` leaves 44, `exit -1` leaves 255 — and refusing a
non-numeric argument with status 2. A script's exit status is the
last command's; end of input in an interactive session leaves with
the last status too.

## The builtins

| Builtin | What it does |
|---|---|
| `cd [dir]` | change directory; no argument means `$HOME` |
| `pwd` | print the working directory |
| `echo args...` | the words joined with one space, one newline |
| `exit [n]` | leave the shell with status `n` |
| `export NAME=VALUE` | set into the environment; children inherit |
| `unset NAME` | remove from the environment |
| `true` | status 0 |
| `false` | status 1 |

`export` and `unset` change the real environment, so every command
the shell forks afterwards inherits them:

```console
$ export GREET=hi
$ printenv GREET
hi
$ unset GREET
$ printenv GREET
$ echo status=$?
1
```

`echo` has no flags — the words, verbatim, one newline. `cd` with a
directory that does not exist reports the os reason and leaves the
status at 1.

## Errors

The error lines carry the shell's name, then the command's — the
classic shape:

```console
$ no-such-command
emosh: no-such-command: command not found      (status 127)
$ echo x > /no/such/dir/f
emosh: os: open /no/such/dir/f: No such file or directory   (status 1)
$ echo dangling |
emosh: syntax error: unexpected end of line    (status 2)
$ echo stray &
emosh: syntax error: & is not supported yet    (status 2)
$ echo *.nope
emosh: no matches: *.nope                      (status 1)
$ ./emosh -z
emosh: unknown option: -z                      (status 2)
$ ./emosh ./no-such-script.esh
emosh: os: open ./no-such-script.esh: No such file or directory   (status 127)
```

An interactive session carries on after any of these; a script
carries on too — it stops only where you tell it to (`&&`, `exit`)
or where the input ends.

## Signals

The shell ignores `sig_pipe` in every mode (a write into a dead pipe
must not kill the interpreter), and `sig_int` and `sig_quit` in an
interactive session: Ctrl-C discards the current line — the
terminal's own line discipline flushes it — and the shell survives.
Every forked child restores the default dispositions before its exec,
so a foreground command dies to Ctrl-C the way it should.

In cooked mode there is no fresh prompt until the next line completes
after a Ctrl-C; the line editor (raw mode, history, completion) is
the next milestone's work, not this one's.

## The honest limits

The contract, stated so you never have to guess:

- no control flow — no `if`, `while`, `for`, no functions;
- the positionals end where they end: `$1` … `$9` and `${N}` only —
  no `shift`, no `$#`, no `$@`;
- no background jobs — `&` refuses by name;
- no line editor — the terminal's own cooked mode reads; no history,
  no completion;
- no IFS field splitting after expansion;
- no `~user`, no nested `${…}` forms, no `${var-word}` without the
  colon;
- no subshell parentheses, no here-docs, no traps, no aliases;
- a `2>&` that is not `2>&1` refuses; there is no `<&`, no `>&`,
  no fd numbers beyond the `2>` family.

The os surface under each of these (process groups, `WNOHANG`, the
stat family) is where the work goes when a milestone names them.

## The standard library connection

`emosh` is the worked example of the `os` package's full surface —
the fork discipline, `dup2`, `execvp`, the environment, the signals —
and of `bufio`'s line reading. `docs/stdlib/os.md` is the reference
for every call the shell makes.
