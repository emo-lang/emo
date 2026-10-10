# The `file` Package

The standard library's direct-style file IO: read a whole file in one
call, write one in another. The calls run on the scheduler, so a slow
disk parks the calling process instead of the whole program — the
same direct style the `net` package uses for sockets.

## Using the package

```emo
require "file"
```

A `require` pairs strictly with the manifest: `file` must be pinned in
`package.emo`:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    file = "0.1.0"
  }
}
```

## The surface

```emo
def read(path String) String
def write(path String, contents String) Int64
```

`read` answers the file's bytes. A missing or unreadable file raises
an ordinary Emo exception whose message names the path and the
reason — `cannot read notes.txt: No such file or directory`.

`write` creates or truncates the path, writes every byte of
`contents`, and answers how many were written — always all of them,
or the failure raises. Unwritable paths raise the same way.

## Paths

Paths are taken as given: a relative path resolves against the
process's working directory, which `os.getcwd` reads and `os.chdir`
moves. `file` does no path normalization and no permission checks of
its own — what the kernel says, the exception says.

## When to reach lower

`file` is the one-shot shape: whole file in, whole file out. Anything
streamed, appended, or buffered goes through `os`'s raw descriptors
(`open_read`, `open_write`, `open_append`, `read`, `write`, `close`)
with `bufio` in front when buffering helps.

## Targets

`["ocaml", "c"]` — the targets with a Unix-shaped host. The demo
(`examples/file_read`) writes a file, reads it back, overwrites it,
and checks the round-trip; its golden output is checked byte-for-byte.
