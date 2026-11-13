# Step 81 — The standard library: `time`

**Milestone:** M42 — The clock and the heartbeat · **Prereq:** step 12
(the processes the timing family parks) · **Related:** `stdlib/registry/os`
(the door-family precedent and the target-split discipline),
`docs/stdlib/time.md` · **Status:** done on the interpreter, ocaml, c,
typescript, and beam — the demo golden rides those four compiled lists
plus the bootstrap; the wasm target carries the clock half and refuses
the timing half at the call.

## Why this step exists

The language has had no clock by decision — slog prints no timestamp
and httpd ships no `Date` header because there was nothing to read
(the stance both references), and the wasm host answered WASI's
`clock_time_get` with ENOSYS naming the pressure. Every program that
measures, schedules, or logs time wanted the same three things: read
the OS's clock, measure a difference, and park until a moment. The
park is the language's own question — Emo's processes park in
`receive` and the schedulers already own timers for IO deadlines — so
the clock lands as the standard library's `time` package over three
runtime doors, and the timing family is pure Emo over them.

## Goal

`require "time"` gives a program the wall clock, the monotonic clock,
and the timing family, byte-identical in its deterministic parts
(everything a golden can pin) on the interpreter, `ocaml`, `c`,
`typescript`, and `beam`, with the `wasm` target carrying the clock
half and refusing the timing half at the call, the way `os`'s process
half does there.

## Decisions settled here

