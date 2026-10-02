# Step 11 — Processes & Message Passing

**Milestone:** M3 · **Prereq:** steps 01–10 · **Status:** done

## Goal

Emo's concurrency core: processes with mailboxes, message passing as the
only cross-process primitive, crash isolation, and the mutable-cell —
implemented on an OCaml 5 effects-based scheduler. **This step cannot start
before its API surface is designed** (see open items) — the README fixes the
semantics, not the spellings.

## Scope

### In

- **API design pass (blocking gate):** process start, send, and receive are
  decided — `do work(item)` yields the new process's pid, `pid <- message`
  sends, and `receive { ... }` reuses `case` branches for selective
  receive (README, Concurrency). Still to settle in `CHECK.md` / the
  README *before* implementing: the self-pid mechanism. Everything below
  assumes it is decided.
- **Scheduler, phase A — Eio:** implement processes directly on Eio fibers
  (the README names Eio as proof of this foundation). This ships the
  semantics fastest and keeps the runtime behind one internal interface.
- **Scheduler, phase B — own effects runtime:** replace Eio beneath that
  interface with a hand-written OCaml 5 effects scheduler (io_uring / kqueue
  / IOCP with libuv fallback comes with step 12's IO). The evaluator's
  blocking points (`receive`, IO) are effect handlers; a pluggable,
  injectable scheduler decision log makes concurrency tests deterministic.
- **Processes** —
  - A process starts with `do <call>`: the new process runs the call, the
    call's own result is discarded, and the `do`-expression evaluates to
    the new process's pid — `const pid = do fetch(page)`. The caller
    continues immediately; all further conversation happens through
    `pid <- message` and the receive form.
  - A process owns a mailbox (an unbounded queue of values) and a heap
    partition; message data is deeply immutable, so native can pass by
    reference and semantics stay identical (the README's dual-backend rule).
  - Every process runs one Emo evaluation stack; tail calls (already
    guaranteed since step 05) make receive loops idiomatic.
  - `receive { ... }` takes the same branches as `case`: the mailbox is
    scanned in order for the first message matching any branch pattern;
    non-matching messages stay queued, and the process blocks while
    nothing matches. Selective receive falls out of ordinary patterns —
    no separate mechanism (Erlang semantics, README promise).
  - The idiomatic message envelope is a tuple — `(reply_to, request)` —
    destructured right in the branch pattern:
    `(reply_to, Color.red) -> { ... }`. Reply flow therefore needs a way
    for a process to learn its own pid (open item below).
  - Uncaught exceptions or errors kill **only** the offending process;
    supervision (restart policies, links) is standard-library territory,
    not runtime — this step provides the process-exit signal a supervisor
    needs, nothing more.
- **`Box`** — the per-process long-lived mutable state primitive:
  `Box.new(v)` / `box.read()` / `box.replace(v)` (annotation `Box[Int]`),
  in place since M1 (step 05). Sending a Box to another process delivers
  a snapshot copy — mutability never crosses a process boundary; this is
  tested as an observable rule.
- **Determinism infrastructure** — a seedable, log-based scheduler for
  tests: every race-sensitive test runs against replayed schedules, so
  concurrency bugs reproduce.

### Out

- Networking (step 12 — though the scheduler interface lands here).
- Supervision library, gen-server-style patterns (standard library, later).
- Shared-memory primitives (excluded from core semantics by design).
- BEAM mapping (step 14 — but this step's tests should avoid constructs a
  BEAM backend could not honor).

## Tasks

- [x] Design pass: the self-pid mechanism settled in `CHECK.md` / README —
      `do` (start, yields pid), `<-` (send), `receive { ... }` (selective
      receive via `case` branches), and `Box` with its operation set are
      already decided.
- [x] Process/mailbox abstraction on Eio; spawn/send/receive.
- [x] Crash isolation; process-exit signals for future supervisors.
- [x] `Box` with snapshot-on-send semantics.
- [x] Deterministic scheduler log for tests.
- [x] Phase B: own effects-based scheduler beneath the same interface.
- [x] Stress tests: ping-pong, fan-out/fan-in, deep receive-loop recursion.

## Acceptance

```emo
def worker() {
  receive {
    Color.red -> {
      return halt()
    }
    _ -> {
      worker()            // tail call — the idiomatic receive loop
    }
  }
}

const pid = do worker()

pid <- Color.red
```

- Ping-pong (1M messages) and fan-out/fan-in (1000 workers) run correctly
  under both phase A and phase B schedulers.
- A process that raises mid-message dies alone; the parent observes the
  exit and continues.
- Sending a Box yields a snapshot: mutating after send is
  unobservable at the receiver — tested.
- Receive loops recursing millions of times keep the native stack flat.
- `dune test` green under the deterministic scheduler.

## Open design items

None — the self-pid mechanism settled in the design pass: `self_pid()`,
`halt()`, and the `Pid` type (rendered `<pid N>`) live in the README;
`CHECK.md` keeps only what is still pending.
