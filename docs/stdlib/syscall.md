# The `syscall` Package

The EmoOS gate's user side: the typed Emo surface over the machine's raw
`ecall`, and the only thing a user program sees of the kernel boundary.
This is not the hosted `os` — it answers to the EmoOS kernel, and it
admits the `riscv64` target alone (`targets = ["riscv64"]`). The ABI
contract — the crossing, the validation, and the answer convention —
is the kernel's [`projects/emo-os/docs/syscalls.md`](../../projects/emo-os/docs/syscalls.md);
this page covers the package's names and what each answers.

Targets: `["riscv64"]`.

## Using the package

```emo
require "syscall"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "syscall"` needs
`"syscall" = "0.1.0"` in the manifest's `deps` block. Build the image
with `emo build --target riscv64`; every other target refuses the
package at resolution, and the interpreter refuses the `ecall` builtin
it rides.

## The answer convention

The kernel answers in one register: `>= 0` is the payload, `< 0` the
refusal's reason. Every fallible door wraps that in the standard
library's tuple — `(R.ok, payload)` or `(R.error, reason)` — with
`why_of` naming the reason:

| Answer | Reason text |
| --- | --- |
| `-2` | `outside the caller's memory` |
| `-3` | `not writable` |
| `-4` | `bad argument` |
| `-5` | `the kernel is out of a resource` |
| `-6` | `no such file` |
| anything else | `unknown verb` |

A refusal is an answer, not a fault: the caller's registers are intact
and execution resumes. Two doors are not fallible this way — `read`
and `input_read` return the raw `Int64` — and `exit` never returns.

Buffers are raw addresses in the calling program's own memory, and the
gate checks them before it reads or writes: a buffer outside the
program's segments is `outside the caller's memory`, one without the
needed permission is `not writable`.

## Process and console

```emo
def exit(code Int64) Void                       // verb 0
def write(buf Int64, len Int64) (R, Int64)      // verb 1
def read() Int64                                // verb 2
def input_read() Int64                          // verb 12
def spawn() (R, Int64)                          // verb 3
def wait(pid Int64) (R, Int64)                  // verb 4
def exec(name Int64, name_len Int64) (R, Int64) // verb 24
def exec_args(name Int64, name_len Int64, args Int64, args_len Int64) (R, Int64)                 // verb 48
def exec_args_env(name Int64, name_len Int64, args Int64, args_len Int64,
                  env Int64, env_len Int64) (R, Int64)                                           // verb 48
def execve(name Int64, name_len Int64, args Int64, args_len Int64,
           env Int64, env_len Int64) (R, Int64)                                                  // verb 54
