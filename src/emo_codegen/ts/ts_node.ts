// The Node host for the TypeScript runtime: the networking section,
// the async-local process context, and the host object the core calls
// into. The compiler concatenates this file after ts_core.ts, so it
// never runs on its own.

import { AsyncLocalStorage } from "node:async_hooks";
import * as nodeNet from "node:net";
import * as nodeDgram from "node:dgram";
import * as nodeTls from "node:tls";
import * as nodeDns from "node:dns";
import * as nodeFs from "node:fs";

const _als = new AsyncLocalStorage<{ pid: number }>();

// ---- Networking ----
// The net package's surface — TCP, Unix-domain sockets, UDP, DNS, and
// TLS — rides Node's net/dgram/tls/dns modules. Every operation answers
// a promise the emitted `await` settles, so the Emo code stays direct
// style; a connection's deadline is per-operation, computed when the
// call starts, exactly like the native scheduler's.

function netError(message: string): EEmoException {
  return new EEmoException(message);
}

function netFail(message: string): never {
  throw netError(message);
}

// The wire's return convention (T29.3): a data-driven failure — a
// refused connection, an unresolvable name, an exceeded deadline, a
// closed socket — is the value (R.error, reason); only the caller's own
// mistakes raise. Every network operation answers one of these.
function netOk(v: any): any {
  return new ETuple([new EEnum("R", "ok"), v]);
}

function netErr(why: string): any {
  return new ETuple([new EEnum("R", "error"), why]);
}

// Runs a network operation, delivering its value as (R.ok, v) and a
// data-driven failure as (R.error, reason); an argument mistake still
// raises, telling the two apart by the exception's kind.
async function netResult(
  op: () => Promise<any> | any
): Promise<any> {
  try {
    return netOk(await op());
  } catch (e) {
    if (e instanceof EEmoException) return netErr(String(e.messageValue));
    throw e;
  }
}

// Every live network object, so the root process finishing can release
// the handles that would otherwise keep Node's loop alive — the native
// rule: the root process finishing ends the program.
const _netRoots = new Set<any>();

// Operation deadlines that are still ticking. They hold the loop open
// on their own, so releasing the handles is not enough to end the
// program: the parked operation they belong to is dropped with them.
const _netTimers = new Set<any>();

function netShutdown(): void {
  _netRoots.forEach((r) => {
    try {
      if (r instanceof EListener) r.server.close();
      else if (r instanceof EUdp) r.sock.close();
      else r.sock.destroy();
    } catch (e) {}
  });
  _netRoots.clear();
  _netTimers.forEach((t) => clearTimeout(t));
  _netTimers.clear();
}

function netReason(e: any): string {
  if (e === null || e === undefined) return "unknown error";
  if (typeof e.message === "string" && e.message.length > 0) return e.message;
  return String(e);
}

function netInt(x: any): number {
  if (isFloat(x)) return Math.trunc((x as EFloat).v);
  return typeof x === "bigint" ? Number(x) : num(x);
}

// A Float64 parameter is an EFloat wrapper; `num` only unwraps Int64.
function netFloat(x: any): number {
  if (isFloat(x)) return (x as EFloat).v;
  return netInt(x);
}

function netDeadline(seconds: number): number | null {
  return seconds > 0 ? Date.now() + seconds * 1000 : null;
}

// Races an operation against its deadline; the operation itself is never
// abandoned — a socket read that arrives late is buffered for the next
// call, like the native parked continuation.
function netRace(
  p: Promise<any>,
  deadline: number | null,
  message: string
): Promise<any> {
  if (deadline === null) return p;
  const remaining = deadline - Date.now();
  if (remaining <= 0) return Promise.reject(netError(message));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      _netTimers.delete(timer);
      reject(netError(message));
    }, remaining);
    _netTimers.add(timer);
    const done = () => {
      clearTimeout(timer);
      _netTimers.delete(timer);
    };
    p.then(
      (v) => {
        done();
        resolve(v);
      },
      (e) => {
        done();
        reject(e);
      }
    );
  });
}

function netSetTimeout(recv: any, seconds: any): any {
  if (!isFloat(seconds))
    throw new Error("`set_timeout` expects a Float64, got " + tag(seconds));
  if ((seconds as EFloat).v < 0)
    throw new Error("the timeout must not be negative");
  recv.timeout = (seconds as EFloat).v;
  return recv;
}

