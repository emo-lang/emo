# The `sync` Package

The standard library's coordination package: a wait group — a one-shot
countdown that lets a process wait for N units of work. Pure Emo over
the process primitives — a wait group is a process holding a count,
`done` is one message, `wait` is another — so every target the package
declares answers with the same observable behavior, and nothing here
needed a compiler change.

A wait group is the message-passing answer to "wait for my workers":
the shape Go reaches for `sync.WaitGroup` for, spelled the way actors
spell it. It is deliberately **not** a shared-memory primitive — Emo
has no shared memory to guard (messages are snapshot copies), which is
why the package has no mutex: a mutex guards memory, and there is none
to guard. A wait group guards nothing; it only counts.

## Using the package

```emo
require "sync"
```

A `require` pairs strictly with the manifest: `sync` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    sync = "0.1.0"
  }
}
```

The wait group is pure message passing over primitives every target
implements, so the manifest declares all five.

## The surface

```emo
def wait_group(n Int64) Pid
def done(wg Pid) Void
def wait(wg Pid) Void
def stop(wg Pid) Void
```

`wait_group` starts a countdown of `n` units and answers the group's
pid — the handle every other call takes. `done` announces one finished
unit; `wait` blocks until the count drains and answers immediately
once it has; `stop` ends the counter process.

The shape of a fan-out:

```emo
const wg = sync.wait_group(3)  // three units of work ahead
do worker(wg)                  // ... each ends with sync.done(wg)
do worker(wg)
do worker(wg)
sync.wait(wg)                  // returns with the third done
sync.stop(wg)
```

Several processes may `wait` on one group, and each is woken. A
zero-count group is born drained: its `wait` answers at once.

## The lifecycle

The count is set once at `wait_group` and only ever goes down: a wait
group is single-use, and there is no `add`. The counter process parks
once drained — a late `wait` still answers, and a late `done` still
raises at its caller — and a process parked forever would hold the
whole program open, so the lifecycle ends explicitly: `stop` halts the
counter, and a `wait` still parked at that moment raises at its caller
instead of hanging. The discipline is the plain one: stop the group
after your last wait.

## Strictness

A `done` past the count does not silently vanish — the call
round-trips through the counter and raises, naming the caller's
mistake at the caller instead of letting it drown in the counter's
mailbox. (A call raced by a `stop` — its counter already gone — drops
like any send to a dead pid.) `wait_group` refuses a negative count.

## Errors

- `sync: the count must not be negative, got -2` — a
  negative count at `wait_group`;
- `sync: the countdown already drained` — a `done` beyond the
  count;
- `sync: the wait group was stopped under the wait` — a `wait`
  still parked when `stop` landed.

## The protocol

Every message on the wire, in either direction, is a tuple tagged
`"sync"` — the package name — so a wait group's traffic never collides
with an application's own messages: `("sync", "dec", from)` and
`("sync", "wait", from)` toward the counter, `("sync", "ok")`,
`("sync", "underflow")`, `("sync", "drained")`, and
`("sync", "stopped")` back. A caller never sees these; they are
documented because a mailbox is a public place, and a protocol that
hides its wire shape cannot be reasoned about when two libraries
share one process's mailbox.

## The golden

The golden (`examples/sync_demo`) exercises fan-out/fan-in, several
waiters on one group, and the zero case — byte-identical on the
interpreter, ocaml, c, typescript, wasm, and beam.
