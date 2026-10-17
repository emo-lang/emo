# Step 51 — TLS on the `c` target

**Milestone:** M18 — TLS on the `c` target · **Related:** `CHECK.md` (the
settled entry), `stdlib/registry/net/0.1.0/net.emo` (the surface this
step completes), `src/emo_sched/emo_sched_det.ml` (the semantic
reference — the ocaml scheduler is the spec), `src/emo_codegen/c/
emo_c_runtime.c` (the carrier), `src/emo_cli/emo_cli.ml` (the single cc
invocation the linkage gate joins), `docs/stdlib/net.md` /
`docs/stdlib/http.md` (the limitation notes this step retires) ·
**Status:** planned — decisions settled 2026-10-17 (`CHECK.md`);
direction settled, nothing implemented.

## Why this step exists

TLS is not missing from the language. `net_tls_connect`,
`net_tls_connect_insecure` and `net_listen_tls` exist as builtins with a
fixed Emo surface (`stdlib/registry/net/0.1.0/net.emo`); the
interpreter's scheduler implements them through the opam `ssl` library
(`emo_sched_det.ml:923-990`), the standalone OCaml runtime mirrors that
implementation (`emo_ocaml_runtime.ml:3274-3351`), `typescript` maps
them onto `node:tls`, and `http`'s `https://` routes through
`net.tls_connect` in plain Emo source. What is missing is the `c`
target — the default: the three names fall out of `emo_c.ml`'s
catch-all into `emo_unsupported` and end the process with exit 70, so
`https` is dead precisely where `emo build` runs by default.

The work is conformance, not surface. The Emo source of `net` and
`http` does not move; no new builtin is named; the semantic reference
is the ocaml scheduler, byte for byte where bytes can be shared.

The user-level-FFI route was evaluated first and refused
(`CHECK.md`): `foreign` is unavailable under `emo run` (E3009) and on
`typescript`/`wasm`/`beam`/`riscv64`, the `ocaml` target's marshaling
tier cannot carry the `Int64` handles an SSL object would ride,
OpenSSL's setter surface is macro-shaped (`SSL_CTX_set_min_proto_version`
is `SSL_CTX_ctrl` underneath), and `http` cannot switch implementations
per target because Emo has no conditional compilation. Binding OpenSSL
at the FFI seam would demote a working three-target capability to a
`c`-only one. The builtins route keeps all of them.

## The shape of the work

**Linkage keys on use, not on presence.** The runtime's TLS section
compiles only under `EMO_HAS_TLS`, and the CLI defines that macro —
together with `-lssl -lcrypto` — only when the program's IR genuinely
reaches one of the three builtins. The detector is the `c` emitter's
own IR walk: a flag set at a genuine `Runtime_impl` node, never a scan
of emitted text. Without the macro the runtime references no `SSL_`
symbol at all, so a program that never touches TLS neither links nor
requires OpenSSL — the mirror image of the `sqlite3` settle (which
refused baking SQLite into the always-linked runtime), same reason,
opposite face: here the runtime is the native carrier, so the gate is a
compile-time flag rather than a package.

**The prototypes are hand-written.** No `<openssl/*.h>` include
appears anywhere, so no platform needs TLS headers: the subset of the
frozen 1.1-era client/server core is declared once in the runtime,
and the libraries are the machine's own — Linux links the distro
OpenSSL through the dev package's `-lssl`/`-lcrypto` symlinks, while
macOS has shipped no OpenSSL headers since Xcode 10 and current
releases no longer ship the `/usr/lib` TLS dylibs at all, so its
OpenSSL comes from Homebrew or similar and rides `--cclib -L<dir>`
(the settle's original no-`-L` premise was caught by this step's own
probe and corrected in `CHECK.md`). The subset is the
frozen 1.1-era client/server core, roughly fifteen functions:
`TLS_method`, `SSL_CTX_new`/`free`, `SSL_CTX_ctrl` (the min/max
protocol-version ctrl codes), `SSL_CTX_set_verify`,
`SSL_CTX_set_default_verify_paths`, `SSL_CTX_use_certificate_file`,
`SSL_CTX_use_PrivateKey_file`, `SSL_new`/`free`, `SSL_set_fd`,
`SSL_ctrl` (SNI), `SSL_set1_host`, `SSL_connect`, `SSL_accept`,
`SSL_read`, `SSL_write`, `SSL_shutdown`, `SSL_get_error`,
`SSL_get_verify_result`, `OpenSSL_version_num`/`OpenSSL_version`, and
the `ERR_*` drain. The constants (`SSL_VERIFY_*`, `SSL_ERROR_*`,
`X509_V_OK`, the ctrl codes, `TLS1_2_VERSION`/`TLS1_3_VERSION`) are
verified once against a real OpenSSL 3.x header and pinned with that
provenance in a comment. The signature risk this takes on is held by
the TLS goldens running on every CI platform.