- **The value is a `Time` of UTC epoch milliseconds.** `Int64` millis
  is the coarsest resolution every hosted target's wall clock honestly
  carries (Node's `Date.now` pins the floor), it survives Int64 past
  any date that matters, and it makes two `Time`s directly subtractable
  — no nanosecond fiction. A `Time` is an immutable class value with
  the calendar fields computed in pure Emo (Hinnant's civil-from-days,
  floor division everywhere), so `year()` through `weekday()` answer
  the same on every target and a golden can pin them.
- **Durations are plain `Int64` milliseconds.** No `Duration` type in
  v1: the arithmetic the package wants (`add`, the `*_between` family)
  is Int64 arithmetic every target shares, the conversion family
  (`time.seconds(n)` … `time.weeks(n)`) plays the constants' role, and
  a wrapper type adds friction the package's surface does not need.
  A `Duration` class can land later without breaking any of this.
- **The timing family speaks seconds, like `net`'s timeouts.**
  `sleep(seconds Float64)`, `after(seconds Float64, f Block)`, and
  `tick(seconds Float64, f Block)` take a Float64 number of seconds —
  `time.tick(3) { ... }` is three seconds, `time.sleep(0.25)` is a
  quarter — and the interval truncates to whole milliseconds, the
  package's honest floor. Negative or non-finite intervals and
  intervals past the 1e9-second ceiling raise; nothing clamps silently
  except the target's own timer limit, which the reference documents.
- **`tick` is the calling process's heartbeat and never returns.** The
  block runs in the caller each interval, forever, Go `time.Tick`'s own
  discipline ("no way to stop it once started"); a raise or `halt()`
  inside the block ends the ticking process, which is the stop, and
  `after` exists for the scheduled one-shot. A stoppable ticker waits
  for receive-with-deadline — recorded as the named open item, BEAM
  native, the schedulers one park away.
- **Formatting is a strict token layout, not Go's reference time.**
  `t.format("YYYY-MM-DD hh:mm:ss")` — nine tokens (`YYYY MM DD hh mm
  ss mmm Mmm Www`, month and weekday names the short English forms),
  everything else literal, and a token letter that opens no complete
  token raises, naming the byte. No magic reference date, no local
  zones: the calendar is UTC always, deterministic on every target, so
  `format` output can ride a golden. `format_iso()` (RFC 3339 with
  milliseconds) and `format_http()` (IMF-fixdate) are the named
  presets.
- **Three doors, no more.** `time_now_ms()` (the wall clock, UTC
  millis), `time_mono_ns()` (the monotonic clock, nanoseconds — the
  elapsed-time instrument `sleep`'s floor cannot serve), and
  `time_sleep_ms(ms)` (parks the calling process, exact-ish, woken
  early by nothing — a message queues and waits for the wake). The
  macro-purity rule names all three: a compile-time body refuses the
  clock like it refuses the filesystem.
- **Targets: `["ocaml", "c", "typescript", "wasm", "beam"]`.** The
  clock half runs on wasm through two host imports; the timing half
  raises at the call there — the wasm driver is synchronous inside one
  host call, and no honest park exists until the driver learns to
  await (the recorded open item). `riscv64` and `browser` stay
  undeclared.

## Deliberately out (v1)

Local-time zones (the calendar is UTC until a target honestly carries
its zone), a `Duration` type, nanosecond wall resolution, timers
cancellable mid-interval (receive-with-deadline, the named open item),
monotonic `Time` blending (Go's hidden monotonic reading — Emo's
`Time` is wall-only and `time.mono()` is the explicit instrument),
leap-second smearing, and WASI `clock_time_get` wiring (the wasm
package's recorded pressure now has its primitive; the fixture pins
ENOSYS until that arc).

## Tasks

- [x] **T81.1** — The doors: the checker's table, the interpreter's
      frame bindings and dispatch arms, the `Sleep` effect through both
      OCaml schedulers (the interpreter's and the compiled runtime's),
      the POSIX monotonic stub beside both runtimes, the C runtime's
      three functions plus the sleeper park in its scheduler, the wasm
      import pair and the timing refusal, the TypeScript hosts' three
      arms (Node and browser), and the BEAM lowering arms.
- [x] **T81.2** — The package: `stdlib/registry/time/0.1.0` — the
      manifest, the `Time` class (the fields, `format`, the presets),
      the conversion family, `now`/`of`/`of_ms`/`mono`, the timing
      family, and the between family — pure Emo over the doors.
- [x] **T81.3** — The golden: `examples/time_demo` (a fixed moment
      built from parts, every format token, the calendar fields, the
      between family, the conversions, `mono` around a sleep, three
      ticks ending in `halt`, and one `after`) on the interpreter,
      ocaml, c, typescript, and beam lists.
- [x] **T81.4** — The docs: `docs/stdlib/time.md` + zh-CN mirror, the
      `docs/stdlib.md` row + section + mirror, the demo-targets import
      table, and the stale "no clock" stances updated (slog's and
      httpd's) to name what owns the clock now.
- [x] **T81.5** — The tracking: this plan, `plan/README.md`'s row,
      `docs/TASKS.md`'s M42 section + mirror, CHECK.md's settle record.

## Found and fixed here

Four bugs the goldens flushed, each a shape no shipped example had
walked before the heartbeat:

- **The IR's Void-body exit positions lowered a bare trailing call as
  an Effect, and every backend's tail machinery keyed on
  `Return_stmt (Call f)`** — so a Void function ending in a self-call
  (`tick_loop(ms, f)`) grew its stack per call everywhere: the C
  emitter emitted a plain recursive call into an 8 MiB fiber, the TS
  emitter kept the await shape (a promise chain per tick), and the
  interpreter evaluated the call inline. The lowering now turns the
  exit-position bare call into the Return it is (the body, an `if`'s
  two branches, a `case`/`receive` branch; loop bodies keep their
  effects; a first-class block call stays a plain exit), the C
  emitter's Void return path emits the expression it carries (until
  now a Void `Return_stmt` could only be the valueless desugar), and
  the interpreter's frame threads tailness through the statement walk
  (`eval_stmts`, the flag threading into the branch bodies, the
  `Expr_stmt`-in-tail arm raising the same `Tail_call` the explicit
  return raises). The heartbeat is now constant-stack on every target.
- **The c backend's closure capture never walked a `Send` statement's
  operands** — `closure_free` stopped at the statement, so a block
  whose only use of an outer binding is the pid it sends to (the
  heartbeat's `owner <- (...)`) captured nothing and the build refused
  (`the variable \`owner\` here`). The walk now covers the send's
  target and message, and the raised value.
- **The TS emitter's `receive` statement carried no trailing `;`** — a
  following statement that opens with `(` parsed as a call of the
  receive's answer (`await E.receive(...)(await time__after(...))`).
  The statement form now ends with the semicolon the sequencer's rule
  already states.
- **The c backend's Void-return discard pooled its claim twice.** The
  Void body's return now evaluates the expression it carries — but
  `emit_expr` pools a dynamic answer itself (the "a dynamic result
  lands in the pool" rule), and the discard wrapped it again:
  `emo_autorelease(emo_autorelease(call))` put the same word in the
  statement's pool twice, and the drain released it twice — the shell
  (emosh) segfaulted on `emo_builder_to_array` reading a freelist
  cell. The discard keeps the expression's own claim; only the
  statement-shaped builders (`emit_runtime_impl`, the spawn site, the
  foreign call — raw strings) take the statement's own wrap.
- **The BEAM emitter's pattern lowering emitted the literal `_`** —
  Core Erlang has no wildcard, so two `_` in one pattern (the calendar
  destructures `const (y, _, _) = ...`) collide as duplicate
  variables. A wildcard now lowers as a distinct fresh variable.
