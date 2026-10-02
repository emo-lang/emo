# Pipeline

Four concurrent processes passing one message shape down a linear
assembly line — orders enter at one end, labeled output leaves at the
other.

```console
emo run main.emo
```

What to notice:

- **`do` starts a process and yields its pid.** The line is two spawned
  stages plus the entry process that feeds it.
- **`pid <- message` sends; `receive` takes the same branches as
  `case`.** Tuple patterns destructure the message right in the branch,
  and `self_pid()` gives a stage the address to report to.
- **Mailboxes are FIFO**, so a linear chain delivers in order — the
  output is deterministic even though every stage runs concurrently.
- **The entry process keeps the program alive.** It closes the line with
  a `"done"` message and waits for the report before leaving; every
  stage exits through `halt()` when its work is drained.
- Tail recursion is the receive loop — no `while`, no callbacks, and
  the compiler guarantees the tail calls.

The golden output is in `expected.txt`.