**The floor is the API subset, not a pinned release.** OpenSSL ≥ 1.1.1,
LibreSSL ≥ 3.5.0 (`SSL_set1_host` completed its port there —
libressl/portable issue 381). The first TLS context creation reads
`OpenSSL_version_num` and refuses below the floor with the library's
own `OpenSSL_version(OPENSSL_VERSION)` string in the reason. The
discrimination between the two version-encoding schemes is T51.2's own
work; "the latest OpenSSL" (3.5 LTS at writing) is simply inside the
subset.

**A `fd → SSL*` side table stands where the ocaml conn's
`ltls : Ssl.socket option` stands.** The `c` runtime's `TcpConn`
methods are emitted as direct calls keyed on the raw fd
(`emo_net_read_line(fd)` and friends, `emo_c.ml:3105-3138`), so the
data plane routes by consulting the table: a fd that carries an SSL
goes through `SSL_read`/`SSL_write`, everything else stays the raw
`recv`/`send` path, unchanged. The table lives inside the `#ifdef`,
with an `emo_net_tls_attached(fd)` hook that answers 0 without it.

## Tasks

### T51.1 — The linkage gate: prototypes and `EMO_HAS_TLS`

The fenced TLS section in `emo_c_runtime.c`/`.h`: the hand-written
prototypes and constants above, compiled only under `EMO_HAS_TLS`;
without the macro the three names still exist, as `emo_unsupported`
bodies — today's honest refusal, unchanged. The emitter
(`emo_c.ml`) gives the three names explicit arms beside the other
`net_*` lowering (leaving the catch-all) and flips its `uses_tls` flag
at genuine `Runtime_impl` nodes, riding the flag through the emit
result. The CLI (`emo_cli.ml`, the `c` branch of `build_file`) appends
`-DEMO_HAS_TLS` and `-lssl -lcrypto` through the cclib slot — so the
conditional flags enter the build's cache key by the mechanism that
already keys cclib — and runs a pre-flight probe first: the runtime's
own TLS section compiled and linked with the TLS libraries, whose
failure renders the fix-naming message (install the OpenSSL
development files, or pass `--cclib -L…/-lssl` for custom locations
such as Homebrew's `openssl@3`) instead of raw linker output. The
probe compiles the runtime itself rather than an empty main so a
library below the fence's floor — one missing a symbol the subset
names — is caught with the same fix message. Linux uses the distro
OpenSSL, the probe catching a missing dev symlink by name; macOS
names its Homebrew location. The gate's detector is the emitter's
walk over the entry-reachable call graph: whole-module emission puts
the net package's unused surface in every net-consuming program's IR,
so flag-at-any-node would demand OpenSSL of every one of them — the
walk keeps `tcp_echo` and friends linkage-free.

Boundary pin: the c_goldens harness asserts a non-TLS build links and
runs with no `SSL_` symbol undefined (`nm` on the produced binary), so
the gate cannot silently rot into always-linked. Existing goldens stay
byte-identical — they are the proof that non-TLS builds are untouched.

### T51.2 — The client handshake (`net_tls_connect`)

The TCP leg reuses the existing `emo_net_connect` path (nonblocking
socket, timeout); the handshake then runs `SSL_connect` in a
nonblocking loop, parking the fiber on `WANT_READ`/`WANT_WRITE` — a
wait-writable hook joins `emo_net_wait_readable` (`emo_c_runtime.c`
:2440-2444) and the scheduler's poll loop gains the POLLOUT arm.
Setup per the ocaml scheduler (`client_tls_ctx`, `emo_sched_det.ml`
:930-937): `TLS_client_method`, the TLS 1.2–1.3 window via
`SSL_CTX_ctrl`, `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`,
`SSL_CTX_set_default_verify_paths` (so `SSL_CERT_FILE`/`SSL_CERT_DIR`
ride along), SNI from the connect hostname (`SSL_ctrl`), hostname
verification via `SSL_set1_host` plus
`SSL_get_verify_result == X509_V_OK`. Errors drain through
`ERR_error_string_n` under the reason prefix the ocaml side prints —
`the TLS handshake with <host>: `. On success the conn fd registers in
the side table.

Fixtures: the existing self-signed pair
(`test/emo_sched/fixtures/tls-{cert,key}.pem`) stays for the
verify-fail and insecure pins; a small CA plus a server certificate
(SAN: `localhost`, `127.0.0.1`) joins it, and a scheduler-level test
drives a verified loopback handshake by pointing `SSL_CERT_FILE` at
the CA — the ocaml-ssl path honors it through OpenSSL's default verify
paths, so the same fixture serves the interpreter and, from T51.5, the
`c` binary.

### T51.3 — The data plane and the insecure variant

`emo_net_read_line` / `read_exactly` / `read_all` / `write` branch on
`emo_net_tls_attached(fd)` into `SSL_read`/`SSL_write` loops with the
same parking discipline as the handshake; `close()` runs
`SSL_shutdown` (best effort), then `SSL_free` and the context free,
and clears the table. `set_timeout` on a TLS conn matches the ocaml
conn's semantics: a socket timeout surfacing through `SSL_read` maps
to the same reason shape the raw path prints for a timed-out read.
`net_tls_connect_insecure` is the whole path of T51.2 with verification
off — the ocaml `set_verify []` shape — sharing everything else.

### T51.4 — The server side (`listen_tls`)

`net_listen_tls(host, port, cert_path, key_path)` loads the PEM pair
into a server context (`SSL_CTX_use_certificate_file` /
`SSL_CTX_use_PrivateKey_file`), refusing with the ocaml-matching
`cannot load the TLS certificate for <host>:<port>` shape when the
files are missing or rejected, and registers the listener fd → context
in a second table. `accept` on such a listener performs the server
handshake (`SSL_accept`, parking as the client loop does) and
registers the conn before returning it, so the ocaml scheduler's
`tls_listener` shape is met. The loopback test pairs this with T51.2:
an Emo TLS echo server and an Emo TLS client in one program on
`127.0.0.1:0`, on the interpreter and on `c`.

### T51.5 — The goldens

`examples/https_roundtrip`: an `http.request` over `https://` served
by the harness's captive TLS server (ocaml-ssl, the fixture
certificate, `SSL_CERT_FILE` at the CA) — following the
`http_roundtrip` pattern, its `expected.txt` taken from the
interpreter and asserted byte-identical on `c`, registered in the
c_goldens list (`emo_cli_test.ml:552-593`). The standalone OCaml
runtime gains its own TLS roundtrip test
(`test/emo_ocaml_runtime/emo_ocaml_runtime_test.ml` next to the net
group) — that path implements TLS but had no test of it.

