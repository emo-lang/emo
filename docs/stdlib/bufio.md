# The `bufio` Package

The standard library's buffered IO: a fixed-size memory buffer in
front of any byte stream, so readers issue few large reads instead of
many small ones, writers coalesce small writes into few large ones,
and both sides gain whole-line and up-to-a-delimiter reads on top of
raw chunks. The shape follows Go's `bufio`: a `Reader` and a `Writer`
over tiny structural interfaces, adapters for the concrete streams,
and buffers the caller sizes explicitly.

The package is pure Emo over `os`, so it runs on the targets `os`
runs on: the ocaml and c targets, the ones with a Unix-shaped host.

## Using the package

```emo
require "bufio"
```

A `require` pairs strictly with the manifest: `bufio` (and `os`,
which it builds on) must be pinned in `package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    bufio = "0.1.0"
    os = "0.1.0"
  }
}
```

## The stream shapes

Two interfaces, one method each, carry the whole abstraction:

```emo
interface ByteReader {
  def read(n Int64) String
}

interface ByteWriter {
  def write(data String) Int64
}
```

`read(n)` returns up to `n` bytes — fewer only at end of stream — and
the empty string once the stream is exhausted, exactly like
`os.read`. `write(data)` takes every byte or raises; the return is
the number of bytes taken. Any class with a matching `read` or
`write` satisfies the interface by shape — the buffered `Reader`
itself is a `ByteReader`, so readers stack.

The adapters hand the concrete streams:

```emo
def fd_reader(fd Int64) FdReader
def fd_writer(fd Int64) FdWriter

def bytes_reader(data String) BytesReader
def bytes_writer() BytesSink
```

The fd adapters read and write through `os.read` and `os.write`, so
files, pipes, and every other descriptor stream ride the same
interface. The in-memory pair makes the buffered logic usable with
nothing behind it: `BytesReader` serves a string's bytes, and
`BytesSink` accumulates what it is handed — its `to_string` hands the
accumulation back without draining it.

## End of stream is a value

Emo has no error channel, so end of stream is never an exception: the
empty string ends the stream, the same rule `os.read` set. A raise is
reserved for the caller's own mistakes — a negative count, a peek
wider than the buffer, a delimiter that is not one byte — and for
failures the underlying stream raises through unchanged.

`read_line` keeps the terminator on purpose: a line's terminator is
data, an empty line must stay distinguishable from the end of the
stream, and the last line of a file may be unterminated. Strip it
only when it is there:

```emo
const line = r.read_line()
if line != "" {
  var text = line
  if bufio.window(line, line.length() - 1, 1) == "\n" {
    text = bufio.window(line, 0, line.length() - 1)
  }
  // ...
}
```

## The Reader

```emo
def default_size() Int64
def reader(src ByteReader) Reader
def reader_size(src ByteReader, size Int64) Reader
```

`default_size` is 4096. The size must be positive — a zero or
negative buffer raises at construction.

```emo
def read(n Int64) String
def read_byte() String
def read_string(delim String) String
def read_line() String
def peek(n Int64) String
def discard(n Int64) Int64
def unread_byte() Void
def buffered() Int64
def reset(src ByteReader) Void
def fill_once() Bool
def fill_until(need Int64) Void
def consume_through(delim String, acc String) String
```

- `read(n)` — up to `n` bytes: the buffer first, then the stream once
  if the buffer is empty. Fewer than `n` means the stream gave all it
  had; the empty string means end of stream.
- `read_byte()` — one byte as a one-byte string; the empty string at
  end of stream.
- `read_string(delim)` — reads through the next occurrence of the
  one-byte delimiter, terminator included, accumulating across
  refills: a delimiter beyond one buffer's worth still arrives whole.
  The empty string means the stream ended before any byte arrived; an
  unterminated final tail is returned as is.
- `read_line()` — `read_string("\n")` by another name: the next line,
  terminator included, the empty string at end of stream.
- `peek(n)` — fills until at least `n` bytes are buffered, then hands
  back exactly those `n` bytes without consuming them. A peek wider
  than the buffer can never be satisfied and raises.
- `discard(n)` — skips up to `n` bytes, returning how many were
  actually skipped.
- `unread_byte()` — pushes the byte read most recently back, once:
  the next read hands it back. A refill between the read and the
  un-read loses the byte and makes the call raise.
- `buffered()` — the bytes ready in the buffer, unread.
- `reset(src)` — starts over: the buffer is emptied and reading
  continues from `src`.

`fill_once`, `fill_until`, and `consume_through` are the refill and
scan machinery the methods above share; they are part of the surface
because everything in the package is, and the doc comments in the
source state their contracts.

## The Writer

```emo
def writer(sink ByteWriter) Writer
def writer_size(sink ByteWriter, size Int64) Writer
```

```emo
def write(data String) Int64
def write_byte(b String) Void
def flush() Void
def buffered() Int64
def available() Int64
def reset(sink ByteWriter) Void
def push(data String) Int64
def write_rest(data String) Void
```

- `write(data)` — buffers the bytes, flushing as the buffer fills. A
  write at least as large as the whole empty buffer passes straight
  through to the sink instead of taking a detour through it. Returns
  the number of bytes taken — always all of them, or the failure
  raises.
- `write_byte(b)` — buffers one byte, given as a one-byte string.
- `flush()` — hands every buffered byte to the sink. The sink's own
  failure raises through unchanged.
- `buffered()` — the bytes waiting for the next flush;
  `available()` — the room left before the buffer flushes on its own.
- `reset(sink)` — flushes what is pending, then starts over on
  `sink`. Unlike Go's `Reset`, nothing is discarded: a package that
  loses data silently is not strict.

A `Writer` must be `flush`-ed before the stream ends — there are no
destructors, so the tail in the buffer belongs to the caller.

## The demo

`examples/bufio_demo` exercises the whole surface end to end —
in-memory streams, a file written through an 8-byte buffer that
really flushes, read back through two stacked readers — and its
golden output is checked byte-for-byte on the interpreter and the c
target.