// A live TCP or TLS connection: the Node socket plus the unconsumed
// bytes, the reader state, and the operation deadline. One persistent
// reader drains the socket into [acc]; read operations wait on it, so a
// timed-out read leaves the bytes it received in place.
class EConn {
  sock: any;
  desc: string;
  timeout: number;
  closed: boolean;
  eof: boolean;
  failed: any;
  acc: Buffer;
  reader: boolean;
  waiting: Set<() => void>;
  isTls: boolean;

  constructor(sock: any, desc: string, isTls: boolean) {
    this.sock = sock;
    this.desc = desc;
    this.timeout = 0;
    this.closed = false;
    this.eof = false;
    this.failed = null;
    this.acc = Buffer.alloc(0);
    this.reader = false;
    this.waiting = new Set();
    this.isTls = isTls;
    // A socket error must never escape as an uncaught 'error' event;
    // the reader records it and read operations report it.
    sock.on("error", () => {});
    sock.on("close", () => _netRoots.delete(this));
    _netRoots.add(this);
  }
}

class EListener {
  server: any;
  desc: string;
  port: number;
  unix: boolean;
  timeout: number;
  closed: boolean;
  failed: any;
  queue: any[];
  waiting: any[];
  isTls: boolean;

  constructor(
    server: any,
    desc: string,
    port: number,
    unix: boolean,
    isTls: boolean
  ) {
    this.server = server;
    this.desc = desc;
    this.port = port;
    this.unix = unix;
    this.timeout = 0;
    this.closed = false;
    this.failed = null;
    this.queue = [];
    this.waiting = [];
    this.isTls = isTls;
    // A TLS server hands back the socket only once the handshake is
    // done; a plain one at accept time.
    _netRoots.add(this);
    server.on(isTls ? "secureConnection" : "connection", (sock: any) => {
      if (this.waiting.length > 0) this.waiting.shift().resolve(sock);
      else this.queue.push(sock);
    });
    server.on("error", (e: any) => {
      this.failed = e;
      const ws = this.waiting;
      this.waiting = [];
      ws.forEach((w) =>
        w.reject(
          new EEmoException(
            "cannot accept on " + this.desc + ": " + netReason(e)
          )
        )
      );
    });
    server.on("close", () => _netRoots.delete(this));
  }
}

class EUdp {
  sock: any;
  desc: string;
  port: number;
  timeout: number;
  closed: boolean;
  queue: any[];
  waiting: any[];

  constructor(sock: any, desc: string, port: number) {
    this.sock = sock;
    this.desc = desc;
    this.port = port;
    this.timeout = 0;
    this.closed = false;
    this.queue = [];
    this.waiting = [];
    _netRoots.add(this);
    sock.on("close", () => _netRoots.delete(this));
    sock.on("message", (msg: Buffer, rinfo: any) => {
      if (this.waiting.length > 0) this.waiting.shift().resolve([msg, rinfo]);
      else this.queue.push([msg, rinfo]);
    });
  }
}

function connNotify(c: EConn): void {
  const ws = c.waiting;
  c.waiting = new Set();
  ws.forEach((w) => w());
}

function connWait(
  c: EConn,
  deadline: number | null,
  message: string
): Promise<void> {
  let me: (() => void) | null = null;
  const p = new Promise<void>((resolve) => {
    me = resolve;
    c.waiting.add(resolve);
  });
  const drop = () => {
    if (me) c.waiting.delete(me);
    me = null;
  };
  return netRace(p, deadline, message).then(
    (v) => {
      drop();
      _endIfShutdown();
      return v;
    },
    (e) => {
      drop();
      _endIfShutdown();
      throw e;
    }
  );
}

function connOpen(c: EConn): void {
  if (c.closed) netFail("the connection to " + c.desc + " is closed");
}

function connStartReader(c: EConn): void {
  if (c.reader) return;
  c.reader = true;
  (async () => {
    try {
      for await (const chunk of c.sock) {
        const b = chunk as Buffer;
        c.acc =
          c.acc.length === 0 ? Buffer.from(b) : Buffer.concat([c.acc, b]);
        connNotify(c);
      }
      c.eof = true;
    } catch (e) {
      c.failed = e;
    }
    connNotify(c);
  })();
}

