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
$ ./emosh - < script.esh     (the explicit dash: the same, by name)
$ ./emosh script.esh args    (a script file; args are $1, $2, …)
$ ./emosh -c "echo hi $1"    (one line, its status the shell's)
```

Bare, the mode is decided by what fd 0 and fd 2 are: both on a
terminal gets the `emosh> ` prompt — which rides **stderr**, so a
redirected stdout stays clean no matter what the session is. Anything
else is a script read line by line with no prompt. With a script file
the lines come from the file, the session is never interactive, and
the file's arguments become the positional parameters; `-` says the
same thing about stdin by name. `-c` runs the one line — connectors
and all — and leaves with its status; an optional word after the line
stands as `$0` and the rest are `$1`, `$2`, …
(`emosh -c 'echo $0 $1' shell hello`). `-c` without a command refuses
with status 2, an unknown option refuses with status 2, and a script
file that cannot open reports the os reason and leaves with 127.

The shell declares the `ocaml` and `c` targets — `emo run main.emo`
runs it under the interpreter (the words after the file ride in as
the program's `os.argv`, so the shell parses them as its own), and
the fixtures in `fixtures/` pin the two targets' outputs byte for
byte.

## One line's life

A line goes lex → parse → expand → execute, in that order, and a
malformed line never kills the shell (there is no catch in the
language, and no raise in the shell): the reason prints to stderr and
the status becomes 2.

```
line     := item ( ";" item )* ";"?        (a trailing `;` is fine)
and_or   := item ( "&&" | "||" item )*
item     := pipeline | compound | declaration
pipeline := command ( "|" command )*
command  := ( word | redirection )*
redirection := "<" | ">" | ">>" word | "N<" | "N>" | "N>>" word
             | "N>&M" | "N<&M" | ">&M" | "<&M"
compound := "if" list "{" list "}" [ "else" ( if | "{" list "}" ) ]
          | "while" list "{" list "}"
          | "for" "var" name "=" expr ";" expr ";" expr "{" list "}"
          | "def" name "(" ")" "{" list "}"
declaration := ("const" | "var") name "=" word
```

A `&` after an item sends it to the background — `a | b &` is one
job, `while … } &` too, the section below. The control flow speaks
Emo: brace blocks, no `then`/`fi`/`do`/`done` terminators. The
keywords (`if`, `while`, `for`, `def`, `const`, `var`) are recognized
where a command may start and only on a bare, unquoted word; `{` and
`}` are reserved as standalone words — a literal brace quotes.

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
- a backslash outside quotes escapes the next byte into a literal —
  and a **bare trailing backslash continues the line**, `> `
  prompting for the next one interactively (a double quote left open
  by a trailing backslash reaches the next line the same way; an
  unterminated single quote still refuses);
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
- `$#` — how many positionals there are.
- `$@` — the positionals as words of their own, vanishing when there
  are none — but only when the form owns the whole word (`"$@"` or
  bare `$@`); mixed into other text (`x$@`) it stays literal, the
  strictness rule keeping one expanded word one argument.
- `$$` — the shell's own process id.
- `$!` — the last background job's pid; the empty string until there
  is one.
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
file (create or truncate), `>>` appends — and every descriptor has
the same rights: `N<` / `N>` / `N>>` aim descriptor `N` at a file
(`2>` their everyday face), `N>&M` / `N<&M` aim descriptor `N` where
`M` already points, `>&M` and `<&M` saying stdout and stdin without
the number (`>&2` the classic "out to stderr"). Each opens just
before the command runs, in the fork child. A digit counts as a
descriptor only when the whole bare word is the digit:
`echo hi 2> log` captures the errors, `echo hi2> log` passes `hi2`
to `echo` and redirects stdout, the classic reading. The order is
the meaning: `cmd > f 2>&1` lands both in `f`, `cmd 2>&1 > f` leaves
stderr where stdout was. A command of redirections alone is a
command: `> log` truncates `log`, `2> log` empties it just the same.

A pipeline forks one child per stage, wired through pipes: `a | b`
runs `a` with its stdout on the pipe and `b` with its stdin on the
pipe. The pipeline's exit status is the last stage's. A builtin found
in a pipeline runs in a fork child like everything else — `exit`
inside one ends that child, not the session, the classic reading.

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

## Control flow and declarations

The flow shapes are Emo's own — brace blocks, the numeric `for`, the
declaration keywords — running shell command lists where Emo runs its
statements:

```console
$ var who = "shell"
$ const greeting = "hello"
$ echo $greeting $who
hello shell
```

- `const NAME = WORD` binds a variable; redeclaring a frozen name —
  by `const`, `var`, or `unset` — refuses (`NAME: is a constant`).
  `var NAME = WORD` binds too; a later `var` replaces the value. The
  value reads two ways: quoted parts bind their expanded text joined
  into one word (`$x` grows; globs stay put: a declaration's value
  does not glob), and a bare run evaluates as an integer expression
  (`var acc = acc + i`). `$NAME` reads a declared binding before the
  environment, and `unset` removes both.
- `NAME = EXPR` reassigns a declared binding — `n = n - 1` inside a
  loop, `acc = acc + i` in a `for` body. The value reads the
  declaration's own two ways. An undeclared name refuses
  (`NAME: is not declared` — `var` and `const` are the only doors a
  binding opens through), and a frozen one refuses its reassignment
  (`NAME: is a constant`).
