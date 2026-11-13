# Emo Playground

The web app where a visitor writes Emo code in the browser and runs it
on the server: an editor page, a dropdown of examples, one Run button,
and the answer below. It is a project of its own under
[`projects/emo-playground/`](.) — written in Emo, served by Emo's own
`httpd`, running submissions through Emo's own interpreter.

## How a run works

One submission is one fresh directory and one child process:

1. `POST /api/run` carries `{"code": "..."}` — a JSON body, capped at
   64 KiB by the server's body budget.
2. The run engine writes the code as `main.emo` into a fresh directory
   under `runs/`, beside a manifest pinning the standard library's
   hosted packages as dependencies — so `require "json"`,
   `require "os"`, and their siblings resolve, and the resolution
   gate's own error is the refusal a visitor sees for anything else
   (`dom` and the bare-metal and FFI-only packages are off the list on
   purpose).
3. Two pipes, one fork, one exec: the child's stdin is `/dev/null`,
   its working directory is the fresh run directory, its stderr is a
   file in the run directory (`stderr.txt` — a file never blocks its
   writer), and it runs `emo run main.emo --curfew N` — the N the
   server was configured with. The child moves itself into its own
   process group first, and forks a watchdog before the exec: a second
   interpreter running the tick program (a bare spinner the server
   wrote beside the run directories once at startup) under its own
   curfew, the run's plus a margin.
4. The parent closes its pipe write end, then one collector
   process drains stdout to EOF while the answering connection stays
   parked in `receive`. Streams past the 1 MiB output budget keep
   draining — a silent producer can never wedge the child on a full
   pipe — but only the budget is kept, with a truncation marker in its
   place. The stderr file is read after the child is reaped.
5. The verdict decodes from the raw wait status: `ok`, `compile`
   (exit 65/66 — the static stages), `curfew` (exit 124, the same
   number `timeout(1)` answers), `crash` (anything else, a signal
   death rendered as 128 plus the signal), and `internal` (exit 127 —
   the exec itself failed). The answer is one JSON document:
   `status`, `exit`, `curfew`, `stdout`, `stderr`.
6. The run directory is swept; its absence is the goal.

The process-group discipline closes the fork escape: a submission
that forks a process that lingers holds the pipe write ends past its
parent's death, and the collectors would never see EOF — the answer
would park until the server restarts. Everything the child ever forks
is in one group nothing else on the host belongs to, and the
watchdog's curfew passes the interpreter's deputized kill
(`EMO_RUN_GROUP`) to the toolchain: the whole group ends at the
curfew plus the margin, the write ends close with it, the answer
arrives. The margin keeps the child's own verdict (0, 65, 66, 124)
ahead of the kill, and covers the run child wedged in a system call,
which its own curfew can never reach.

The run's absolute paths never reach the visitor — the diagnostics
name `main.emo`, and the toolchain's lockfile notice (written into a
directory that is about to be swept) is scrubbed from the answer.

## The curfew

A runaway `while true {}` must end, and Emo has no clock — slog's own
header records that decision. So the clock lives in the toolchain:
`emo run --curfew SECONDS` hands one interpreted run a wall-clock
deadline, checked every 65,536 steps of the evaluator. Past the
deadline the run ends with exit 124 and the verdict on stderr, and the
page words it. A `--target` artifact does not consult the curfew, and
`--curfew` with `--target` is refused: the flag governs the
interpreter's own run only.

## Trust model

The curfew bounds the interpreter's CPU; it does not isolate. User
code runs with the interpreter's full library surface on the host
machine: it can read and write files, fork processes, and open
network connections. The decided mitigations are the fresh directory
per run, stdin from `/dev/null`, the body and output budgets, the
curfew, and the process-group discipline: everything a submission
forks lives in one group nothing else on the host belongs to, and the
watchdog's curfew ends that whole group (P2.1) — a submission cannot
outlive its own curfew through a process it left behind. A real
public deployment still wants a boundary of its own — a container or
a dedicated user — tracked as [P2.2](docs/TASKS.md).

## Configuration

Every knob is an environment variable with a decided default, read
once at startup; a malformed value stops the program with a message
naming the variable.

| variable | meaning | default |
| --- | --- | --- |
| `PG_HOST` | the bind address | `127.0.0.1` |
| `PG_PORT` | the bind port | `8080` |
| `PG_EMO` | the `emo` binary the runner execs | `emo` on PATH |
| `PG_CURFEW` | the run curfew, whole seconds, 1..120 | `5` |
| `PG_WEB_DIR` | the static assets' directory | `web` |
| `PG_RUNS_DIR` | where run directories are created | `runs` |

## Running it

From the project directory (the manifest's tree is the module tree,
and the assets and examples are read from disk beside it):

```console
$ emo run main.emo
playground serving http://127.0.0.1:8080 — curfew 5.0s
```

Then open the address in a browser, or knock on it by hand:

```console
$ curl -s -X POST -d '{"code":"println(\"hello\")"}' http://127.0.0.1:8080/api/run
{"status":"ok","exit":0,"curfew":5.0,"stdout":"hello\n","stderr":""}
```

## Testing it

```console
$ emo test
```

24 tests: the engine driven directly — a known program's bytes, a
compile error that names `main.emo`, the curfew, the output budget's
truncation, the swept directory, the fork escape's answer arriving at
the curfew plus the margin, the wedged run stopped by the watchdog —
and the routes driven the way the web-server guide's own tests drive
them, with one test over the wire on a port the kernel picks.

## Layout

```
package.emo        the manifest: the hosted packages, and the test
                   suite's own dependencies
main.emo           the entry: one Config, the tick program, one
                   listener, the wait
config.emo         the environment's knobs, validated at startup
server.emo         the listener and the route table
handlers.emo       the routes: page, assets, examples, /api/run
runner.emo         the run engine: pipes, fork, exec, the watchdog,
                   collect, sweep
web/               the page (index.html, style.css, app.js)
web/examples/      the programs the dropdown loads
test/              the suite: test_runner.emo, test_web.emo
```

The Chinese translation of this README is
[`README.zh-CN.md`](README.zh-CN.md).
