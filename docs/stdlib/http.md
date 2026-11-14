# The `http` Package

The standard library's HTTP client, written in pure Emo on top of the
`net` package. Direct style throughout: a request reads like any other
function call, and the scheduler parks the process underneath while the
socket is busy. Serving HTTP is the [`httpd`](stdlib/httpd.md) package's
half of the wire. The package declares the `ocaml`, `c`, and
`typescript` targets (`targets = ["ocaml", "c", "typescript"]`);
dependency resolution refuses it on every other target. `https://` rides
`net`'s TLS on every one of them — ocaml-ssl on `ocaml`, `node:tls` on
`typescript`, the system OpenSSL/LibreSSL on `c` (see the `net`
package's coverage notes).

## Using the package

```emo
require "http"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "http"` needs `"http" = "0.1.0"` in
the manifest's `deps` block; the `net` package it builds on comes
through `http`'s own manifest. The package declares the `ocaml`, `c`,
and `typescript` targets.

## Client

The verb helpers cover the common cases; the general form takes every knob
explicitly:

```emo
http.get(url)                                // GET, no body
http.post(url, body)                         // POST with a body
http.put(url, body)                          // PUT with a body
http.delete(url)                             // DELETE, no body
http.request(method, url, headers, body, timeout)
http.request_with(method, url, headers, body, timeout, tls_options)
```

`http.request`'s full signature:

```emo
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) (R, HttpResponse)
```

- `headers` is an array of `(name, value)` tuples, appended after the
  built-in `Host`, `Content-Length`, and `Connection: close` lines.
- `timeout` is in seconds and is passed to `net.connect` /
  `net.tls_connect`; `0.0` (what the verb helpers use) waits indefinitely.
- The URL must carry an explicit `http://` or `https://` scheme;
  anything else is the error tuple, as is every transport failure the
  `net` package reports — match the pair, don't assume the response.
  `https://` URLs go through `net.tls_connect` — TLS with
  certificate verification on, per the `net` package's default. Default
  ports are 80 and 443; `host:port` overrides them.

Every success answers `(R.ok, resp)` with an `HttpResponse`:

```emo
class HttpResponse {
  // fields: status Int64, headers Array[(String, String)], body String
  def header(name String) String   // case-insensitive lookup; "" when absent
}
```

`http.request_with` is `http.request` plus the per-connection TLS
policy: `tls_options` is a `net.TlsClientOptions` from
`net.tls_client_options()` (`with_ca_file`, `with_client_certificate`,
`with_server_name`, `without_verification`), and an `https://` URL
connects through `net.tls_connect_with`. A plain `http://` URL has no
TLS leg, so the policy applies only to `https`.

```emo
require "http"

case http.get("http://127.0.0.1:8901/hello.txt") {
  (R.error, why) then { println("request failed: ${why}") }
  (R.ok, resp)   then {
    println(resp.status)                 // 200
    println(resp.header("content-type")) // text/plain
    println(resp.body)
  }
}
```

Redirects are never followed: a 3xx is a response like any other, and
following it (reading `resp.header("location")` and issuing the next
request) is the caller's explicit, visible move.

Each request opens one connection and closes it after the exchange — the
client always sends `Connection: close`, so there is no pooling to reason
about.

## Limitations

- **Three targets.** The package declares `targets = ["ocaml", "c", "typescript"]`;
  resolution refuses it for wasm, BEAM, and riscv64 builds. On `c`, UDP
  and Unix-domain sockets stay refused (inherited from `net`), and names
  resolve to IPv4 addresses only; `https` works.
- **No connection pooling.** One TCP connection per request, closed after
  the exchange.
- **No redirect following.** 3xx responses are returned as-is.
- **`Content-Length` responses.** Responses are read by their
  `Content-Length`; a response without one reads the connection's
  remaining bytes.
- **No header continuation, trailers, or compression** — headers are read
  as flat `Name: value` lines.
