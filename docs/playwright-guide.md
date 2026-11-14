# Getting Started with `playwright`

Driving a real browser from Emo: start the driver, connect, open a page,
read the DOM. Every step below is a working program.

One point shapes everything else: **Emo does not launch the browser.** The
`playwright` package is a pure client — it speaks the driver's channel
protocol over websocket to the official `playwright run-server`. The driver
launches the browser during the handshake and hands it over as
`preLaunchedBrowser` in the initialize answer (the server runs in
`denyLaunch` mode), so the client never launches anything itself.

## 1. Start a driver

```sh
npx playwright run-server --port 9933
```

The engine is chromium by default. To pick another:

```sh
npx playwright run-server --port 9933 --browser firefox
```

## 2. Add the packages

`require "playwright"`, with the manifest pinning exact versions:

```emo
deps {
  "playwright" = "0.1.0"
  "dom" = "0.1.0"        // only needed to query the DOM with CSS selectors
}
```

`emo deps add dom 0.1.0` pins the new package into `package.emo` and writes
`package.lock`.

## 3. The session flow

`connect → browser() → new_page() → goto → read → close`

1. `playwright.connect("127.0.0.1", 9933, 30.0)` dials the driver and runs the
   initialize handshake, answering `(R, Playwright)`. The browser name rides
   the `?browser=` query parameter; for another engine use
   `connect_with("firefox", host, port, timeout)`.
2. `pw.browser()` hands back the Browser the driver pre-launched. It makes no
   call — the object is already there.
3. `browser.new_page()` opens a page: `newContext` on the browser first, then
   `newPage` on that context (the browser channel has no page door of its own).
4. `page.goto(url)` answers the `PageResponse` the navigation earned;
   `is_null?()` says the navigation earned none (`about:blank`, a data url).
5. Read the DOM — next section.
6. Close: `page.close()`, then `pw.close()`. **Do not call
   `browser.close()`**: `pw.close()` hangs up the connection and the server
   takes the browser down with it.

```emo
require "dom"
require "playwright"

case playwright.connect("127.0.0.1", 9933, 30.0) {
  (R.error, why) -> { println("connect: ${why}") }
  (R.ok, pw)     -> {
    const browser = pw.browser()
    case browser.new_page() {
      (R.error, why) -> { println("new_page: ${why}") }
      (R.ok, page)   -> {
        case page.goto("https://example.com") {
          (R.error, why) -> { println("goto: ${why}") }
          (R.ok, resp)   -> {
            if !resp.is_null?() {
              println("${resp.status()} ${resp.url()}")
            }
          }
        }
        case page.content() {
          (R.error, why) -> { println("content: ${why}") }
          (R.ok, html)   -> {
            case dom.parse(html) {
              (R.error, why) -> { println("parse: ${why}") }
              (R.ok, doc)    -> {
                case doc.find("h1") {
                  (R.error, why) -> { println("find: ${why}") }
                  (R.ok, hits)   -> {
                    println("h1 count: ${hits.length()}")
                    println("h1 text: ${hits.text()}")
                  }
                }
              }
            }
          }
        }
        case page.close() {
          (R.error, why) -> { println("close: ${why}") }
          (R.ok, _)      -> {}
        }
      }
    }
    case pw.close() {
      (R.error, why) -> { println("close: ${why}") }
      (R.ok, _)      -> {}
    }
  }
}
```

## 4. Reading the DOM

There are two roads:

- **One element's text**: `page.text_content("#hello")` answers a `Text`. A
  selector that matches nothing is **not an error** — the answer is the null
  text, read through `is_null?()` (valkey's null reply, the same reading), and
  a real value goes through `as_string()`.
- **The whole DOM / structured queries**: `page.content()` answers the page's
  serialized HTML; hand it to the `dom` package. `dom.parse(html)` yields a
  `Document`, `Document.find(sel)` a `Selection`, and from there the goquery-
  shaped doors: `text()`, `attr()`, `attr_or()`, `html()`, `find()`, and so on.

The `playwright` package itself has no `evaluate`, no locators, and no event
callbacks, so every "query the DOM" capability comes from `dom` — and `dom`
only sees the rendered HTML string `content()` handed it. `dom.parse` is
strict (tags must close, a bare `&` or `<` in text refuses, no synthesized
`html`/`head`/`body` skeleton); `content()` output normally satisfies it, and
when it does not, the answer is `(R.error, reason)` with a byte position, not
a raise.

## 5. Errors: the three-way split

- The driver refusing a call is the value `(R.error, "playwright: " + the
  driver's text)`.
- The wire failing (a deadline, a close, the server leaving) is the value with
  the websocket or net reason.
- The caller's own mistake — an empty selector, an empty key, an unknown
  browser name — raises.

The engine never raises on driver data: a malformed message is a reason, not a
crash.

## 6. Notes

- **Run on the `c` target.** CHECK.md records that the interpreter's det
  scheduler hits a parked-read EBADF while a driver call is held open across a
  chatty wait, while the identical ladder runs byte-green on the `c` runtime.
  Use `emo build main.emo` (the default target is `c`) and run the native
  executable; the live verification before delivery ran on that path too.
- **Every door carries a 30-second deadline.** A selector the page never meets
  returns the driver's timeout error once the budget is spent instead of
  holding the process forever; `connect`'s timeout bounds every exchange, with
  `0.0` meaning wait indefinitely.
- **The v1 surface is exactly this**: `goto`, `click`, `fill`, `press`,
  `title`, `content`, `text_content`, `screenshot`, `close`. Contexts as
  first-class objects, locator semantics, `evaluate`, event doors, downloads,
  and tracing are all absent.
- The protocol is the driver's own, not a published standard; the package
  tracks the wire as the driver speaks it (verified against playwright 1.65.0
  with chromium headless shell 158.0.8127.18).

## References

- Package overview and limits: [`docs/stdlib/playwright.md`](stdlib/playwright.md)
  · [`docs/zh-CN/stdlib/playwright.md`](zh-CN/stdlib/playwright.md)
- Chinese version: [`docs/zh-CN/playwright-guide.md`](zh-CN/playwright-guide.md)
- The live example: `examples/playwright_live` (serves its own page through
  `httpd`, run by hand)
- The browser-free golden: `examples/playwright_demo` (carries its own
  miniature driver)
