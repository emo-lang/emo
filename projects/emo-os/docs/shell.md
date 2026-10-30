# The shell — the REPL over the console and the filesystem

How EmoOS ends its boot: the REPL process that takes the machine's
foreground once the boot proof is done, the line it reads and the
commands it answers, and the boundaries it states. Fixed as of T7.3
(2026-10-31). Below it are the services the gate routes to — the
console service (T3.7/T4.4) and the filesystem service (T7.2, its
design in [`fs.md`](fs.md)); the verbs it speaks are
[`syscalls.md`](syscalls.md)'s.

Chinese translation: [`shell.zh-CN.md`](shell.zh-CN.md).

## What the shell is

The shell is a **user process** — the boot pass of the user image
itself. The boot proof (the gate line, the echo, the filesystem
roundtrip, the four killed passes, the spawn/wait round trip) is the
top level's preamble; when it ends, the top level calls the REPL loop
instead of exiting, and the machine stops ending by itself: the REPL
is the foreground, and the way off it is the `poweroff` command — the
boot pass's exit verb, the same route that ended the machine when the
proof was the whole program.

Everything the shell does crosses the gate: every byte it prints and
reads rides the write and read verbs through the console service, and
every file operation rides the filesystem verbs through the filesystem
service. The shell is ordinary typed Emo in U-mode on its own address
space, speaking the `syscall` package's stubs and nothing else — the
first resident of the machine that is neither kernel nor service, and
the standing demo that the user side of the system is the same
language as the supervisor underneath it.

The REPL allocates in the boot pass's arena, as every user pass does,
and no collector exists yet: the bound is the user heap (8 MiB), a few
dozen bytes per interaction, the same lifetime bound every user pass
lives under.

## The line

The console is raw bytes — no line discipline below the shell — so the
REPL builds the line itself, one byte at a time, each byte a blocking
read through the gate:

- **Printable ASCII (32–126)** joins the line and is echoed back —
  the terminal sees what it typed, because nothing else echoes.
- **Backspace (8) and DEL (127)** erase the line's last character,
  echoed as the three-byte sequence `\b \b`; on an empty line they do
  nothing.
- **CR (13) and LF (10)** both end the line, echoed as a single LF —
  the kernel's own console discipline (`println` writes a bare LF,
  and the shell's output follows it).
- **Every other byte is dropped**, silently and by name in this note:
  the shell does not guess what a control byte meant.
- **The line is bounded at 120 bytes.** Bytes past the bound are
  dropped *and not echoed* — the missing echo is the tell, the same
  strictness the gate's staging bound uses (reason 4 there, visible
  silence here).

The prompt is `emo> `, printed before each line is read.

## The commands