function connCheckRead(c: EConn): void {
  if (c.failed !== null && !c.eof)
    netFail("cannot read on " + c.desc + ": " + netReason(c.failed));
}

async function connReadLine(c: EConn): Promise<string> {
  connOpen(c);
  connStartReader(c);
  const deadline = netDeadline(c.timeout);
  const message = "timed out reading a line from " + c.desc;
  for (;;) {
    const at = c.acc.indexOf(10);
    if (at >= 0) {
      let line = c.acc.subarray(0, at);
      c.acc = c.acc.subarray(at + 1);
      if (line.length > 0 && line[line.length - 1] === 13)
        line = line.subarray(0, line.length - 1);
      return utf8Decode(line);
    }
    if (c.eof) {
      if (c.acc.length === 0) return "";
      netFail("the connection to " + c.desc + " closed mid-line");
    }
    connCheckRead(c);
    await connWait(c, deadline, message);
  }
}

async function connReadExactly(c: EConn, n: any): Promise<string> {
  connOpen(c);
  if (typeof n !== "bigint")
    throw new Error("`read_exactly` expects an Int64, got " + tag(n));
  const count = Number(n);
  if (count < 0) throw new Error("`read_exactly` expects a non-negative Int64");
  connStartReader(c);
  const deadline = netDeadline(c.timeout);
  const message = "timed out reading from " + c.desc;
  for (;;) {
    if (c.acc.length >= count) {
      const out = c.acc.subarray(0, count);
      c.acc = c.acc.subarray(count);
      return utf8Decode(out);
    }
    if (c.eof)
      netFail(
        "the connection to " +
          c.desc +
          " closed after " +
          c.acc.length +
          " of " +
          count +
          " bytes"
      );
    connCheckRead(c);
    await connWait(c, deadline, message);
  }
}

async function connReadAll(c: EConn): Promise<string> {
  connOpen(c);
  connStartReader(c);
  const deadline = netDeadline(c.timeout);
  const message = "timed out reading from " + c.desc;
  for (;;) {
    if (c.eof) {
      const out = c.acc;
      c.acc = Buffer.alloc(0);
      return utf8Decode(out);
    }
    connCheckRead(c);
    await connWait(c, deadline, message);
  }
}

function connWrite(c: EConn, data: any): Promise<EConn> {
  connOpen(c);
  if (typeof data !== "string")
    throw new Error("`write` expects a String, got " + tag(data));
  const deadline = netDeadline(c.timeout);
  const message = "timed out writing to " + c.desc;
  const flushed = new Promise<void>((resolve, reject) => {
    c.sock.write(Buffer.from(data, "utf8"), (e: any) => {
      if (e)
        reject(netError("cannot write on " + c.desc + ": " + netReason(e)));
      else resolve();
    });
  });
  return netRace(flushed, deadline, message).then(() => c);
}

function connClose(c: EConn): EConn {
  connOpen(c);
  c.closed = true;
  // Graceful: writes were delivered in full before returning, so this
  // sends the FIN and lets the peer read everything that was written.
  try {
    c.sock.end();
  } catch (e) {}
  return c;
}

function netPeerDesc(sock: any): string {
  const host = sock.remoteAddress ? String(sock.remoteAddress) : "";
  const port = sock.remotePort ? String(sock.remotePort) : "0";
  return host + ":" + port;
}

function wrapAccepted(l: EListener, sock: any): EConn {
  return new EConn(sock, netPeerDesc(sock), l.isTls);
}

function listenerAccept(l: EListener): Promise<EConn> {
  if (l.closed)
    return Promise.reject(
      netError("the listener on " + l.desc + " is closed")
    );
  if (l.failed !== null)
    return Promise.reject(
      netError("cannot accept on " + l.desc + ": " + netReason(l.failed))
    );
  if (l.queue.length > 0)
    return Promise.resolve(wrapAccepted(l, l.queue.shift()));
  const deadline = netDeadline(l.timeout);
  const message = "timed out waiting to accept on " + l.desc;
  let entry: any = null;
  const wait = new Promise<any>((resolve, reject) => {
    entry = { resolve, reject };
    l.waiting.push(entry);
  });
  const drop = () => {
    const i = l.waiting.indexOf(entry);
    if (i >= 0) l.waiting.splice(i, 1);
  };
  return netRace(wait, deadline, message).then(
    (sock) => {
      drop();
      _endIfShutdown(sock);
      return wrapAccepted(l, sock);
    },
    (e) => {
      drop();
      _endIfShutdown();
      throw e;
    }
  );
}

