# The `slog` Package

The standard library's structured logger: one line per record, either
logfmt or JSON, filtered by a minimum level. Pure Emo over the shared
runtimes, so every target the package declares answers with the same
bytes.

A logger is an opaque handle — `slog.new` answers one, `slog.child`
derives a renamed copy — and the handle itself carries the name, the
minimum level, and the format. A logger is an ordinary value: nothing
to configure behind the scenes, nothing to tear down, and no global
state anywhere in the package.

## Using the package

```emo
require "slog"
```

A `require` pairs strictly with the manifest: `slog` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript"]

  deps {
    slog = "0.1.0"
  }
}
```

The declared targets are the ones that work today: the wasm and beam
runtimes do not implement `Map` yet, and attrs are a `Map`. The
manifest widens when they land.

## The surface

```emo
def level_debug() Int64
def level_info() Int64
def level_warn() Int64
def level_error() Int64

def format_logfmt() Int64
def format_json() Int64

def new(name String, min Int64, format Int64) String
def child(handle String, name String) String
def enabled(handle String, level Int64) Bool

def debug(handle String, msg String, attrs Map[String, String])
def info(handle String, msg String, attrs Map[String, String])
def warn(handle String, msg String, attrs Map[String, String])
def error(handle String, msg String, attrs Map[String, String])
```

Levels are ordered, `debug < info < warn < error`: a record below the
logger's minimum prints nothing, and `enabled` answers the same
question before the caller builds the record. A child nests its name
under the parent's (`web` + `db` is `web.db`) and inherits the level
and the format.

## The records

Records go to stdout, one `println` per record, and carry no
timestamp: Emo has no clock, and deterministic output is worth more
than stamps the caller would have to fake. A caller with a time in
hand passes it as an ordinary attribute.

The logfmt format:

```emo
level=info logger=web msg=listening addr=127.0.0.1:8080
level=warn logger=web msg="slow query" ms=412 table=users
```

The json format renders the same record as one object per line:

```emo
{"level":"info","logger":"worker","msg":"job done","job":"resize","ms":"38"}
```

Both formats emit `level`, `logger`, `msg`, then the attrs in map
order. A value renders bare when every byte survives the line — no
spaces, control bytes, `"`, `=`, or `\` — and quoted with escapes
otherwise; UTF-8 text rides through. The json format escapes by
RFC 8259.

Attrs are a `Map[String, String]`: render numbers and booleans by
interpolation before the call ("${port}").

## Strictness

Every call validates its handle and its keys, then filters — a bad
key is a mistake even when the record would not have printed.
Attribute keys are ASCII letters, digits, `_`, `.`, `-` only, so a key
reads the same in both formats. Every rejection raises an ordinary Emo
exception saying exactly what failed; filtering is the only silence.

## Errors

- `slog: logger name must not be empty` — an empty name at `new` or
  `child`;
- `slog: unknown level 7` / `slog: unknown format 5` — out of range at
  `new`, or at `enabled`;
- `slog: not a logger handle: web` — a plain name passed where a
  handle belongs;
- `slog: malformed logger handle: slog:x:9` — a corrupted handle;
- `slog: invalid attribute key "has space"` — keys are ASCII letters,
  digits, `_`, `.`, `-`.

## The golden

The golden (`examples/slog_demo`) exercises both formats, level
filtering, a child logger, quoting and escaping (quotes, `=`, empty
values, UTF-8), and `enabled` — byte-identical on the interpreter,
ocaml, c, and typescript.