The line parses by one rule: leading spaces are skipped, the command
word ends at the first space (or the line's end), and what follows
after that one separating space is the argument — verbatim, spaces
included. Commands are lowercase and exact. Eight:

| Command | Argument | Effect | Output |
| --- | --- | --- | --- |
| `help` | none | — | one line naming the eight commands |
| `echo` | the text, verbatim | — | the text, then a newline; an empty argument is an empty line |
| `ls` | none | `file_list` | the names, one per line, as the service lists them; an empty volume lists nothing |
| `cat` | one name | `file_read` | the file's bytes, then a newline; the read's capacity is 2048, the write bound, so a whole file always fits |
| `write` | one name, then the text | `file_write` | the file named becomes the text's bytes (an absent text is an empty file); quiet on success |
| `rm` | one name | `file_remove` | the file is gone; quiet on success |
| `counter` | none | the machine's program: `spawn` + `wait` | the console renderer pass (T7.4) runs to its quit key, the frames its whole output; silence on success, the prompt's return saying it is done |
| `poweroff` | none | the boot pass's `exit` | the machine ends — the exit route's `dma` line and frames account, then the SBI poweroff |

The strictness is the platform's, carried to the surface:

- A command that takes no argument refuses one (`ls foo` is
  `ls: bad argument`) — nothing is silently ignored.
- A command that takes one name refuses a second, and refuses no name
  at all, with the same line.
- An unknown word answers `<word>: unknown command`.
- An empty line (or one of only spaces) answers nothing and re-prompts.

The file commands are quiet on success because silence is what the
Unix convention taught and the golden proves the effect through the
next command (`ls` sees what `write` wrote; `rm` is proven by the
`cat` that refuses after it). Every refusal the services answer comes
back as one line, `<command>: <message>`, with the message the
`syscall` package names — `no such file`, `bad argument`,
`the kernel is out of a resource`.

## The error messages

The stubs answer refusals as `(R.error, why)` with `why` a String, and
the riscv64 backend's String surface is equality only — the backend
refuses every String method by name. So the shell maps the message
back through string equality (the proof chain's `reason_num` shape)
and prints its own bytes: the four messages the file verbs can answer
are poked into the shell's scratch at REPL start, and anything outside
them prints as `refused`. The mapping is total over what the stubs
can say to a shell whose buffers are its own writable segment.

## The scratch

The shell keeps its own addresses in the user image's read-write
segment, above the proof chain's (the segment the loader zeroed and
the gate checks against — the ELF's RW segment runs megabytes past
these):

| Address (from the scratch base `0x87200000`) | Contents |
| --- | --- |
| `+6144` | the line, 128 bytes (the bound is 120) |
| `+6272` | the list's buffer, 256 bytes |
| `+6528` | the read's buffer, 2048 bytes |
| `+8576` … | the texts: the four refusal messages, `unknown command`, the help line, the prompt, the eight command names, `: `, a LF — poked once at REPL start from byte-array literals, the only texts the shell prints |

The texts ride byte-array literals because strings cannot: the
riscv64 backend carries no String-to-bytes path, and the array literal
read one element at a time into raw memory is the honest form. No
array-element assignment is involved (the target refuses it): the
array is read, the destination is raw memory.

## The bounds

- The command set is the eight above. Starting a program became one of
  them at T7.5, the decision the closure demo owed: `counter` starts
  the machine's one program — the console renderer pass — by the
  proof chain's own spawn discipline (the token cell poked, the child
  re-entering the top level, the exit answering the wait), because
  the spawn verb carries no arguments and the image is the one program
  the machine has. The command names what it runs; a second program,
  or a program loaded from the disk, reopens the name — a `run` with
  nothing honest to run would be a construct without its place.
- One volume, a flat namespace, whole files: the filesystem service's
  own bounds (T7.2). A name with a space in it is legal to the
  service and unreachable from the shell — the space is the
  separator.
- No flags, no paths, no environment, no job control: the console is
  the whole world and the line is the whole input.
- The REPL is the boot pass, and its exit is the machine's end: there
  is no shell to return to, because the shell is the last thing
  running.
- One reader at a time, the console service's oldest-request
  discipline (T3.7): the proof chain's readers are done before the
  REPL starts, and while the counter pass runs the REPL is parked at
  the wait — the program owns the console until its exit, and the
  bytes the feed queues behind the quit key are the REPL's.

## The pins

`run.sh`'s chain grows the REPL's exchange after the proof chain's
last line, under both timer transports: the first prompt, the
`counter` command starting the machine's program (the full-boot
golden's beat — the frames, the keys, the quit key, the prompt's
return; the pins are the console renderer's, [`ui.md`](ui.md)), the
`help` line naming the eight commands, the echo command's echo, the
`ls` naming `hello.txt`, the `cat boot.txt` naming the kernel's boot
file's bytes (`EmoOS boots from disk`, written by the kernel root
through the first instance — the disk's content read back by a user
program through the gate, nothing staged by the test), the refusal
`cat: no such file` after `rm`, and `bogus: unknown command` — then
the exit route's lines as before, reached now by typing `poweroff`.
The write is proven by a line-order check on the list: the second
`ls` answers `hello.txt` and `note.txt` on consecutive lines, and the
write's echo cannot produce that pair. Three consecutive rounds
byte-identical on each leg.