function listenerPort(l: EListener): bigint {
  if (l.unix)
    netFail("a unix-domain listener (" + l.desc + ") has no port");
  return BigInt(l.port);
}

function listenerClose(l: EListener): EListener {
  if (l.closed)
    netFail("the listener on " + l.desc + " is already closed");
  l.closed = true;
  try {
    l.server.close();
  } catch (e) {}
  return l;
}

function udpSendTo(u: EUdp, host: any, port: any, data: any): Promise<EUdp> {
  if (u.closed)
    return Promise.reject(
      netError("the udp socket on " + u.desc + " is closed")
    );
  const p = netInt(port);
  const deadline = netDeadline(u.timeout);
  const message = "timed out sending on " + u.desc;
  return netResolveAddrs(host)
    .then((addrs) => {
      if (addrs.length === 0) netFail("cannot resolve host `" + host + "`");
      return netRace(
        new Promise<void>((resolve, reject) => {
          u.sock.send(
            Buffer.from(data, "utf8"),
            p,
            addrs[0],
            (e: any) => {
              if (e)
                reject(
                  new EEmoException(
                    "cannot send on " + u.desc + ": " + netReason(e)
                  )
                );
              else resolve();
            }
          );
        }),
        deadline,
        message
      );
    })
    .then(() => u);
}

function udpRecvFrom(u: EUdp): Promise<any> {
  if (u.closed)
    return Promise.reject(
      netError("the udp socket on " + u.desc + " is closed")
    );
  const deliver = (pair: any) =>
    new ETuple([utf8Decode(pair[0]), pair[1].address, BigInt(pair[1].port)]);
  if (u.queue.length > 0) return Promise.resolve(deliver(u.queue.shift()));
  const deadline = netDeadline(u.timeout);
  const message = "timed out waiting to receive on " + u.desc;
  let entry: any = null;
  const wait = new Promise<any>((resolve, reject) => {
    entry = { resolve, reject };
    u.waiting.push(entry);
  });
  const drop = () => {
    const i = u.waiting.indexOf(entry);
    if (i >= 0) u.waiting.splice(i, 1);
  };
  return netRace(wait, deadline, message).then(
    (pair) => {
      drop();
      _endIfShutdown();
      return deliver(pair);
    },
    (e) => {
      drop();
      _endIfShutdown();
      throw e;
    }
  );
}

function udpClose(u: EUdp): EUdp {
  if (u.closed)
    netFail("the udp socket on " + u.desc + " is already closed");
  u.closed = true;
  try {
    u.sock.close();
  } catch (e) {}
  return u;
}

async function netResolveAddrs(host: any): Promise<string[]> {
  try {
    const r = await nodeDns.promises.lookup(String(host), {
      all: true,
      verbatim: true,
    });
    return r.map((a: any) => String(a.address));
  } catch (e) {
    return [];
  }
}

async function netResolve(host: any): Promise<EArray> {
  if (typeof host !== "string")
    throw new Error("`net_resolve` expects a String host, got " + tag(host));
  const addrs = await netResolveAddrs(host);
  _endIfShutdown();
  if (addrs.length === 0) netFail("cannot resolve host `" + host + "`");
  return new EArray(addrs);
}

// An address literal needs no SNI name; a hostname does.
function netIsIpLiteral(host: string): boolean {
  return /^[0-9.]+$/.test(host) || host.indexOf(":") >= 0;
}

function netConnectErrorValue(host: string, port: number, e: any): any {
  const target = host + ":" + port;
  if (e && e.code === "ECONNREFUSED")
    return new EEmoException("connection refused to " + target);
  if (e instanceof EEmoException) return e;
  return new EEmoException(
    "cannot connect to " + target + ": " + netReason(e)
  );
}