- A run of bare words and comparisons at a command position is the
  expression statement when its head names a declared binding,
  opens with digits, or is an open parenthesis — the shell's own
  reading of the Emo repl: `s + 1` after `var s = 0` prints `1`,
  `2 * 3` prints `6`, `( 2 + 3 ) * 2` prints `10`, comparisons
  answer 1 or 0; integer literals and bound values read with an
  optional leading minus (`-5`, a counter sinking past zero). A lone
  name answers the value it binds, string or
  number alike — `c` after `const c = "foo"` prints foo; only a
  longer run demands numbers. A builtin's or a function's name keeps
  its command (`echo hi` never evaluates), and quoting the head
  forces the command reading (`'git' status`); the comparison operators ride
  ordinary commands as plain words (`grep == hi` runs grep, `echo a
  == b` prints). The session's own names outrank the PATH's
  commands, and a pipeline stage can be the value's producer
  (`g | tr a-z A-Z`).
- `if LIST { LIST } else { LIST }` and
  `while LIST { LIST }` — the condition has two shapes. A **command
  list**: its last command's exit status chooses (0 continues).
  A **numeric comparison**: `if s > 5 { … }`,
  `if s == 3 && s < 10 { … }` — when every token in the condition is
  a bare word or comparison/boolean operator and a comparison is
  present, it evaluates as an integer expression over the declared
  bindings and the environment (`$i` forms read for their values
  too). No `else` and a false condition answers 0; `else` may chain
  `else if … { … }`, flattened into nesting.
- `for var I = EXPR; I < EXPR; I = I + EXPR { LIST }` — the numeric
  for, Emo's own shape: the header's three expressions are integer
  arithmetic over bare variable names (`$#` counts in too), the loop
  variable a declared binding set each round and restored after, the
  step an assignment `I = I + EXPR` the way the header says.

`break` and `continue` leave or step a loop; `return [n]` leaves a
function — each refusing where it does not belong (`break: only in a
loop`, `return: only in a function`).

```console
$ def greet() {
  echo greet:$1
}
$ greet world
greet:world
$ for var i = 1; i <= 3; i = i + 1 {
  echo tick $i
}
tick 1
tick 2
tick 3
$ var n = 2
$ while n > 0 {
  echo n=$n
  n = n - 1
}
n=2
n=1
$ echo final=$n
0
```

A block may open on one line and close lines later — the shell asks
for the next line with `>` until the braces balance, exactly the way
a trailing backslash works. Declarations and functions defined inside
a body are the session's own (there are no locals), and a `for`'s
variable is restored after the loop, whatever it was before.

## Background jobs

A `&` after a pipeline runs it in the background: `sleep 5 &` spawns
the job and moves on — the spawn's success is that item's status, and
the spawn itself is the separator (`a & b` runs `b` right away). The
job takes the smallest free number, and `$!` answers its pid.

The shell polls its jobs before every prompt; a job that finished
gets its line — `[1] done sleep 5`, the status riding after `done`
when it is not zero — and leaves the table. A background job runs in
a process group of its own, so the terminal's Ctrl-C, aimed at the
shell's group, can never reach it; a foreground command keeps the
classic discipline and dies to Ctrl-C the way it should.

| Builtin | What it does |
|---|---|
| `jobs` | one poll first, then the still-running jobs: `[1] 4821 running sleep 5` |
| `fg %n` | park on the job's whole pipeline; its status the answer |
| `bg %n` | nothing here ever stops — `emosh: bg: job 1 already in background` |
| `wait [%n]` | park on that job, or on all of them; an unknown job is 127 |
| `kill [-N] target...` | signal pids, or whole job groups with `%n` (15 the default) |

The honest edges, stated: `fg` waits — without a terminal-handoff
call the job keeps its own process group, so a Ctrl-C cannot reach a
job brought back this way; a background job's stdin stays the shell's
(there is no `/dev/null` redirection — two jobs racing to read is
the user's to avoid); and the shell exits leaving running jobs
behind, the way a script's shell does.

```console
$ sleep 5 &
$ jobs
[1] 4821 running sleep 5
$ kill %1
$ echo status=$?
0
```

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
emosh: no-such-command: command not found   (status 127)
$ ./nonexec-script
emosh: ./nonexec-script: os: execvp: Permission denied   (status 126)
$ echo x > /no/such/dir/f
emosh: os: open /no/such/dir/f: No such file or directory   (status 1)
$ echo dangling |
emosh: syntax error: unexpected end of line    (status 2)
$ echo stray 2>&x
emosh: syntax error: bad descriptor redirection    (status 2)
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

- no `case`, no `until`, no `select`, no `[[`, no arithmetic
  parentheses outside the for header;
- no compound commands in pipelines (`if … } | cat` refuses) and no
  word-list iteration (`for x in words` — the for is the numeric
  form); a function call takes no redirections;
- the positionals end where they end: `$1` … `$9`, `${N}`, `$#` and
  `$@` only — no `shift`, no `$*`; a declaration's or assignment's
  value is one word;
- background jobs exist but the terminal does not negotiate: `fg`
  waits, and a Ctrl-C cannot reach a job it brought back (the
  terminal-handoff call — `tcsetpgrp` — is the os half waiting to
  land); nothing here stops a job, so `bg` always answers
  `already in background`; a background job's stdin stays the
  shell's;
- no line editor — the terminal's own cooked mode reads; no history,
  no completion;
- no IFS field splitting after expansion;
- no `~user`, no nested `${…}` forms, no `${var-word}` without the
  colon;
- no subshell parentheses, no here-docs, no traps, no aliases;
- the dup forms aim a descriptor where another points — they do not
  close (`N>&-` refuses), and `<>` (read-write) is not a form.

The os surface under each of these (process groups, `WNOHANG`, the
stat family) is where the work goes when a milestone names them.

## The standard library connection

`emosh` is the worked example of the `os` package's full surface —
the fork discipline, `dup2`, `execvp`, the environment, the signals —
and of `bufio`'s line reading. `docs/stdlib/os.md` is the reference
for every call the shell makes.
