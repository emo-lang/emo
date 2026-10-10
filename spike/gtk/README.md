# Linux GTK spike

The second GUI feasibility spike. The macOS spike asked whether a
native GUI is reachable at all; this one asks a sharper question: the
macOS shim was forced by Objective-C (headers, per-signature msgSend
casts, ARC bridges) — **how much of that binding layer is inherent,
and how much was accidental?** GTK 4 is plain C, so the direct-call
path can be measured.

## Run

```sh
./docker-e2e.sh      # anywhere with Docker: compile, link, and run
                     # inside Linux (ubuntu:24.04 + Xvfb), autotest
                     # clicks a real button and prints the result
./build.sh           # on a machine with GTK 4 installed
EMO_GUI_AUTOTEST=1 ./gtk-spike
```

No compiler changes beyond the ones the macOS spike already landed
(Void foreign returns, `emo_defs.h`, content-keyed cclib cache).

## The answer: the shim shrinks from 192 lines to ~100, and the direct layer appears

- **Direct `foreign def` calls, no shim** — `gtk_init`, `gtk_window_new`,
  `gtk_window_set_title`, `gtk_window_set_default_size`,
  `gtk_fixed_new`/`gtk_fixed_put`, `gtk_button_new_with_label`,
  `gtk_label_new`, `gtk_label_set_text`, `gtk_button_get_label`,
  `gtk_window_set_child`, `gtk_window_present`, plus GLib's
  `g_main_loop_new`/`g_main_loop_run`: thirteen calls straight from
  Emo. Widget pointers ride pointer-sized Int64s; strings cross both
  directions as `const char *`.
- **The shim keeps exactly three jobs**: (1) the signal handler —
  `g_signal_connect` takes a function pointer, which Emo cannot
  produce, so the handler externs `main__on_click` and forwards
  GObject's own `user_data` as the per-connection handle (the
  userdata slot the interface-and-userdata callback design
  anticipates); (2) C `int` **returns** — a 32-bit return leaves the
  upper half of the register undefined, so `gtk_widget_get_width` gets
  a widening wrapper (parameters are safe, returns are not — the
  first concrete validation of the `Int32` item in
  `docs/numeric-width.md`); (3) the self-driving autotest.
- **No structs on the common path** — GTK4's migration from
  struct-returning getters (GTK3's `gtk_widget_get_allocation`) to
  scalar functions means the whole demo never marshals a struct.
- **Callbacks unchanged from macOS** — state through the callback's
  signature (count in, new count out), the handle through
  `user_data`.

## Findings

1. **The macOS binding layer was ~2/3 accidental.** ObjC forced the
   creators, the msgSend vocabulary, and the ARC bridges; against C
   GTK those become direct Emo calls. What remains inherent is
   function-pointer callbacks, non-64-bit returns, and varargs —
   exactly the list the language roadmap already tracks.
2. **GTK 4 removed the classic main loop from the library.** Verified
   in 4.14 (Ubuntu 24.04): `gtk_main`/`gtk_main_quit` are neither
   declared in the headers nor exported by `libgtk-4`; only
   `gtk_init` survives. The loop is GLib's, and Emo direct-calls
   `g_main_loop_new`/`g_main_loop_run` while the shim quits it.
3. **The direct-call externs and the library's headers cannot share a
   translation unit.** `emo_defs.h` declares the FFI view of every
   foreign symbol (`int64_t` handles); gtk.h declares typed
   prototypes for the same symbols — include both and cc rejects the
   redeclarations. The macOS spike never met this because its
   vocabulary shim declares no AppKit symbols; a direct-call shim has
   to hand-declare the one Emo callback instead, giving up the
   compile-time signature check on it. A defs variant without the
   foreign declarations would restore the check.
4. **`int`-returning getters are a silent-corruption hazard.** Declared
   `Int64` they compile and link fine, then return garbage in the
   upper half. Nothing warns today; the options are shim wrappers
   (this spike), an `Int32` foreign type (numeric-width schedule), or
   a lint that refuses suspected-narrow returns.
5. **C `double` parameters are the same trap with a sharper edge.**
   GTK 4.12 moved `GtkFixed` to double coordinates; declared `Int64`,
   the spike's first build compiled, linked, and drew garbage — an
   integer argument travels in an x register while the callee reads
   the v register, a wrong-register-class read invisible to the
   linker, to cc (cross-TU), and to the checker. Declaring the
   parameters `Float64` — which the FFI table already carries — needs
   no shim; the trap exists only while the declaration lies. The
   screenshot pipeline (Xvfb + `xwd`) caught it; the autotest, which
   only reads back text and width, did not.
6. **`int64_t` is `long` on Linux and `long long` on macOS.** The
   shim's first draft defined its defs-matching functions as
   `long long` — correct on macOS, rejected by the container's cc
   against `emo_defs.h` on the first build. The header contract
   caught a real portability bug on first contact.
7. **`GtkFixed` coordinates run top-left** (AppKit ran bottom-left) —
   layout numbers are not portable across toolkits; they belong in
   the Emo layer per toolkit, which is where the spike keeps them.
8. **pkg-config flags pass through `--cclib` verbatim** —
   `--cclib="$(pkg-config --libs gtk4)"` is one `-`-prefixed value the
   shell splits for cc; the content-keyed cache covers it.

## Status

Spike only — the container image (`emo-gtk-build`, built from
`Dockerfile`) is local. The `emo` binary defaults to
`../../_build/default/src/emo_cli/emo.exe`; override with `EMO=...`.
