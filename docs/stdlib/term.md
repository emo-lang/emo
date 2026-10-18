# The `term` Package

The standard library's terminal-input surface: line reads, raw mode,
decoded key events, and the terminal's size, all on stdin (file
descriptor 0). It is the second native-binding package in the standard
library — the calls are `foreign def`s against a small C shim the
package carries in its own tree — and it declares `targets = ["c"]`.
The build compiles the shim by itself: consuming the package is plain
`require`, with no flags to pass.

The interpreter refuses foreign code (E3009) and the other targets
refuse the package at resolution, so `emo run` cannot execute a
program that touches it; build with `emo build` (the default target is
`c`).

## Using the package

```emo
require "term"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "term"` needs `"term" = "0.1.0"` in
the manifest's `deps` block.

## Errors

Following the standard library's convention, every failing call
answers `(R.ok, value)` or `(R.error, reason)`, the reason a String
that begins with the package name and names the operation —
`term: enable_raw: not a terminal`, `term: size: Inappropriate ioctl
for device`. End of input is not an error: `read_line` answers `""`
and `read_key` answers `Key.eof`.

## Line input

```emo
def read_line() (R, String)
```

One line from stdin, **terminator included** — the same choice
`bufio` makes, so an empty line (`"\n"`) and the end of the input
(`""`) are never the same answer. A last line without a terminator is
returned as it is. A String carrying an embedded NUL truncates there,
as at every C boundary.

## Terminals and size

```emo
def is_tty() Bool
def size() (R, (Int64, Int64))
```

`is_tty` is true when stdin is a terminal. `size` answers
`(columns, rows)` from the terminal driver, or `(R.error, reason)`
when stdin is not a terminal (or the driver reports no size).

## Raw mode

```emo
def enable_raw() (R, Int64)
def restore() (R, Int64)
```

`enable_raw` puts stdin in raw mode: bytes arrive unbuffered, echo is
off, and Ctrl-C and Ctrl-Z are keys rather than signals. The previous
setting is saved; `restore` puts it back. Both answer `(R.ok, 0)` on
success. `enable_raw` is idempotent, and `restore` with raw mode off
is a no-op.

The saved setting is restored automatically when the process exits, so
a program that returns without an explicit `restore` leaves the
terminal usable. A signal that ends the process without running its
exit path (`SIGKILL`, or `SIGTERM` before the program handles it)
bypasses that; the shell's `reset` command is the recovery.

## Key events

```emo
enum Key {
  char, ctrl, enter, tab, back_tab, backspace, escape,
  up, down, left, right, home, end, insert, delete,
  page_up, page_down,
  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
  alt, unknown, eof
}

def read_key() (R, (Key, Int64))
```

`read_key` blocks for the next key and answers the enum member plus a
code:

| Member | Code |
|---|---|
| `char` | the character's Unicode scalar value (UTF-8 decoded) |
| `ctrl` | Ctrl-@ through Ctrl-Z as `0`–`26` |
| `alt` | the following ASCII byte's value (`1`–`26` for a control key) |
| `unknown` | the final byte of an escape sequence the package does not decode |
| `eof` | `0` |
| every other member | `0` |

Raw mode is what makes keys arrive as they are pressed; without it the
terminal's own line discipline still applies, and `read_key` sees
whole lines. Ctrl-C reaches the program as `Key.ctrl` with code `3`
only while raw mode is on.

The decoder recognizes the sequences a terminal sends for the arrow
keys, Home/End, Insert/Delete, Page Up/Page Down, F1–F12, Shift-Tab,
and Alt+key. `Esc` followed by nothing within 50 ms is `Key.escape` —
the conventional way to tell a lone Esc from the start of a sequence.
Modifier parameters (`Esc [ 1 ; 5 A` and friends) are accepted and
ignored: the surface has no modifier bit yet, so Ctrl-Up reads as
`Key.up`. Mouse reports, bracketed paste, and focus events are not
decoded; they arrive as `Key.unknown`.

## Boundaries and limitations

- **stdin only.** The package reads file descriptor 0, the terminal a
  TUI paints to. A program reading a second terminal, or a file
  descriptor chosen by the caller, is out of scope.
- **Unix terminals.** The package is `c`-target only and uses POSIX
  termios; Windows consoles are not a target.
- **No resize events.** `size()` answers the current size on demand;
  the SIGWINCH wiring is the UI framework's next step, not this
  package's.
- **Esc timing.** The 50 ms wait after Esc is the only timing in the
  package. A remote or very slow terminal that delivers one escape
  sequence's bytes further apart than that sees `Key.escape` followed
  by the remaining bytes.

## Example

```emo
require "term"

def main() {
  const (R.ok, _) = term.enable_raw()
  var more = true
  while more {
    const (R.ok, key) = term.read_key()
    case key {
      (term.Key.ctrl, 3) -> { more = false }
      (term.Key.enter, _) -> { println("enter") }
      (term.Key.char, code) -> { println("char ${code}") }
      _ -> {}
    }
  }
  term.restore()
}
```

The runnable demo is `examples/term_demo`, which reads lines until the
end of the input.
