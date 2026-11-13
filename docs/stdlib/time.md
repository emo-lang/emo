# The `time` Package

The standard library's clock: the OS's wall clock and monotonic clock
ride three runtime doors, and every other part of the package is pure
Emo over those readings. A moment is a `Time` — an immutable value
whose calendar fields are computed in pure Emo — differences are
plain `Int64` milliseconds, and the timing family (`sleep`, `after`,
`tick`) parks processes the way the schedulers park everything else.
The parts a golden can pin are byte-identical on every target the
package declares.

## Using the package

```emo
require "time"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "time"` needs `"time" = "0.1.0"`
in the manifest's `deps` block.

## The units

- **A moment is a `Time` of UTC epoch milliseconds.** `Int64` millis
  is the coarsest resolution every hosted target's wall clock honestly
  carries (Node's `Date.now` pins the floor), and it survives Int64
  past any date that matters. A `Time` is an immutable class value:
  two instances with equal content are `==`, and one crosses a process
  boundary as a snapshot copy like any class value.
- **A duration is a plain `Int64` of milliseconds.** No wrapper type —
  the arithmetic the package wants is the arithmetic every target
  shares. The conversion family (`time.seconds(2)`, `time.days(3)`, …)
  plays the constants' role, and `t.add(ms)` moves a moment.
- **The timing family speaks seconds**, the way `net`'s timeouts do:
  `time.sleep(0.25)` is a quarter of a second, `time.tick(3) { ... }`
  is every three seconds. The interval truncates to whole milliseconds
  — the package's honest floor — and refuses the rest loudly.

## Errors

The package raises, it does not answer error tuples: every failure it
can produce is a contract violation in the caller's own argument. A
negative or non-finite interval, and an interval past the 1e9-second
ceiling, raises `Exception` naming the call and the value; a malformed
format layout raises naming the byte. The clock doors themselves
cannot fail — a reading is always available.

## The clock

```emo
def now() Time
def of_ms(ms Int64) Time
def of(year Int64, month Int64, day Int64, hour Int64, minute Int64, second Int64, ms Int64) Time
def mono() Int64
```

`now()` reads the OS's wall clock, UTC. `of_ms` and `of` construct a
fixed moment — the calendar constructor is pure arithmetic (Hinnant's
days_from_civil), so `time.of(year: 2026, month: 11, day: 13, ...)`
names the same moment on every target and in a golden.

`mono()` reads the monotonic clock — a reading that never goes back,
the instrument an elapsed measurement rides. The wall clock can jump;
this cannot. Two readings subtract directly:

```emo
const start = time.mono()
run_the_thing()
println(time.mono() - start)   // nanoseconds elapsed
```

The unit is nanoseconds; the resolution is the target's own
(`clock_gettime` on the native targets, `hrtime` on Node,
`performance.now()` on wasm and the browser, `monotonic_time` on the
BEAM).

## The `Time`

```emo
def unix_ms() Int64
def add(ms Int64) Time
def before?(other Time) Bool
def after?(other Time) Bool

def year() Int64            // the UTC calendar fields
def month() Int64           // 1..12
def day() Int64             // 1..31
def hour() Int64            // 0..23
def minute() Int64          // 0..59
def second() Int64          // 0..59
def millisecond() Int64     // 0..999
def weekday() Int64         // 0 Sunday .. 6 Saturday
def epoch_days() Int64      // whole days since the epoch, floored

def format(layout String) String
def format_iso() String
def format_http() String
```

Every field is pure arithmetic over the millisecond reading, so the
answers are the same on every target. `add` takes signed milliseconds —
a negative count moves back. The default rendering (`to_string`,
interpolation) is the ISO form.

The calendar is **UTC always**. A local time zone is a target's own
fiction — the same process prints a different date on a different
machine — so the package does not carry one; the UTC answer is the
deterministic one.

## Formatting

`t.format(layout)` walks the layout left to right. Nine tokens,
everything else literal byte for byte:

| Token | Renders | Example |
|---|---|---|
| `YYYY` | the year, zero-padded to four digits | `2026` |
| `MM` | the month, zero-padded | `11` |
| `DD` | the day of month, zero-padded | `13` |
| `hh` | the hour, zero-padded | `08` |
| `mm` | the minute, zero-padded | `30` |
| `ss` | the second, zero-padded | `15` |
| `mmm` | the milliseconds, zero-padded to three | `123` |
| `Mmm` | the month's short English name | `Nov` |
| `Www` | the weekday's short English name | `Fri` |

```emo
const t = time.of(year: 2026, month: 11, day: 13, hour: 8, minute: 30, second: 15, ms: 123)
println(t.format("YYYY-MM-DD hh:mm:ss"))   // 2026-11-13 08:30:15
println(t.format("Www, DD Mmm YYYY"))      // Fri, 13 Nov 2026
println(t.format_iso())                    // 2026-11-13T08:30:15.123Z
println(t.format_http())                   // Fri, 13 Nov 2026 08:30:15 GMT
```

The layout is strict, not Go's reference time: there is no magic date
to memorize, and there is no guessing. The letters `Y M D h m s` are
token letters — one that opens no complete token is a malformed
layout, and the raise names the byte and the rest of the layout
(`time: unknown layout token at byte 27: MT`). A literal uppercase M
needs the presets or string concatenation — `format_http` composes its
trailing ` GMT` outside the layout for exactly this reason. A year
wider than four digits prints full; a negative year prints a minus
sign in front of the padded absolute value.

`format_iso()` is RFC 3339 with milliseconds and the `Z` suffix.
`format_http()` is IMF-fixdate, the HTTP `Date` header's form.

## Differences

```emo
def since(t Time) Int64
def ms_between(a Time, b Time) Int64
def seconds_between(a Time, b Time) Float64
def minutes_between(a Time, b Time) Int64
def hours_between(a Time, b Time) Int64
def days_between(a Time, b Time) Int64
```

Every one answers `b - a`, signed: negative when `b` is the earlier
moment. `since(t)` measures from `t` to the wall clock's now — so a
clock adjustment shows up in it; that is the wall clock's own honesty.
For a measurement that must never jump, take two `mono()` readings and
subtract.

The `*_between` family truncates: 90 seconds is 0 minutes and 1 hour
is 0 days. `seconds_between` answers a `Float64` — the milliseconds'
own fraction — the others Int64. A calendar-day difference (midnight
to midnight in UTC) reads through the fields when the 24-hour count is
not what a caller wants.

## The conversions

```emo
def milliseconds(n Int64) Int64
def seconds(n Int64) Int64
def minutes(n Int64) Int64
def hours(n Int64) Int64
def days(n Int64) Int64
def weeks(n Int64) Int64
```

Plain multiplication into milliseconds — the constants' role. They
feed `add` and the doors that take a millisecond count directly:

```emo
println(launch.add(time.hours(25)).format("YYYY-MM-DD hh:mm:ss"))
// 2026-11-14 09:30:15
```

## The timing family

```emo
def sleep(seconds Float64) Void
def after(seconds Float64, f Block) Void
def tick(seconds Float64, f Block) Void
```

`sleep(seconds)` parks the calling process for the interval. It is a
real park: the process leaves the run queue, other processes take
their turns, and the scheduler wakes it at the deadline. A message
that arrives while it sleeps queues in the mailbox and waits for the
wake — sleep is woken early by nothing.

`after(seconds, f)` runs the block once, the interval out, in its own
process. The caller continues at once; the block's own raise kills
only its process. There is no cancel — the interval is the scheduled
run's whole contract.

```emo
time.after(0.5) {
  println("half a second later")
}
```

`tick(seconds, f)` runs the block **in the calling process every
interval, forever — the heartbeat. It never returns.** The block's own
raise or `halt()` is the stop, and the code after a tick is the code a
heartbeat program never reaches. This is Go `time.Tick`'s own
discipline ("it offers no way to stop it once started"); `after` is
the scheduled one-shot beside it. The first run comes one interval in.

```emo
// three ticks, then the heartbeat ends itself
def heart(total Int64, owner Pid) Void {
  const count = Box.new(0)
  time.tick(0.05) {
    count.replace(count.read() + 1)
    println("tick ${count.read()}")
    if count.read() == total {
      owner <- ("demo", "done")
      halt()
    }
  }
}

do heart(3, self_pid())
receive {
  ("demo", "done") -> { println("the heartbeat ended") }
}
```

A block inside a `tick` runs in the ticking process — `halt()` there
ends the ticking process, and the program goes on without it.

**The floors a caller should know.** The interval truncates to whole
milliseconds: `time.sleep(0.0009)` is a one-millisecond sleep. Each
target's own timer limit is the second floor — Node clamps one timer
at 2³¹−1 ms (about 24.8 days; the runtime re-arms in slices so the
contract holds past it), and a sleep's real length is always at least
the interval, never less. The 1e9-second ceiling (about 31 years) is
the package's own, and crossing it raises.

## Targets

`["ocaml", "c", "typescript", "wasm", "beam"]`. The clock half runs
everywhere the package declares — on `wasm` through the two host
imports (`time_now_ms`, `time_mono_ns`). The timing half raises at the
call on `wasm`, naming the capability: the wasm driver runs the whole
program synchronously inside one host call, and no honest park exists
until the driver learns to await — the `os` package's process half is
the precedent. `riscv64` stays undeclared: the bare-metal kernel owns
its own tick. The `browser` target stays undeclared too — a browser
program's timing is the page's own timers — though the TypeScript
browser host already carries the doors, so declaring it later is the
package's own manifest change, not a compiler one.

## Reference

- The demo: `examples/time_demo` — a fixed moment built from parts,
  every format token, the calendar fields, the between family, the
  conversions, `mono` around a sleep, three ticks ending in `halt`,
  and one `after` — byte-identical on the interpreter, ocaml, c,
  typescript, and beam.
- The settle record: `CHECK.md` (the `time` entry) and
  `plan/step-81-stdlib-time.md`.
