# Step 64 — Browser automation: `websocket`, then `playwright`

Two packages land together because the second rides the first: the
RFC 6455 halves as a stdlib package over `net`, then the Playwright
client speaking the driver's channel protocol through those frames.

## Why this shape

The `os` package has no `dup2`, so a child's stdin/stdout cannot be
wired to pipes — the `run-driver` stdio transport other language
clients use is unreachable from Emo code. What the surface does have:
`net`'s TCP with per-operation deadlines, `json`, `base64`,
`crypto.legacy.sha1`, and `rand`. The driver itself offers a
WebSocket endpoint (`npx playwright run-server`), and that endpoint
speaks the same channel protocol the pipe does. So: a WebSocket
client in pure Emo becomes the `websocket` package (both halves — a
stdlib that can dial but not take would be half a transport), and
`playwright` depends on it.

## The wire, as pinned

- One JSON document per text frame. A command is
  `{id, guid, method, params, metadata}`; an answer is
  `{id, result}` or `{id, error}`; an event is
  `{guid, method, params}`.
- `__create__` (params `{type, guid, initializer}`) and `__dispose__`
  maintain the client's object table; every other event is skipped —
  v1 has no event doors.
- An object reference rides as `{guid}`; binary rides as base64 text.
- The handshake: the client speaks first — `initialize` on the root
  channel (`guid: ""`, params `{sdkLanguage: "javascript"}`) — and
  the run-server has already launched the browser for the connection
  (`denyLaunch`): the browser's guid arrives inside the Playwright
  object's initializer as `preLaunchedBrowser`. The client never
  launches.
- The browser name rides the endpoint's `?browser=` query parameter;
  the endpoint path defaults to `/`.
- A `User-Agent` shaped `Playwright/x.y` triggers the server's
  version gate (HTTP 428 on mismatch); the package's agent string
  (`emo-playwright/0.1.0`) does not match that shape and is let
  through.
- Page actions route to the page's main frame channel (the Page
  initializer names it); `screenshot` and `close` are Page-channel
  methods; `newPage` is a Browser-channel method.

## The packages

- `stdlib/registry/websocket/0.1.0` — one file, both halves. The
  client's header walk reads the answer to the blank line before
  verifying the accept, so no handshake byte leaks into the frame
  stream. Frames: all three length forms, masking strictly by role,
  fragmentation joined on receive, pings answered, closes answered.
- `stdlib/registry/playwright/0.1.0` — the facade plus
  `internal/channel.emo` (the JSON pump, the id ledger, the guid
  table, the null-safe field readers). Errors per the house split:
  driver refusals are `(R.error, "playwright: " + text)` with the
  dispatcher's wrapping unwrapped; wire failures keep the websocket
  or net reasons; caller mistakes raise.

## The demos

Both demos carry their own counterparty so the goldens need no
browser and no Node:

- `websocket_demo` — an echo server through `websocket.accept`, the
  client through `websocket.connect`: multi-byte, 70000 bytes (the
  two-byte length form), the goodbye.
- `playwright_demo` — a miniature driver answering the run-server
  shapes over raw frames: the initialize object group, a skipped
  event, the page create with its main frame, a fragmented
  70013-byte document, a ping the client must answer (the driver
  reads the masked pong back), a 120000-char screenshot reply riding
  the eight-byte length form, both dispatcher error shapes, the
  goodbye.

## Found on the way

- **The c backend refused every C-keyword-named method.** The
  emitter's method call looked the reserved-word-escaped name
  (`goto_c`) up against the IR's plain name and fell through to the
  refusal; `Page.goto` was the first method in the repo to carry a
  reserved word. Fixed: the lookup accepts both spellings and the
  emitted call names itself off the matched declaration, the same
  way the declaration did.
- **The driver's server answers a non-RFC WebSocket accept** (not derived
  from the client's key; its own client never validates), so `websocket`
  grew the named `connect_insecure` door and `playwright` dials through
  it, the initialize handshake standing as the protocol proof.
- **`Browser.newPage` does not exist in this driver generation** — a page
  is `newContext` then `newPage` on that context; the facade does the
  two-hop dance.
- **The per-call deadline rides `metadata.timeout`** — the official client's
  params carry no timeout at all; without the metadata budget a missing
  selector holds the driver's answer forever. The doors send the official
  shape (30000 ms on page doors, 0 on structural calls).
- **The det interpreter's parked read breaks during a held-open call**
  (EBADF on the next read; the c runtime runs the identical ladder
  byte-green) — found-not-fixed, the live check records its run on c.
- **The json package's escape-length walk recurses per character.**
  `quoted_len` is a plain recursion over the string's bytes, so a
  120000-char `json.encode` rides 120000 stack frames — past the c
  target's fiber stack (the interpreter survives it). Found-not-
  fixed; the demo hand-assembles its one large reply around it, and
  the package's own encode calls are all small.

## Verification

`examples/websocket_demo` and `examples/playwright_demo` byte-
identical across three interpreter runs and the `c` binaries; both
demos in the lockfile suite (`test/emo_project/emo_project_test.ml`)
and in `c_goldens`; `dune runtest` green; `@fmt` clean. The live
check (`examples/playwright_live`) ran the whole ladder against
playwright 1.65.0 / chromium 158.0.8127.18, green on the `c` target.