### T51.6 — Docs

`docs/stdlib/net.md`: the TLS limitation note ("`c` implements TCP
only") becomes the implemented story — ocaml-ssl on `ocaml`, node:tls
on `typescript`, the system OpenSSL/LibreSSL on `c`, with the version
floor stated; `docs/stdlib/http.md`: the "`https` needs TLS, which `c`
refuses" note retired; the zh-CN mirrors
(`docs/zh-CN/stdlib/{net,http}.md`) follow. `CHECK.md` already carries
the settle; the gates table and `plan/README.md`'s status table are
updated in the same pass.

## Left open, deliberately

- **Windows.** TLS follows the `c` target's own platform support
  (macOS/Linux); no Schannel route is scheduled, and the refusal on
  unsupported platforms stays the honest `emo_unsupported`.
- **Custom CA parameters, client certificates, ALPN.** None can land
  on one target alone — each is a surface addition the interpreter,
  the standalone OCaml runtime and `c` must take in the same commit.
  Deferred until a requirement names them.
- **Handshake-internal message wording.** A library-produced failure
  message is ocaml-ssl's wording on the interpreter side and OpenSSL's
  on `c` — byte parity there is not achievable and not pretended; the
  convention pins the prefix and the shape, and the goldens assert
  exactly that much (T51.2). The runtime-manufactured reasons
  (timeouts, unloadable certificates, closed connections) remain held
  to full byte parity, per the step-37 discipline.

## Acceptance

- An `https://` request runs end-to-end on the `c` target against the
  captive TLS server, its output byte-identical to the interpreter's
  `expected.txt` (`examples/https_roundtrip`).
- The verified handshake (`SSL_CERT_FILE` → the fixture CA), the
  verify-fail pin, the insecure roundtrip, and the server-side TLS
  echo are green on the interpreter and on `c`.
- A non-TLS `c` build neither links nor requires OpenSSL — the `nm`
  pin holds — and every existing golden on every target stays
  byte-identical.
- The runtime-manufactured reason strings are byte-identical across
  interp / `c` / the standalone ocaml runtime; the
  handshake-internal ones agree on the `the TLS handshake with <host>:
  ` prefix, by design.
- A program below the library floor (or without OpenSSL installed) is
  refused with the library's version string or the fix-naming linkage
  message, never raw toolchain output.
- `dune build @fmt` clean and `dune test --force` green.