```

- **`exit`** ends the calling process. The root's exit ends the
  machine; a spawned process's exit answers its parent's `wait`. Never
  returns.
- **`write`** sends the `len` bytes at `buf` to the kernel's console
  and answers the byte count. The gate stages at most 2048 bytes.
- **`read`** answers the next console byte (0–255), blocking until one
  exists.
- **`input_read`** answers the next event of the machine's merged input
  stream, blocking until one exists. The event is packed into one word:
  the type in bits 48–63 (0 the separator, 1 a key, 2 a relative move,
  3 an absolute move, `0x454D` the machine's byte event), the code in
  bits 32–47, the value in bits 0–31. The stream merges the
  virtio-input device with the serial console's bytes, the bytes first;
  one reader at a time.
- **`spawn`** starts a new process at this program's top level on a
  fresh stack; the image's constants are its constants, so the first
  process's constant is how the child knows it is the child. Answers
  the child's pid number.
- **`wait`** blocks until the named child exits — pid `0` or a negative
  number means the first of the caller's children — and answers the
  child's status word. The wire packs the child's pid above the status;
  the wrapper masks it to the low 32 bits, so the status is the exit
  code above the low byte for an exit, the signal's number for a signal
  death.
- **`exec`** loads the ELF named by the `name_len` bytes at `name` from
  the volume as its own image and process; answers the child's pid
  number.
- **`exec_args`** is `exec` with the line's arguments: the args text
  (at most 512 bytes, split at spaces) lands on the child's first stack
  as `argv[1..]`, with `argv[0]` the name.
- **`exec_args_env`** adds the environment text on the same staging
  page.
- **`execve`** replaces the caller's image in place: the caller keeps
  its pid and becomes the new image. Never returns on success.

## Files

Files are whole files by name: the name is 1–24 bytes at `name`, with
no NUL and no newline.

```emo
def file_write(name Int64, name_len Int64, buf Int64, len Int64) (R, Int64)   // verb 6
def file_read(name Int64, name_len Int64, buf Int64, cap Int64) (R, Int64)    // verb 7
def file_list(buf Int64, cap Int64) (R, Int64)                                // verb 8
def list_dir(name Int64, name_len Int64, buf Int64, cap Int64) (R, Int64)     // verb 45
def file_remove(name Int64, name_len Int64) (R, Int64)                        // verb 9
```

- **`file_write`** makes the file the `len` bytes at `buf` (at most
  2048), replacing one of that name; answers the count.
- **`file_read`** lands the file's bytes at `buf`, at most `cap` of
  them, and answers the file's size — a size past `cap` says the buffer
  was short.
- **`file_list`** lands the names, each followed by a newline, and
  answers the bytes written.
- **`list_dir`** lands the named directory's immediate children — a
  type byte (0 file, 1 directory), a length byte, and the name — and
  answers the bytes written. The root is the empty name.
- **`file_remove`** deletes the file and answers 0.

A name no file holds is `no such file`; a full disk or name table is
`the kernel is out of a resource`. A request made while the filesystem
service is between one instance and the next waits for the next.

## The clock

```emo
def time() (R, Int64)   // verb 29
```

Seconds since the Unix epoch, UTC, read from the board's goldfish RTC
by the gate itself. The gate never refuses this verb.

## The desktop protocol

The compositor's surface, negotiated by `desktop_version` — one word,
`1`, the protocol verbs 10–35 carry.

```emo
def desktop_version() (R, Int64)                                  // verb 23
def win_frame() (R, Int64)                                        // verb 22
def present(grant Int64, x Int64, y Int64, w Int64, h Int64) (R, Int64)   // verb 10
def output_info(index Int64) (R, Int64)                           // verb 11
def input_info(index Int64) (R, Int64)                            // verb 18
```

- **`desktop_version`** anchors the negotiation; additions to the verb
  set never move the word.
- **`win_frame`** parks the caller and answers the next composition's
  completion — the frame pulse an animation paces itself by. Virtio-gpu
  has no vblank; the composition is the machine's pulse. A ring of four
  parks full is `the kernel is out of a resource`.
- **`present`** commits the buffer the grant names: the damage rect
  `(x, y, w, h)` is what the device takes and what the scanout shows,
  and the transfer and flush complete before the answer. Grant id 0 is
  the screen carve's; the caller must be the holder the kernel's
  authorization table names.
- **`output_info`** answers the `index`-th output's rectangle, packed
  width in bits 32–63 and height in bits 0–31.
- **`input_info`** answers the `index`-th pointer's axis maxima, packed
  X in bits 32–63 and Y in bits 0–31 — the range an absolute report
  scales to the display by.

### Window buffers

```emo
def win_new(w Int64, h Int64) (R, Int64)            // verb 13
def win_close(grant Int64) (R, Int64)               // verb 14
def win_focus(grant Int64) (R, Int64)               // verb 15
def win_move(grant Int64, x Int64, y Int64) (R, Int64)        // verb 16
def win_role(grant Int64, role Int64) (R, Int64)    // verb 17
def win_parent(grant Int64, parent Int64) (R, Int64)          // verb 19
def win_format(grant Int64, format Int64) (R, Int64)          // verb 20
def win_scale(grant Int64, scale Int64) (R, Int64)            // verb 21
def win_shape(grant Int64, radius Int64, softness Int64) (R, Int64)   // verb 33
def win_minimize(grant Int64) (R, Int64)            // verb 25
def win_desk_open(pid Int64) (R, Int64)             // verb 26
```

- **`win_new`** allocates the window buffer and maps it into the
  caller's table at the identity of its physical addresses. The answer
  packs the base's frame number in bits 32–63 and the grant id in bits
  0–31; the byte address to paint is the frame number shifted left by
  12, and the grant id is what the other window doors name the buffer
  by.
- **`win_close`** releases the run to the allocator and drops the
  grant.
- **`win_focus`** names the window the compositor routes input to.
- **`win_move`** sets the position the composition blits the window's
  frame at. The x rides the blit's word granularity (even), and the
  bounds against the display's mode are the compositor's to judge.
- **`win_role`** declares the surface's role: `0` toplevel, `1` popup,
  `2` subsurface, `3` panel, `4` wallpaper. The vocabulary is frozen,
  and every role is implemented: toplevel is free-standing, popup and
  subsurface are parent-relative (`win_parent` binds the parent), panel
  is the walk's topmost strip, and wallpaper is the desktop's canvas
  under every window (the machine holds one). A buffer with no role
  meets `bad argument` at every surface verb, as does a second
  declaration for one surface and a second wallpaper; `win_focus` on the
  wallpaper is refused too. A full stack is `the kernel is out of a
  resource`.
- **`win_parent`** binds a popup or subsurface to the toplevel it hangs
  from: its position becomes the parent's, its own coordinates
  relative, and the parent's death takes it too. The caller must own
  both grants. A role that takes no parent (toplevel, panel) is
  `bad argument`.
- **`win_format`** records the pixel format the caller painted:
  XRGB8888 (`0`) is the first accepted value and ARGB8888 (`1`) the
  second — the walk composites an ARGB row per pixel, source-over, with
  the buffer's alpha bytes the shape. A format the compositor does not
  carry is refused by its number.
- **`win_scale`** sets the scale the compositor honors when it carries
  the buffer: a whole number past one carries it at that multiple,
  nearest neighbor; a scale below 1 is `bad argument`, and so is a
  scale on an ARGB row (the blend and the scaling are not yet one
  walk).
- **`win_shape`** sets the radius and softness the compositor's mask
  and shadow wear; an unset row carries the toplevels' `10` and `16`.
  Zero radius is the bare rectangle every other role wears (words' own
  meaning: a toplevel stripped, a panel shaped), and zero softness is
  the mask without the ring. A value past 255 is `bad argument`. It
  binds at its declaration; a second call is the argument refusal.
- **`win_minimize`** takes the toplevel off the compositor's walk,
  keeping its entry (position and grant) for the restore. A grant that
  is no toplevel, or one already hidden, is `bad argument`.
- **`win_desk_open`** is the desktop's open: the window owned by that
  pid is raised and focused, unhidden first if hidden. The caller must
  own a panel — the desktop's strip is the authority, not the window's
  ownership.

### Workspaces and the notification service

```emo
def win_workspace(grant Int64, desk Int64) (R, Int64)   // verb 30
def desk_show(desk Int64) (R, Int64)                    // verb 31
def desk_workspace() (R, Int64)                         // verb 32
def notify(title Int64, tlen Int64, body Int64, blen Int64) (R, Int64)   // verb 27
def notify_take(buf Int64, cap Int64) (R, Int64)        // verb 28
```

- **`win_workspace`** moves the caller's toplevel to another desk; the
  desk's bounds are `0..3`, and the walk paints the window only on the
  desk it now names.
- **`desk_show`** is the shell's switch: the named desk's windows come
  onto the display, the outgoing desk's focus remembered and the
  incoming desk's restored. The caller must own a panel.
- **`desk_workspace`** answers the packed desk word — the active desk in
  the low byte, the occupancy mask above it, a bit set while a live
  toplevel carries the desk.
- **`notify`** queues a notification: the title is 1–64 bytes at
  `title`, the body 0–192 bytes at `body`. The service holds eight
  raised and not yet taken; a full queue is `the kernel is out of a
  resource`, for the caller to retry once the shell has drained.
  Answers the notification's id (1 or more).
- **`notify_take`** lands at most one packed notification at `buf`: the
  24-byte head first (id at 0, title length at 8, body length at 16),
  then the title and body bytes; answers the packed size. An empty
  queue answers 0. The first taker becomes the notification center's
  owner, and every later taker with another pid is `not writable`.

## The clipboard

```emo
def clip_set(buf Int64, len Int64) (R, Int64)   // verb 34
def clip_get(buf Int64, cap Int64) (R, Int64)   // verb 35
```

- **`clip_set`** replaces the clipboard with the `len` bytes at `buf`;
  `len` 0 clears it, and a `len` past the clipboard page's 4096 is
  `bad argument`. The writer must be the focused surface's owner —
  the app the copy key reaches — so a background caller is
  `not writable`. The gate copies inside the trap, so the clipboard
  never holds half a selection.
- **`clip_get`** lands as many of the clipboard's bytes as fit at `buf`
  (at most `cap`) and answers the count. Reading is any process's.

## Example

The desktop's own programs are the worked examples:
`projects/emo-desktop/fb/apps/files/main.emo` opens a window, paints a
buffer with `present`, and reads the input stream with `input_read`;
`projects/emo-desktop/fb/winbuf/` holds the full compositor client.