function netTlsErrorValue(host: string, port: number, e: any): any {
  if (e instanceof EEmoException) return e;
  return new EEmoException(
    "the TLS handshake with " +
      host +
      ":" +
      port +
      " failed: " +
      netReason(e)
  );
}

// The per-connection TLS policy the options record carries: a private
// trust store, a client certificate for mutual TLS, the name SNI and
// verification use, and the explicit verification opt-out. A missing
// or unreadable file is the (R.error, reason) the simple calls give.
function netTlsClientOptions(
  verify: boolean,
  caFile: any,
  certFile: any,
  keyFile: any,
  serverName: any
): any {
  const opts: any = { rejectUnauthorized: verify };
  if (caFile !== "") {
    try {
      opts.ca = nodeFs.readFileSync(caFile);
    } catch (e) {
      netFail("cannot load the TLS CA file `" + caFile + "`: " + netReason(e));
    }
  }
  if (certFile !== "") {
    try {
      opts.cert = nodeFs.readFileSync(certFile);
      opts.key = nodeFs.readFileSync(keyFile);
    } catch (e) {
      netFail(
        "cannot load the TLS client certificate `" +
          certFile +
          "`: " +
          netReason(e)
      );
    }
  }
  if (serverName !== "") opts.servername = serverName;
  return opts;
}

function netConnectOne(
  addr: string,
  port: number,
  tlsOpts: any,
  host: string,
  deadline: number | null,
  message: string
): Promise<any> {
  return new Promise((resolve, reject) => {
    let sock: any = null;
    let done = false;
    let timer: any = null;
    const finish = (fn: () => void) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      fn();
    };
    if (tlsOpts !== null) {
      const opts: any = Object.assign({}, tlsOpts, { host: addr, port: port });
      const name = tlsOpts.servername || host;
      opts.servername = netIsIpLiteral(name) ? undefined : name;
      sock = nodeTls.connect(opts);
      sock.once("secureConnect", () => finish(() => resolve(sock)));
      sock.once("error", (e: any) =>
        finish(() => reject(netTlsErrorValue(host, port, e)))
      );
    } else {
      sock = nodeNet.createConnection({ host: addr, port: port });
      sock.once("connect", () => finish(() => resolve(sock)));
      sock.once("error", (e: any) =>
        finish(() => reject(netConnectErrorValue(host, port, e)))
      );
    }
    if (deadline !== null)
      timer = setTimeout(
        () =>
          finish(() => {
            try {
              sock.destroy();
            } catch (e) {}
            reject(netFail(message));
          }),
        Math.max(1, deadline - Date.now())
      );
  });
}

async function netConnect(
  host: any,
  port: any,
  timeout: any,
  tlsOpts: any
): Promise<EConn> {
  const p = netInt(port);
  const t = netFloat(timeout);
  if (tlsOpts !== null && tlsOpts.rejectUnauthorized) {
    const name = tlsOpts.servername || host;
    if (netIsIpLiteral(name))
      netFail(
        "tls: cannot verify a certificate for the IP address `" +
          name +
          "`; pass server_name with the certificate's DNS name"
      );
  }
  const addrs = await netResolveAddrs(host);
  _endIfShutdown();
  if (addrs.length === 0) netFail("cannot resolve host `" + host + "`");
  const deadline = netDeadline(t);
  const message =
    "timed out after " + g6(t) + "s connecting to " + host + ":" + p;
  let last: any = null;
  for (const addr of addrs) {
    if (deadline !== null && Date.now() >= deadline) netFail(message);
    try {
      const sock = await netConnectOne(
        addr,
        p,
        tlsOpts,
        host,
        deadline,
        message
      );
      _endIfShutdown(sock);
      return new EConn(sock, netPeerDesc(sock), tlsOpts !== null);
    } catch (e) {
      if (e instanceof EProgramEnd) throw e;
      last = e;
    }
  }
  if (last instanceof EEmoException) throw last;
  netFail("cannot connect to " + host + ":" + p);
}

