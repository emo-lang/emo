# Concurrency

Emo ships with a native concurrency model built around **processes and message passing**, in the spirit of the actor model. This choice is deliberate: it maps natively onto BEAM processes, while the `ocaml` backend implements it with a scheduler built on OCaml 5 effects — the same foundation proven by runtimes such as Eio.

The concurrency semantics are shaped by the following decisions:

- **`do` starts a process and yields its pid.** `do work(item)` runs the call in a new process; the value of the `do`-expression is the new process's pid, and the call's own result is discarded.
- **`pid <- message` sends.** `<-` delivers a message to a process's mailbox, and is always written with a space on each side — a juxtaposed `a<-b` is a syntax error rather than a guess, and comparison against a negated value is `a < -b`.
- **`receive` takes the same branches as `case`.** `receive { ... }` scans the mailbox for the first message matching any branch; non-matching messages stay queued, and the process blocks while nothing matches — selective receive comes from ordinary patterns, with no separate mechanism.
- **A process learns its own pid with `self_pid()`.** The idiomatic reply pattern is one line — `sender <- (self_pid(), request)` — with the tuple destructured right in the receiver's branch pattern. Pids are opaque values of type `Pid` that compare by identity and render as `<pid 3>`.
- **`halt()` stops the current process.** So does an unhandled error, and either kills only the offending process; core provides the process-exit signal a supervisor needs and nothing more — kill, wait, and restart policies are library territory.
- **The root process is the program.** When it ends — normally, by `halt()`, or by an uncaught raise — the program ends with it, and processes still runnable or parked are dropped. A program that waits for spawned work keeps its root alive, normally parked in `receive`; the rule holds on every target, including BEAM.
- Message passing is the core concurrency primitive; shared-memory primitives are not part of the core semantics.
- Data is immutable by default, so messages can be passed by copying on BEAM and by reference on the `ocaml` and `c` backends while keeping identical observable semantics.
- Tail calls are guaranteed; recursion is the idiomatic shape of a receive loop.
- Crash isolation and supervision are library-level on both backends: an unhandled error kills only the offending process.
