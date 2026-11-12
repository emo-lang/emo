# The `playwright` package

A Playwright client in pure Emo: browser automation over the driver's
channel protocol, spoken to the official `playwright run-server`
through the `websocket` package. Direct style on the net surface —
every call parks the process on the scheduler like any other socket
work. The wire never raises on driver data: a refused call is the
value `(R.error, "playwright: " + the driver's text)`, a wire failure
the value with the websocket or net reason, and only a caller's own
mistake raises.

```emo
playwright.connect(host, port, timeout)            // (R, Playwright) — chromium
playwright.connect_with(name, host, port, timeout) // (R, Playwright) — firefox, webkit
pw.browser()        // Browser — the one the server pre-launched for this connection
pw.close()          // (R, Playwright) — hang up; the server takes the browser down

browser.new_page()  // (R, Page)
browser.version()   // (R, String)
browser.close()     // (R, Browser)

page.goto(url)      // (R, PageResponse) — is_null?(), then status() and url()
page.click(sel)     // (R, Page)
page.fill(sel, t)   // (R, Page)
page.press(sel, k)  // (R, Page)
page.title()        // (R, String)
page.content()      // (R, String)
page.text_content(sel)  // (R, Text) — is_null?(), then as_string()
page.screenshot()   // (R, Bytes) — a PNG, decoded out of the driver's base64
page.close()        // (R, Page)
```

Targets: `["ocaml", "c", "typescript"]` (it builds on `websocket`,
`json`, and `base64`). Reference:
[`docs/stdlib/playwright.md`](stdlib/playwright.md) · Demo:
`examples/playwright_demo`.

## Using the package

`require "playwright"`, with the package pinned in your manifest:

```emo
deps {
  "websocket" = "0.1.0"
  "playwright" = "0.1.0"
}
```

## Connecting

Start a driver first — the package is a client:

```sh
npx playwright run-server --port 9933
```

Then `playwright.connect("127.0.0.1", 9933, 5.0)`. The run-server
launches the browser when the connection arrives and hands it over
pre-launched — the browser name rides the endpoint's `?browser=`
query parameter (`connect_with("firefox", ...)` sends
`/?browser=firefox`), and the client never launches anything itself.
The initialize handshake pins the root Playwright channel and the
pre-launched browser out of the objects the driver introduces on the
way; after it answers, `pw.browser()` is ready. The timeout bounds
each exchange; `0.0` waits indefinitely.

## The doors

Every wait-on-the-page door carries its budget in the call's
metadata — the driver's 30000 ms default, the field the driver
actually reads for its per-call deadline (a metadata with no timeout
is no deadline at all: a selector the page never meets would hold
the driver's answer forever).

`goto` answers the response the navigation earned — its `status()`
and `url()` — or the null response when the navigation earns none
(`about:blank`, a data url); `is_null?()` tells the two apart,
json's reading. `text_content` answers a `Text`: an element the
selector does not match is not an error, it is the null text read
through `is_null?()` — valkey's null reply with the same reading.
`click`, `fill`, and `press` answer the page back so doors chain
visibly; a selector or key the caller left empty is a caller's
mistake and raises.

`screenshot()` asks for a PNG and decodes the driver's base64 answer
into `Bytes`. On `typescript` the base64 package's own String carrier
applies to the decoded form: a PNG is arbitrary bytes, so the honest
read of a screenshot on that target is through `Bytes` from an exact
alphabet — base64 is exact by construction, and the decode is byte
exact on `ocaml` and `c`.

## Errors

The three-way split, valkey's rule: the driver refusing a call is
`(R.error, "playwright: " + the driver's message)` (the dispatcher's
own wrapping is unwrapped); the wire failing — a deadline, a close,
the server gone — is the value with the websocket or net reason; a
caller's mistake raises. The engine never raises on driver data: a
malformed message is a reason, not a crash.

## Example

`examples/playwright_demo` runs the whole surface against this repo's
own miniature driver — a fake `run-server` that answers the real wire
shapes over real websocket frames, fragmented messages and a ping and
the eight-byte length form included, so the golden needs no browser
and no Node. The golden pins the round trip byte for byte.

`examples/playwright_live` is the live check: a real `run-server`
driving a real headless chromium against a local page this program
serves itself through `httpd` — version, navigation, title, DOM
text, a screenshot, the timeout error a missing selector earns. It
is in no golden list (it needs the install and a driver running) and
runs by hand; the driver it was verified against is recorded in
`CHECK.md`.

## Limitations

- Three targets: the same gate `websocket` rides.
- The driver's protocol is the driver's own, not a published
  standard; this package tracks the wire as the driver speaks it and
  states what it was verified against rather than promising a
  version forever. **Verified live against playwright 1.65.0
  (chromium 158.0.8127.18, macOS arm64), the whole ladder on the `c`
  target.** What is pinned here: the run-server pre-launch shape
  (`denyLaunch`), the `?browser=` selection, the initialize
  handshake on the root channel, the context-then-page dance for
  `new_page` (the browser channel has no page door of its own), the
  metadata-borne per-call deadline, and the door methods above.
- The driver's server answers a WebSocket accept that does not
  derive from the client's key (its own client never validates it),
  so the dial goes through `websocket.connect_insecure` — the
  protocol's proof here is the initialize handshake itself.
- Events the driver emits (navigations, loads, console) are absorbed
  or skipped; v1 has no event doors. `__create__` and `__dispose__`
  are handled — the object table rides on them.
- No contexts, no locator semantics, no `evaluate`, no
  screenshots-as-files, no downloads, no tracing. The doors above
  are the whole surface.
- The typescript caveat above rides `base64.decode`'s own carrier.