async function netConnectUnix(path: any, timeout: any): Promise<EConn> {
  const t = netFloat(timeout);
  const target = "unix socket " + path;
  const deadline = netDeadline(t);
  const message = "timed out after " + g6(t) + "s connecting to " + target;
  const c: EConn = await new Promise<EConn>((resolve, reject) => {
    let done = false;
    let timer: any = null;
    const finish = (fn: () => void) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      fn();
    };
    const sock = nodeNet.createConnection({ path: path });
    sock.once("connect", () =>
      finish(() => resolve(new EConn(sock, target, false)))
    );
    sock.once("error", (e: any) =>
      finish(() =>
        reject(
          e && e.code === "ECONNREFUSED"
            ? new EEmoException("connection refused to " + target)
            : new EEmoException(
                "cannot connect to " + target + ": " + netReason(e)
              )
        )
      )
    );
    if (deadline !== null)
      timer = setTimeout(
        () =>
          finish(() => {
            try {
              sock.destroy();
            } catch (e) {}
            reject(netError(message));
          }),
        Math.max(1, deadline - Date.now())
      );
  });
  _endIfShutdown(c.sock);
  return c;
}

async function netListen(host: any, port: any): Promise<EListener> {
  const p = netInt(port);
  const l = new EListener(nodeNet.createServer(), "", 0, false, false);
  await new Promise<void>((resolve, reject) => {
    l.server.once("error", (e: any) => {
      if (e && e.code === "ENOTFOUND")
        reject(netError("cannot resolve host `" + host + "`"));
      else
        reject(
          netError(
            "cannot listen on " + host + ":" + p + ": " + netReason(e)
          )
        );
    });
    l.server.listen({ host: host, port: p }, () => resolve());
  });
  _endIfShutdown();
  const addr = l.server.address();
  l.port = addr && typeof addr === "object" ? addr.port : p;
  l.desc = host + ":" + l.port;
  return l;
}

async function netListenUnix(path: any): Promise<EListener> {
  const l = new EListener(
    nodeNet.createServer(),
    "unix socket " + path,
    0,
    true,
    false
  );
  await new Promise<void>((resolve, reject) => {
    l.server.once("error", (e: any) =>
      reject(
        netError(
          "cannot listen on unix socket " + path + ": " + netReason(e)
        )
      )
    );
    l.server.listen({ path: path }, () => resolve());
  });
  _endIfShutdown();
  return l;
}

async function netListenTls(
  host: any,
  port: any,
  certPath: any,
  keyPath: any,
  caFile: any,
  requireClientCert: boolean
): Promise<EListener> {
  const p = netInt(port);
  if (requireClientCert && caFile === "")
    netFail("tls: require_client_cert needs a ca_file to verify against");
  let cert: any;
  let key: any;
  try {
    cert = nodeFs.readFileSync(certPath);
    key = nodeFs.readFileSync(keyPath);
  } catch (e) {
    netFail(
      "cannot load the TLS certificate for " +
        host +
        ":" +
        p +
        ": " +
        netReason(e)
    );
  }
  const serverOpts: any = { cert: cert, key: key };
  if (caFile !== "") {
    try {
      serverOpts.ca = nodeFs.readFileSync(caFile);
    } catch (e) {
      netFail(
        "cannot load the TLS client CA file `" + caFile + "`: " + netReason(e)
      );
    }
    serverOpts.requestCert = true;
    serverOpts.rejectUnauthorized = requireClientCert;
  }
  const l = new EListener(
    nodeTls.createServer(serverOpts),
    "",
    0,
    false,
    true
  );
  await new Promise<void>((resolve, reject) => {
    l.server.once("error", (e: any) => {
      if (e && e.code === "ENOTFOUND")
        reject(netError("cannot resolve host `" + host + "`"));
      else
        reject(
          netError(
            "cannot listen on " + host + ":" + p + ": " + netReason(e)
          )
        );
    });
    l.server.listen({ host: host, port: p }, () => resolve());
  });
  _endIfShutdown();
  const addr = l.server.address();
  l.port = addr && typeof addr === "object" ? addr.port : p;
  l.desc = host + ":" + l.port;
  return l;
}

async function netUdpBind(host: any, port: any): Promise<EUdp> {
  const p = netInt(port);
  const sock = nodeDgram.createSocket("udp4");
  await new Promise<void>((resolve, reject) => {
    sock.once("error", (e: any) => {
      if (e && e.code === "ENOTFOUND")
        reject(netError("cannot resolve host `" + host + "`"));
      else
        reject(
          netError(
            "cannot bind udp on " + host + ":" + p + ": " + netReason(e)
          )
        );
    });
    sock.bind({ address: String(host), port: p }, () => resolve());
  });
  const addr = sock.address();
  const bound = addr ? addr.port : p;
  return new EUdp(sock, host + ":" + bound, bound);
}


