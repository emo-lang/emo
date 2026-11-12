# The `emosh` Shell Guide

`emosh` is the general-purpose command interpreter written in Emo, in
`projects/emo-shell` — a program, not a package. It reads lines, cuts
them into words and operators, expands the environment, and runs
pipelines of forked children wired through `dup2`: the shape the
classic shells have, in one language from prompt to exec, riding the
standard library's own `os` surface (`fork`, `execvp`, `waitpid`,
`pipe`, `dup2`, the environment, the signals) plus `bufio` for the
line reader.

This guide covers the v0 surface. Everything it states is what the
shell does; everything it does not state, the shell does not do — the
limits section at the bottom is the honest list.

## Building and running

```console
$ cd projects/emo-shell
$ emo build main.emo --target c -o emosh
$ ./emosh                (interactive)
$ ./emosh < script.esh   (a script on stdin)
```

The mode is decided by what fd 0 is: a terminal gets the `emosh> `
prompt, anything else is a script read line by line with no prompt.
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
redirection := "<" | ">" | ">>" word
```

## Words and quoting

A word is the pieces a line was cut into, and quoting is resolved at
lex time, not remembered:

- bare text is expandable — `$var`, `$?`, and a leading `~` grow here;
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
- `$?` — the last command's exit status.
- `$0` — the name the shell was started with.
- `~` at the start of an unquoted word — `$HOME`; unset leaves the
  tilde as it is (`~user` is not a form here).

**There is no word splitting after expansion.** One expanded word is
one argument, always — a variable holding spaces passes them intact,
and the guide's honest trade for that is no field splitting at all.
There is no globbing either.

## Redirections and pipelines

`<` reads a command's stdin from a file, `>` writes its stdout to a
file (create or truncate), `>>` appends — each opening the file just
before the command runs, in the fork child. A command of redirections
alone is a command: `> log` truncates `log`.

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

The v0 contract, stated so you never have to guess:

- no control flow — no `if`, `while`, `for`, no functions;
- no globbing, no `~user`, no `${var:-default}` forms, no `$1`
  positional parameters;
- no background jobs — `&` refuses by name;
- no line editor — the terminal's own cooked mode reads; no history,
  no completion;
- no IFS field splitting after expansion;
- no subshell parentheses, no here-docs, no traps, no aliases.

The os surface under each of these (process groups, `WNOHANG`, the
stat family) is where the work goes when a milestone names them.

## The standard library connection

`emosh` is the worked example of the `os` package's full surface —
the fork discipline, `dup2`, `execvp`, the environment, the signals —
and of `bufio`'s line reading. `docs/stdlib/os.md` is the reference
for every call the shell makes.