// The host method table: the receivers the networking section owns.
function nodeMethod(recv: any, name: string, args: any[]): any {
  if (recv instanceof EConn) {
    if (name === "read_line") return netResult(() => connReadLine(recv));
    if (name === "read_exactly")
      return netResult(() => connReadExactly(recv, args[0]));
    if (name === "read_all") return netResult(() => connReadAll(recv));
    if (name === "write") return netResult(() => connWrite(recv, args[0]));
    if (name === "close") return netResult(() => connClose(recv));
    if (name === "set_timeout") return netSetTimeout(recv, args[0]);
  }
  if (recv instanceof EListener) {
    if (name === "accept") return netResult(() => listenerAccept(recv));
    if (name === "port") return listenerPort(recv);
    if (name === "close") return netResult(() => listenerClose(recv));
    if (name === "set_timeout") return netSetTimeout(recv, args[0]);
  }
  if (recv instanceof EUdp) {
    if (name === "send_to")
      return netResult(() => udpSendTo(recv, args[0], args[1], args[2]));
    if (name === "recv_from") return netResult(() => udpRecvFrom(recv));
    if (name === "port") return BigInt(recv.port);
    if (name === "close") return netResult(() => udpClose(recv));
    if (name === "set_timeout") return netSetTimeout(recv, args[0]);
  }
  return _hostMethodMiss;
}

function nodeRuntimeImpl(name: string, args: any[]): any {
  switch (name) {
    case "net_resolve":
      return netResult(() => netResolve(args[0]));
    case "net_connect":
      return netResult(() => netConnect(args[0], args[1], args[2], null));
    case "net_connect_unix":
      return netResult(() => netConnectUnix(args[0], args[1]));
    case "net_listen":
      return netResult(() => netListen(args[0], args[1]));
    case "net_listen_unix":
      return netResult(() => netListenUnix(args[0]));
    case "net_udp_bind":
      return netResult(() => netUdpBind(args[0], args[1]));
    case "net_tls_connect":
      return netResult(() =>
        netConnect(
          args[0],
          args[1],
          args[2],
          netTlsClientOptions(true, "", "", "", "")
        )
      );
    case "net_tls_connect_insecure":
      return netResult(() =>
        netConnect(
          args[0],
          args[1],
          args[2],
          netTlsClientOptions(false, "", "", "", "")
        )
      );
    case "net_tls_connect_with":
      return netResult(() =>
        netConnect(
          args[0],
          args[1],
          args[2],
          netTlsClientOptions(
            !args[7],
            args[3],
            args[4],
            args[5],
            args[6]
          )
        )
      );
    case "net_listen_tls":
      return netResult(() =>
        netListenTls(args[0], args[1], args[2], args[3], "", false)
      );
    case "net_listen_tls_with":
      return netResult(() =>
        netListenTls(args[0], args[1], args[2], args[3], args[4], args[5])
      );
    default:
      throw new Error(
        "the `" +
          name +
          "` runtime implementation is not supported on the typescript target yet"
      );
  }
}

// The root body has ended, so the program has ended. The emitted root
// calls this the moment its last statement is done — synchronously,
// before the microtasks a preceding send queued run — so a task a send
// made runnable never gets to execute past the root. Node's own loop
// then drains: the handles are closed, the timers are cleared, and the
// pending resumptions unwinding at _endIfShutdown leave nothing behind.
function nodeShutdown(): void {
  netShutdown();
}

function nodeWrite(text: string): void {
  process.stdout.write(text);
}

function nodeRunAs<T>(pid: number, f: () => T): T {
  return _als.run({ pid }, f);
}

function nodeCurrentPid(): number | null {
  const st = _als.getStore();
  return st ? st.pid : null;
}

_host = {
  write: nodeWrite,
  runAs: nodeRunAs,
  currentPid: nodeCurrentPid,
  shutdownOnRootEnd: () => true,
  shutdown: nodeShutdown,
  method: nodeMethod,
  runtimeImpl: nodeRuntimeImpl,
};
