// The Emo runtime for the TypeScript target: tagged values, the
// stringification rule, builtins, and method dispatch. Emitted
// programs are self-contained — this prelude is prepended to the
// generated code, so everything lives in one namespace, E.

// Processes: each task runs under an async-local store carrying its
// pid, so `self_pid()` is correct across awaits.
import { AsyncLocalStorage } from "node:async_hooks";
const _als = new AsyncLocalStorage<{ pid: number }>();
const _mailboxes = new Map<number, any[]>();
const _waiters = new Map<number, (msg: any) => void>();
let _nextPid = 1;

class EHalt {}
class EReturn {
  value: any;
  constructor(value: any) {
    this.value = value;
  }
}

// Processes end cleanly on EHalt/EReturn and on an uncaught Emo
// exception (reported, killing only the offending process).
function _taskError(e: any): any {
  if (e instanceof EHalt || e instanceof EReturn) return undefined;
  if (e instanceof EEmoException) {
    console.error(
      "error[E3010]: uncaught exception: " + to_string(e.messageValue)
    );
    return undefined;
  }
  throw e;
}

// Node runs emitted programs in strip-only mode: plain field
// declarations and explicit assignments only — no parameter
// properties, no enums, no decorators.

class EFloat {
  v: number;
  constructor(v: number) {
    this.v = v;
  }
}

class EChar {
  c: string;
  constructor(c: string) {
    this.c = c;
  }
}

class EBox {
  v: any;
  constructor(v: any) {
    this.v = v;
  }
}

class EBytes {
  data: Uint8Array;
  constructor(n: number) {
    this.data = new Uint8Array(n);
  }
}

// The List deque: a doubly-linked chain with O(1) push and pop at both
// ends. The identity is the object, so mutation is visible through every
// alias — the same shape a Box takes. Dispatch goes through E.method's
// EList arms, so the class carries no methods of its own (an `is`
// interface check stays false, like Box and Bytes).
class EListNode {
  v: any;
  prev: EListNode | null;
  next: EListNode | null;
  constructor(v: any) {
    this.v = v;
    this.prev = null;
    this.next = null;
  }
}

class EList {
  head: EListNode | null;
  tail: EListNode | null;
  size: number;
  constructor() {
    this.head = null;
    this.tail = null;
    this.size = 0;
  }
}

function listPushFront(l: EList, v: any): EList {
  const node = new EListNode(v);
  node.next = l.head;
  if (l.head) l.head.prev = node;
  else l.tail = node;
  l.head = node;
  l.size++;
  return l;
}

function listPushBack(l: EList, v: any): EList {
  const node = new EListNode(v);
  node.prev = l.tail;
  if (l.tail) l.tail.next = node;
  else l.head = node;
  l.tail = node;
  l.size++;
  return l;
}

function listPopFront(l: EList): any {
  if (!l.head) throw new Error("`pop_front` on an empty List");
  const node = l.head;
  l.head = node.next;
  if (l.head) l.head.prev = null;
  else l.tail = null;
  l.size--;
  return node.v;
}

function listPopBack(l: EList): any {
  if (!l.tail) throw new Error("`pop_back` on an empty List");
  const node = l.tail;
  l.tail = node.prev;
  if (l.tail) l.tail.next = null;
  else l.head = null;
  l.size--;
  return node.v;
}

class ETuple {
  items: any[];
  constructor(items: any[]) {
    this.items = items;
  }
}

class EArray {
  items: any[];
  constructor(items: any[]) {
    this.items = items;
  }
}

// The Map: a mutable, insertion-ordered hash table. JS's own Map keeps
// insertion order; the keys cross it normalized to tagged strings, so
// the primitive Emo key types hash and compare per Emo's rule (Int64
// 1n, Byte 1, and Float64 1.0 are three distinct keys).
class EMap {
  entries: Map<string, [any, any]>;
  constructor() {
    this.entries = new Map();
  }
}

function isMapKey(k: any): boolean {
  return (
    typeof k === "string" ||
    typeof k === "bigint" ||
    typeof k === "number" ||
    typeof k === "boolean" ||
    isFloat(k) ||
    isChar(k)
  );
}

function emoMapKey(k: any): string {
  if (typeof k === "string") return "s:" + k;
  if (typeof k === "bigint") return "i:" + k.toString();
  if (typeof k === "number") return "y:" + k;
  if (typeof k === "boolean") return "b:" + k;
  if (isFloat(k)) return "f:" + k.v;
  if (isChar(k)) return "c:" + k.c;
  throw new Error(
    "a map key must be a String, Int64, Byte, Bool, Char, or Float64"
  );
}

class EEnum {
  type: string;
  member: string;
  constructor(type: string, member: string) {
    this.type = type;
    this.member = member;
  }
}

class EPid {
  id: number;
  constructor(id: number) {
    this.id = id;
  }
}

class EEmoException extends Error {
  messageValue: any;
  dataValue: any;
  constructor(messageValue: any, dataValue: any = null) {
    super("uncaught exception");
    this.messageValue = messageValue;
    this.dataValue = dataValue;
  }
}

function isFloat(x: any): x is EFloat {
  return x instanceof EFloat;
}

function isChar(x: any): x is EChar {
  return x instanceof EChar;
}

function isInt(x: any): boolean {
  return typeof x === "number" && Number.isInteger(x);
}

// The integer value is an Int64 (BigInt) everywhere; JS-native
// collections and APIs take numbers — this is the boundary.
function num(x: any): number {
  return typeof x === "bigint" ? Number(x) : (x as number);
}

function isI64(x: any): boolean {
  return typeof x === "bigint";
}

// OCaml's %g: six significant digits, exponent form below 1e-4 or at
// 1e6 and above, exponent spelled with a sign and two digits.
function g6(x: number): string {
  if (Number.isNaN(x)) return "nan";
  if (x === Infinity) return "inf";
  if (x === -Infinity) return "-inf";
  if (x === 0) return Object.is(x, -0) ? "-0" : "0";
  const exp = Math.floor(Math.log10(Math.abs(x)));
  if (exp < -4 || exp >= 6) {
    let r = Number((x / Math.pow(10, exp)).toFixed(5));
    let e = exp;
    if (Math.abs(r) >= 10) {
      r = Number((r / 10).toFixed(5));
      e += 1;
    }
    let ms = r.toFixed(5);
    if (ms.includes(".")) ms = ms.replace(/0+$/, "").replace(/\.$/, "");
    return (
      ms + "e" + (e < 0 ? "-" : "+") + String(Math.abs(e)).padStart(2, "0")
    );
  }
  const decimals = Math.max(0, 5 - exp);
  let s = x.toFixed(decimals);
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s;
}

function floatStr(f: number): string {
  if (Number.isInteger(f) && Math.abs(f) < 1e16) return f.toFixed(1);
  return g6(f);
}

// Strings are UTF-8 on every target, so `to_bytes` and `Bytes.to_string`
// are the UTF-8 codec, written out like `%g` above. Invalid sequences
// become U+FFFD (a JS string cannot carry raw non-UTF-8 bytes; the byte
// targets memcpy, so they keep them).

function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let cp = s.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
      const lo = s.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      } else {
        cp = 0xfffd;
      }
    } else if (cp >= 0xdc00 && cp <= 0xdfff) {
      cp = 0xfffd;
    }
    if (cp < 0x80) out.push(cp);
    else if (cp < 0x800)
      out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
    else if (cp < 0x10000)
      out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    else
      out.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 63),
        0x80 | ((cp >> 6) & 63),
        0x80 | (cp & 63)
      );
  }
  return Uint8Array.from(out);
}

function utf8Decode(d: Uint8Array): string {
  let s = "";
  for (let i = 0; i < d.length; ) {
    const b = d[i];
    if (b < 0x80) {
      s += String.fromCharCode(b);
      i++;
      continue;
    }
    const len = b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4;
    let cp = 0;
    let ok = i + len <= d.length;
    if (ok && len === 2) {
      cp = b & 0x1f;
      ok = b >= 0xc2;
    } else if (ok && len === 3) {
      cp = b & 0x0f;
      ok = b >= 0xe0 && b < 0xe8;
    } else if (ok) {
      cp = b & 0x07;
      ok = b >= 0xf0 && b < 0xf5;
    }
    for (let k = 1; ok && k < len; k++) {
      const c = d[i + k];
      if ((c & 0xc0) !== 0x80) ok = false;
      else cp = (cp << 6) | (c & 0x3f);
    }
    if (
      !ok ||
      (len === 3 && cp < 0x800) ||
      (len === 4 && cp < 0x10000) ||
      (cp >= 0xd800 && cp <= 0xdfff) ||
      cp > 0x10ffff
    ) {
      s += "\ufffd";
      i++;
      continue;
    }
    if (cp > 0xffff) {
      cp -= 0x10000;
      s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    } else {
      s += String.fromCharCode(cp);
    }
    i += len;
  }
  return s;
}

// Deep equality: primitives by value, compounds element-wise,
// instances through their class-declared content (__eq).
function deepEq(a: any, b: any): boolean {
  if (a === b) return true;
  if (isFloat(a) && isFloat(b)) return a.v === b.v;
  if (isChar(a) && isChar(b)) return a.c === b.c;
  if (a instanceof ETuple && b instanceof ETuple)
    return (
      a.items.length === b.items.length &&
      a.items.every((x: any, i: number) => deepEq(x, b.items[i]))
    );
  if (a instanceof EArray && b instanceof EArray)
    return (
      a.items.length === b.items.length &&
      a.items.every((x: any, i: number) => deepEq(x, b.items[i]))
    );
  if (a instanceof EMap && b instanceof EMap) {
    if (a.entries.size !== b.entries.size) return false;
    for (const [key, kv] of a.entries) {
      const other = b.entries.get(key);
      if (!other || !deepEq(kv[1], other[1])) return false;
    }
    return true;
  }
  if (a instanceof EEnum && b instanceof EEnum)
    return a.type === b.type && a.member === b.member;
  if (a instanceof EBytes && b instanceof EBytes)
    return (
      a.data.length === b.data.length &&
      a.data.every((x: number, i: number) => x === b.data[i])
    );
  if (a instanceof EList && b instanceof EList) {
    if (a.size !== b.size) return false;
    let na = a.head;
    let nb = b.head;
    while (na && nb) {
      if (!deepEq(na.v, nb.v)) return false;
      na = na.next;
      nb = nb.next;
    }
    return true;
  }
  if (
    a &&
    b &&
    typeof a === "object" &&
    typeof b === "object" &&
    typeof a.__eq === "function"
  )
    return a.__eq(b);
  return false;
}

// Inside a map's rendering, strings show quoted — the debug form the
// interpreter's Map rendering uses.
function toStrDbg(v: any): string {
  return typeof v === "string" ? JSON.stringify(v) : toStr(v);
}

// The one stringification rule: interpolation and `.to_string()` share
// it, exactly like the interpreter.
function toStr(v: any): string {
  if (typeof v === "number") return String(v);
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "string") return v;
  if (typeof v === "boolean") return v ? "true" : "false";
  if (v === null || v === undefined) return "nil";
  if (isFloat(v)) return floatStr(v.v);
  if (isChar(v)) return v.c;
  if (v instanceof EBox) return toStr(v.v);
  if (v instanceof EBytes) return "Bytes[" + v.data.length + "]";
  if (v instanceof EList) {
    const items: string[] = [];
    for (let n = v.head; n; n = n.next) items.push(toStr(n.v));
    return "List[" + items.join(", ") + "]";
  }
  if (v instanceof ETuple) return "(" + v.items.map(toStr).join(", ") + ")";
  if (v instanceof EArray) return "[" + v.items.map(toStr).join(", ") + "]";
  if (v instanceof EMap)
    return (
      "{" +
      [...v.entries.values()]
        .map((kv: [any, any]) => toStrDbg(kv[0]) + ": " + toStrDbg(kv[1]))
        .join(", ") +
      "}"
    );
  if (v instanceof EEnum) return v.type + "." + v.member;
  if (v instanceof EPid) return "<pid " + v.id + ">";
  if (v instanceof EEmoException) return toStr(v.messageValue);
  if (v && typeof v === "object" && v.constructor && v.constructor.__emo)
    return v.constructor.__emo;
  return String(v);
}

function println(v: any): void {
  process.stdout.write(toStr(v) + "\n");
}

// ---- printf ----

// C17 §7.21.6.1 on the JS primitives. bigint Int64s format through
// two's-complement masking; floats take a BigInt-exact decimal
// expansion with round-half-to-even, matching the C targets' snprintf
// where `toFixed` (half away from zero) would not. `%s` measures width
// and precision in UTF-8 bytes; a cut landing mid-codepoint decodes to
// U+FFFD, since a JS string cannot carry a partial byte.

class PFSpec {
  minus: boolean = false;
  plus: boolean = false;
  space: boolean = false;
  hash: boolean = false;
  zero: boolean = false;
  width: number | "*" | null = null;
  prec: number | "*" | null = null;
  conv: string = "d";
}

function pfParse(fmt: string): any[] {
  const parts: any[] = [];
  let text = "";
  const flush = () => {
    if (text) {
      parts.push(text);
      text = "";
    }
  };
  let i = 0;
  while (i < fmt.length) {
    if (fmt[i] !== "%") {
      text += fmt[i];
      i++;
      continue;
    }
    flush();
    i++;
    if (i >= fmt.length)
      throw new Error("printf: the format ends with a lone `%`");
    if (fmt[i] === "%") {
      parts.push("%");
      i++;
      continue;
    }
    const s = new PFSpec();
    while (i < fmt.length && "-+ #0".includes(fmt[i])) {
      const f = fmt[i];
      if (f === "-") s.minus = true;
      else if (f === "+") s.plus = true;
      else if (f === " ") s.space = true;
      else if (f === "#") s.hash = true;
      else s.zero = true;
      i++;
    }
    if (i < fmt.length && fmt[i] === "*") {
      s.width = "*";
      i++;
    } else if (i < fmt.length && fmt[i] >= "0" && fmt[i] <= "9") {
      let digits = "";
      while (i < fmt.length && fmt[i] >= "0" && fmt[i] <= "9") {
        digits += fmt[i];
        i++;
      }
      s.width = Math.min(Number(digits), 999999999);
    }
    if (i < fmt.length && fmt[i] === ".") {
      i++;
      if (i < fmt.length && fmt[i] === "*") {
        s.prec = "*";
        i++;
      } else {
        let digits = "";
        while (i < fmt.length && fmt[i] >= "0" && fmt[i] <= "9") {
          digits += fmt[i];
          i++;
        }
        // `%.f` spells an explicit precision of zero in C.
        s.prec = Math.min(Number(digits || "0"), 999999999);
      }
    }
    if (i < fmt.length && "hlLzjt".includes(fmt[i]))
      throw new Error(
        "printf: length modifiers (`h`, `l`, `ll`, `z`, ...) have no meaning in Emo"
      );
    if (i >= fmt.length)
      throw new Error("printf: the format ends with a bare `%`");
    s.conv = fmt[i];
    i++;
    if ("diuoxXcsfFeEgG".includes(s.conv)) parts.push(s);
    else if (s.conv === "a" || s.conv === "A")
      throw new Error(
        "printf: hex-float conversion `%" + s.conv + "` is not supported"
      );
    else if (s.conv === "n")
      throw new Error("printf: `%n` is not supported (it writes through pointers)");
    else if (s.conv === "p")
      throw new Error("printf: `%p` is not supported (Emo has no pointers)");
    else throw new Error("printf: unknown conversion `%" + s.conv + "`");
  }
  flush();
  return parts;
}

function pfSlots(parts: any[]): number {
  let n = 0;
  for (const p of parts) {
    if (typeof p === "string") continue;
    const s = p as PFSpec;
    n += (s.width === "*" ? 1 : 0) + (s.prec === "*" ? 1 : 0) + 1;
  }
  return n;
}

function pfDecompose(x: number): { neg: boolean; mant: bigint; exp: number } {
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, x);
  const hi = view.getUint32(0);
  const lo = view.getUint32(4);
  const neg = (hi >>> 31) === 1;
  const rawExp = (hi >>> 20) & 0x7ff;
  const frac = (BigInt(hi & 0xfffff) << 32n) | BigInt(lo);
  if (rawExp === 0) return { neg, mant: frac, exp: -1074 };
  return { neg, mant: frac | (1n << 52n), exp: rawExp - 1075 };
}

// Round q+r/d to nearest, ties to even.
function pfRound(q: bigint, r: bigint, d: bigint): bigint {
  const twice = r * 2n;
  if (twice > d) return q + 1n;
  if (twice === d) return q + (q & 1n);
  return q;
}

// sign(mant × 2^exp − 10^x), exact, over positive integers.
function pfCmpPow10(mant: bigint, exp: number, x: number): number {
  let lnum = mant;
  let lden = 1n;
  let rnum = 1n;
  let rden = 1n;
  if (exp >= 0) lnum <<= BigInt(exp);
  else lden <<= BigInt(-exp);
  if (x >= 0) {
    rnum = pfPow10(x);
  } else {
    rden = pfPow10(-x);
  }
  const l = lnum * rden;
  const r = rnum * lden;
  return l < r ? -1 : l > r ? 1 : 0;
}

function pfPow10(n: number): bigint {
  let r = 1n;
  const fives = 5n ** BigInt(n);
  // 10^n = 2^n × 5^n; the shift is cheap, the power is the work.
  return fives << BigInt(n);
}

function pfTwoDigit(n: number): string {
  return (n < 10 ? "0" : "") + n;
}

// The (Q, X) rendering of a positive value with exactly `digits`
// significant figures: value ≈ Q × 10^(X − digits + 1), Q carrying
// `digits` digits, correctly rounded (half to even). X adjusts up when
// the rounding bumps the leading digit (9.99… → 1.0…).
function pfSignificant(
  mant: bigint,
  exp: number,
  digits: number
): { q: bigint; x: number } {
  let x = Math.floor(Math.log10(Number(mant) * Math.pow(2, exp)));
  while (pfCmpPow10(mant, exp, x) < 0) x--;
  while (pfCmpPow10(mant, exp, x + 1) >= 0) x++;
  const shift = digits - 1 - x;
  let num = mant;
  let den = 1n;
  if (exp >= 0) num <<= BigInt(exp);
  else den <<= BigInt(-exp);
  if (shift >= 0) num *= pfPow10(shift);
  else den *= pfPow10(-shift);
  let q = pfRound(num / den, num % den, den);
  if (q >= pfPow10(digits)) {
    q = pfPow10(digits - 1);
    x += 1;
  }
  return { q, x };
}

// Fixed notation from a (Q, X) significant rendering.
function pfFixedFromSig(q: bigint, digits: number, x: number): string {
  const d = String(q).padStart(digits, "0");
  const point = x + 1; // digits before the decimal point
  if (point <= 0) return "0." + "0".repeat(-point) + d;
  if (point >= digits) return d + "0".repeat(point - digits);
  return d.slice(0, point) + "." + d.slice(point);
}

// Scientific notation: d.ddd…e±XX, `digits` − 1 fraction digits.
function pfSciFromSig(
  q: bigint,
  digits: number,
  x: number,
  upper: boolean,
  hash: boolean
): string {
  const d = String(q).padStart(digits, "0");
  let frac = digits > 1 ? d.slice(1) : "";
  let point = "";
  if (frac !== "") point = ".";
  else if (hash) point = ".";
  return (
    d[0] +
    point +
    frac +
    (upper ? "E" : "e") +
    (x < 0 ? "-" : "+") +
    pfTwoDigit(Math.abs(x))
  );
}

// Fixed notation for the value |x| with `prec` digits after the point,
// correctly rounded; the integer part never loses a digit.
function pfFixedPrec(mant: bigint, exp: number, prec: number): string {
  if (mant === 0n) return prec > 0 ? "0." + "0".repeat(prec) : "0";
  if (exp >= 0) {
    const int = String(mant << BigInt(exp));
    return prec > 0 ? int + "." + "0".repeat(prec) : int;
  }
  let num = mant * pfPow10(prec);
  const den = 1n << BigInt(-exp);
  const q = pfRound(num / den, num % den, den);
  const s = String(q).padStart(prec + 1, "0");
  return prec > 0
    ? s.slice(0, s.length - prec) + "." + s.slice(s.length - prec)
    : s.slice(0, s.length - prec);
}

// The padded rendering of one float conversion (f/F/e/E/g/G).
function pfFloat(
  x: number,
  s: PFSpec,
  minus: boolean,
  zero: boolean,
  width: number,
  prec: number | null
): string {
  const upper = s.conv === "F" || s.conv === "E" || s.conv === "G";
  const neg = pfDecompose(x).neg;
  let sign = neg ? "-" : s.plus ? "+" : s.space ? " " : "";
  let body: string;
  if (!Number.isFinite(x)) {
    body = Number.isNaN(x) ? "nan" : "inf";
    if (upper) body = body.toUpperCase();
    // The 0 flag has no effect on inf and nan.
    const total = sign + body;
    if (width > total.length) {
      if (minus) return total + " ".repeat(width - total.length);
      return " ".repeat(width - total.length) + total;
    }
    return total;
  }
  const { mant, exp } = pfDecompose(x);
  if (s.conv === "f" || s.conv === "F") {
    const p = prec === null ? 6 : prec;
    body = pfFixedPrec(mant, exp, p);
    // '#' keeps the decimal point even with an explicit precision of
    // zero.
    if (s.hash && p === 0 && !body.includes(".")) body += ".";
  } else if (s.conv === "e" || s.conv === "E") {
    const p = prec === null ? 6 : prec;
    const sig = pfSignificant(mant, exp, p + 1);
    body = pfSciFromSig(sig.q, p + 1, sig.x, upper, s.hash);
  } else {
    let p = prec === null ? 6 : prec;
    if (p === 0) p = 1; // C: a %g precision of zero is taken as one.
    if (mant === 0n) {
      // %g of zero: style f, all fraction digits stripped unless #.
      body = s.hash ? "0." + "0".repeat(p - 1) : "0";
    } else {
      const sig = pfSignificant(mant, exp, p);
      if (sig.x >= -4 && sig.x < p) {
        body = pfFixedFromSig(sig.q, p, sig.x);
        if (!s.hash) {
          const dot = body.indexOf(".");
          if (dot >= 0) {
            body = body.replace(/0+$/, "");
            if (body.endsWith(".")) body = body.slice(0, -1);
          }
        }
      } else {
        body = pfSciFromSig(sig.q, p, sig.x, upper, s.hash);
        if (!s.hash) {
          const eAt = body.indexOf(upper ? "E" : "e");
          let mantissa = body.slice(0, eAt);
          const expPart = body.slice(eAt);
          if (mantissa.includes(".")) {
            mantissa = mantissa.replace(/0+$/, "");
            if (mantissa.endsWith(".")) mantissa = mantissa.slice(0, -1);
          }
          body = mantissa + expPart;
        }
      }
    }
  }
  const total = sign + body;
  if (width > total.length) {
    if (minus) return total + " ".repeat(width - total.length);
    if (zero) return sign + "0".repeat(width - total.length) + body;
    return " ".repeat(width - total.length) + total;
  }
  return total;
}

function printf(fmt: any, data: any): void {
  if (typeof fmt !== "string")
    throw new Error("`printf` expects (format String, data Array)");
  if (!(data instanceof EArray))
    throw new Error(
      "`printf` expects (format String, data Array), got " + tag(data) + " as data"
    );
  const parts = pfParse(fmt);
  const items = data.items;
  if (pfSlots(parts) !== items.length)
    throw new Error(
      "printf: the format consumes " +
        pfSlots(parts) +
        " argument(s), the array has " +
        items.length +
        " element(s)"
    );
  let idx = 0;
  const pull = (): any => items[idx++];
  const pullI64 = (conv: string): any => {
    const v = pull();
    if (typeof v === "bigint") return v;
    if (typeof v === "number" && Number.isInteger(v)) return BigInt(v);
    throw new Error(
      "printf: `%" +
        conv +
        "` expects " +
        (conv === "c"
          ? "a Char, Byte, or Int64"
          : conv === "s"
          ? "a String"
          : "fFeEgG".includes(conv)
          ? "a Float64"
          : "an Int64") +
        ", got " +
        tag(v)
    );
  };
  let out = "";
  for (const p of parts) {
    if (typeof p === "string") {
      out += p;
      continue;
    }
    const s = p as PFSpec;
    let minus = s.minus;
    let width: number;
    if (s.width === "*") {
      width = pfStarWidth(pull());
      // C: a negative width via `*` means left-align with the absolute
      // value.
      if (width < 0) {
        minus = true;
        width = -width;
      }
    } else width = s.width === null ? 0 : (s.width as number);
    let prec: number | null =
      s.prec === "*" ? pfStarPrec(pull()) : (s.prec as number | null);
    if (s.conv === "%") {
      out += "%";
      continue;
    }
    const v = pull();
    if ("diuoxX".includes(s.conv)) {
      if (typeof v !== "bigint" && !(typeof v === "number" && Number.isInteger(v)))
        throw new Error(
          "printf: `%" + s.conv + "` expects an Int64, got " + tag(v)
        );
      const n: bigint = typeof v === "bigint" ? v : BigInt(v);
      let body: string;
      if (s.conv === "d" || s.conv === "i") {
        body = BigInt.asIntN(64, n).toString();
      } else if (s.conv === "u") {
        body = BigInt.asUintN(64, n).toString();
      } else if (s.conv === "o") {
        body = BigInt.asUintN(64, n).toString(8);
      } else if (s.conv === "x") {
        body = BigInt.asUintN(64, n).toString(16);
      } else {
        body = BigInt.asUintN(64, n).toString(16).toUpperCase();
      }
      // '#' prefixes 0, 0x, 0X on o/x/X when the value is nonzero.
      if (s.hash && n !== 0n) {
        if (s.conv === "o") body = "0" + body;
        else if (s.conv === "x") body = "0x" + body;
        else if (s.conv === "X") body = "0X" + body;
      }
      let sign = "";
      if (s.conv === "d" || s.conv === "i") {
        const neg = body.startsWith("-");
        if (neg) {
          sign = "-";
          body = body.slice(1);
        } else if (s.plus) sign = "+";
        else if (s.space) sign = " ";
      }
      out += pfPad(sign, body, minus, s.zero, width);
    } else if (s.conv === "c") {
      let byte: number;
      if (v instanceof EChar) byte = v.c.charCodeAt(0);
      else if (typeof v === "number" && Number.isInteger(v)) byte = v & 0xff;
      else if (typeof v === "bigint") byte = Number(v & 0xffn);
      else
        throw new Error(
          "printf: `%c` expects a Char, Byte, or Int64, got " + tag(v)
        );
      const ch = String.fromCharCode(byte);
      if (width > ch.length) {
        if (minus) out += ch + " ".repeat(width - 1);
        else out += " ".repeat(width - 1) + ch;
      } else out += ch;
    } else if (s.conv === "s") {
      if (typeof v !== "string")
        throw new Error("printf: `%s` expects a String, got " + tag(v));
      let bytes = utf8Encode(v);
      if (prec !== null && prec < bytes.length) bytes = bytes.slice(0, prec);
      const missing = width - bytes.length;
      if (missing > 0 && !minus) out += " ".repeat(missing);
      out += utf8Decode(bytes);
      if (missing > 0 && minus) out += " ".repeat(missing);
    } else {
      if (!(v instanceof EFloat))
        throw new Error(
          "printf: `%" + s.conv + "` expects a Float64, got " + tag(v)
        );
      out += pfFloat(v.v, s, minus, s.zero, width, prec);
    }
  }
  process.stdout.write(out);
}

function pfStarWidth(v: any): number {
  if (typeof v === "bigint") return Number(v);
  if (typeof v === "number" && Number.isInteger(v)) return v;
  throw new Error("printf: `%*` expects an Int64, got " + tag(v));
}

function pfStarPrec(v: any): number | null {
  const n = pfStarWidth(v);
  // C17: a negative precision through `*` is treated as omitted.
  return n < 0 ? null : n;
}

// Numeric padding with sign and zero-fill (integers and floats).
function pfPad(
  sign: string,
  body: string,
  minus: boolean,
  zero: boolean,
  width: number
): string {
  const total = sign + body;
  if (width <= total.length) return total;
  const fill = width - total.length;
  if (minus) return total + " ".repeat(fill);
  if (zero) return sign + "0".repeat(fill) + body;
  return " ".repeat(fill) + total;
}


function tag(v: any): string {
  if (typeof v === "number") return Number.isInteger(v) ? "Byte" : "Float64";
  if (typeof v === "bigint") return "Int64";
  if (typeof v === "string") return "String";
  if (typeof v === "boolean") return "Bool";
  if (isFloat(v)) return "Float64";
  if (isChar(v)) return "Char";
  if (v instanceof ETuple) return "Tuple";
  if (v instanceof EArray) return "Array";
  if (v instanceof EMap) return "Map";
  if (v instanceof EEnum) return "Enum";
  if (v instanceof EBox) return "Box";
  if (v instanceof EBytes) return "Bytes";
  if (v instanceof EList) return "List";
  return "an instance";
}

// Predicate-method and interface names arrive sanitized (? → _q) at
// the definition site; dispatch tries the plain name first, then the
// sanitized one.
function sanitize(name: string): string {
  return name.split("?").join("_q");
}

function unfloat(x: any): number {
  return isFloat(x) ? x.v : (x as number);
}

function bothInt(a: any, b: any): boolean {
  if (isI64(a) && isI64(b)) return true;
  return isInt(a) && isInt(b);
}

function wrap64(x: bigint): bigint {
  return BigInt.asIntN(64, x);
}

const E: any = {
  float: (v: number) => new EFloat(v),
  char: (c: string) => new EChar(c),
  tuple: (...items: any[]) => new ETuple(items),
  array: (items: any[]) => new EArray(items),
  box: (v: any) => new EBox(v),
  bytesNew: (n: any) => {
    const len = num(n);
    if (!Number.isInteger(len) || len < 0)
      throw new Error("`Bytes.new` needs a non-negative Int64 length");
    return new EBytes(len);
  },
  listNew: (arr: any) => {
    if (!(arr instanceof EArray))
      throw new Error("`List.new` expects an Array, got " + tag(arr));
    const l = new EList();
    for (const item of arr.items) listPushBack(l, item);
    return l;
  },
  enum_: (type: string, member: string) => new EEnum(type, member),

  eq: deepEq,
  ne: (a: any, b: any) => !deepEq(a, b),
  truthy: (b: any) => b === true,
  println,
  printf,
  interpolate: (items: any[]) => items.map(toStr).join(""),
  toStr,

  // The Map's constructor: (key, value) tuple pairs, in insertion
  // order; a later pair overwrites an earlier one.
  mapNew(pairs: any[]): EMap {
    const m = new EMap();
    for (const p of pairs) {
      if (!(p instanceof ETuple) || p.items.length !== 2)
        throw new Error("`Map.new` takes (key, value) pairs of two elements");
      m.entries.set(emoMapKey(p.items[0]), [p.items[0], p.items[1]]);
    }
    return m;
  },

  add(a: any, b: any) {
    if (typeof a === "string" && typeof b === "string") return a + b;
    if (isI64(a) && isI64(b)) return wrap64((a as bigint) + (b as bigint));
    if (bothInt(a, b)) return (a as number) + (b as number);
    return new EFloat(unfloat(a) + unfloat(b));
  },
  sub(a: any, b: any) {
    if (isI64(a) && isI64(b)) return wrap64((a as bigint) - (b as bigint));
    if (bothInt(a, b)) return (a as number) - (b as number);
    return new EFloat(unfloat(a) - unfloat(b));
  },
  mul(a: any, b: any) {
    if (isI64(a) && isI64(b)) return wrap64((a as bigint) * (b as bigint));
    if (bothInt(a, b)) return (a as number) * (b as number);
    return new EFloat(unfloat(a) * unfloat(b));
  },
  div(a: any, b: any) {
    if (isI64(a) && isI64(b)) return E.i64Div(a as bigint, b as bigint);
    if (bothInt(a, b)) return Math.trunc((a as number) / (b as number));
    return new EFloat(unfloat(a) / unfloat(b));
  },
  mod(a: any, b: any) {
    if (isI64(a) && isI64(b)) return E.i64Mod(a as bigint, b as bigint);
    if (bothInt(a, b)) return (a as number) % (b as number);
    return new EFloat(unfloat(a) % unfloat(b));
  },
  // Bitwise work is integer work. JS bitwise ops run on int32, so
  // results past 2^31 follow the platform's word — the width family
  // (Int64/Byte) carries the exact contract later.
  requireInt(v: any, op: string): number {
    if (!isInt(v)) throw new EEmoException(`operator \`${op}\` expects an Int64, got ${tag(v)}`);
    return v as number;
  },
  bitAnd(a: any, b: any) {
    if (isI64(a) && isI64(b)) return wrap64((a as bigint) & (b as bigint));
    return this.requireInt(a, "&") & this.requireInt(b, "&");
  },
  bitOr(a: any, b: any) {
    if (isI64(a) && isI64(b)) return wrap64((a as bigint) | (b as bigint));
    return this.requireInt(a, "|") | this.requireInt(b, "|");
  },
  bitXor(a: any, b: any) {
    if (isI64(a) && isI64(b)) return wrap64((a as bigint) ^ (b as bigint));
    return this.requireInt(a, "^") ^ this.requireInt(b, "^");
  },
  shl(a: any, b: any) {
    if (isI64(a) && isI64(b)) return E.i64Shl(a as bigint, b as bigint);
    const n = this.requireInt(b, "<<");
    if (n < 0) throw new EEmoException("shift count must be non-negative");
    return this.requireInt(a, "<<") << n;
  },
  shr(a: any, b: any) {
    if (isI64(a) && isI64(b)) return E.i64Shr(a as bigint, b as bigint);
    const n = this.requireInt(b, ">>");
    if (n < 0) throw new EEmoException("shift count must be non-negative");
    return this.requireInt(a, ">>") >> n;
  },
  bitNot(a: any) {
    if (isI64(a)) return wrap64(~(a as bigint));
    return ~this.requireInt(a, "~");
  },
  neg(a: any) {
    if (isInt(a)) return -(a as number);
    return new EFloat(-unfloat(a));
  },
  lt(a: any, b: any) {
    return unfloat(a) < unfloat(b);
  },
  le(a: any, b: any) {
    return unfloat(a) <= unfloat(b);
  },
  gt(a: any, b: any) {
    return unfloat(a) > unfloat(b);
  },
  ge(a: any, b: any) {
    return unfloat(a) >= unfloat(b);
  },

  // The fixed-width family. Int64 values are BigInts — arithmetic wraps
  // in two's complement at 64 bits; Byte values are numbers that wrap
  // modulo 256. Comparisons reuse lt/le/gt/ge: JS reads BigInts and
  // numbers natively, so only the producing operators need a path.
  i64Add: (a: bigint, b: bigint) => BigInt.asIntN(64, a + b),
  i64Sub: (a: bigint, b: bigint) => BigInt.asIntN(64, a - b),
  i64Mul: (a: bigint, b: bigint) => BigInt.asIntN(64, a * b),
  i64Div: (a: bigint, b: bigint) => {
    if (b === 0n) throw new EEmoException("division by zero");
    return BigInt.asIntN(64, a / b);
  },
  i64Mod: (a: bigint, b: bigint) => {
    if (b === 0n) throw new EEmoException("division by zero");
    return BigInt.asIntN(64, a % b);
  },
  i64BitAnd: (a: bigint, b: bigint) => BigInt.asIntN(64, a & b),
  i64BitOr: (a: bigint, b: bigint) => BigInt.asIntN(64, a | b),
  i64BitXor: (a: bigint, b: bigint) => BigInt.asIntN(64, a ^ b),
  i64Shl: (a: bigint, b: bigint) => {
    if (b < 0n) throw new EEmoException("shift count must be non-negative");
    return b >= 64n ? 0n : BigInt.asIntN(64, a << b);
  },
  i64Shr: (a: bigint, b: bigint) => {
    if (b < 0n) throw new EEmoException("shift count must be non-negative");
    return b >= 64n ? (a < 0n ? -1n : 0n) : a >> b;
  },
  i64BitNot: (a: bigint) => BigInt.asIntN(64, ~a),
  i64Neg: (a: bigint) => BigInt.asIntN(64, -a),

  byteAdd: (a: number, b: number) => (a + b) & 0xff,
  byteSub: (a: number, b: number) => (a - b) & 0xff,
  byteMul: (a: number, b: number) => (a * b) & 0xff,
  byteDiv: (a: number, b: number) => {
    if (b === 0) throw new EEmoException("division by zero");
    return (a / b) | 0;
  },
  byteMod: (a: number, b: number) => {
    if (b === 0) throw new EEmoException("division by zero");
    return a % b;
  },
  byteBitAnd: (a: number, b: number) => a & b,
  byteBitOr: (a: number, b: number) => a | b,
  byteBitXor: (a: number, b: number) => a ^ b,
  byteShl: (a: number, b: number) => (b >= 8 ? 0 : (a << b) & 0xff),
  byteShr: (a: number, b: number) => (b >= 8 ? 0 : a >> b),
  byteBitNot: (a: number) => ~a & 0xff,

  index(coll: any, i: any): any {
    const items: any[] =
      coll instanceof EArray ? coll.items : (coll as ETuple).items;
    // The index is an Int64 (BigInt); the collection is JS-native.
    const n = typeof i === "bigint" ? Number(i) : (i as number);
    if (n < 0 || n >= items.length)
      throw new Error("index " + i + " is out of bounds");
    return items[n];
  },

  callValue(f: any, args: any[]): any {
    return f(...args);
  },

  // Method dispatch: instances by property, builtins by shape — one
  // table, like the native runtime's method_call.
  method(recv: any, name: string, args: any[]): any {
    if (recv && typeof recv === "object") {
      const direct = recv[name] ?? recv[sanitize(name)];
      if (typeof direct === "function") return direct.apply(recv, args);
      // A field can shadow a prototype method (same name): when the
      // own property is not a function, try the prototype's.
      const proto = Object.getPrototypeOf(recv) as any;
      const protoM = proto ? proto[name] ?? proto[sanitize(name)] : undefined;
      if (typeof protoM === "function") return protoM.apply(recv, args);
      if (name === "read" && recv instanceof EBox) return recv.v;
      if (name === "replace" && recv instanceof EBox) {
        recv.v = args[0];
        return args[0];
      }
      if (recv instanceof EBytes) {
        const d = recv.data;
        const idx = (mname2: string) => {
          const i = num(args[0]);
          if (!Number.isInteger(i))
            throw new Error("`" + mname2 + "` expects an Int64 index");
          if (i < 0 || i >= d.length)
            throw new Error(
              "index " + i + " is out of bounds for a length-" + d.length + " Bytes"
            );
          return i;
        };
        if (name === "length") return BigInt(d.length);
        if (name === "get") return BigInt(d[idx(name)]);
        if (name === "set") {
          const i = idx(name);
          const v = num(args[1]);
          if (!Number.isInteger(v) || v < 0 || v > 255)
            throw new Error("`set` expects a byte value in 0-255");
          d[i] = v;
          return BigInt(v);
        }
        if (name === "get_u16_le" || name === "get_u32_le") {
          const w = name === "get_u16_le" ? 2 : 4;
          const i = idx(name);
          let acc = 0;
          for (let k = w - 1; k >= 0; k--) acc = (acc << 8) | d[i + k];
          return BigInt(acc);
        }
        if (name === "set_u16_le" || name === "set_u32_le") {
          const w = name === "set_u16_le" ? 2 : 4;
          const i = idx(name);
          let v = num(args[1]);
          if (!Number.isInteger(v))
            throw new Error("`" + name + "` expects an Int64 value");
          v = v >>> 0;
          for (let k = 0; k < w; k++) d[i + k] = (v >>> (8 * k)) & 0xff;
          return BigInt(w === 2 ? v & 0xffff : v >>> 0);
        }
        if (name === "get_u64_le" || name === "set_u64_le") {
          const i = num(args[0]);
          if (typeof i !== "number" || i < 0 || i + 8 > d.length)
            throw new Error(
              "index " + args[0] + " is out of bounds for a " + name + " " +
                (name === "get_u64_le" ? "read" : "write")
            );
          if (name === "get_u64_le") {
            let acc = 0n;
            for (let k = 7; k >= 0; k--)
              acc = (acc << 8n) | BigInt(d[i + k]);
            return BigInt.asIntN(64, acc);
          }
          const v = args[1];
          if (typeof v !== "bigint")
            throw new Error("`set_u64_le` expects an Int64 value");
          const w = BigInt.asUintN(64, v);
          for (let k = 0; k < 8; k++)
            d[i + k] = Number((w >> BigInt(8 * k)) & 0xffn);
          return BigInt.asIntN(64, v);
        }
        if (name === "to_string") {
          return utf8Decode(d);
        }
      }
      if (isFloat(recv) && name === "to_bits") {
        const buf = new ArrayBuffer(8);
        const dv = new DataView(buf);
        dv.setFloat64(0, recv.v, true);
        return dv.getBigInt64(0, true);
      }
      if (recv instanceof EList) {
        if (name === "push_front") return listPushFront(recv, args[0]);
        if (name === "push_back") return listPushBack(recv, args[0]);
        if (name === "pop_front") return listPopFront(recv);
        if (name === "pop_back") return listPopBack(recv);
        if (name === "length") return BigInt(recv.size);
        if (name === "to_string") return toStr(recv);
      }
      if (name === "length" && recv instanceof EArray)
        return BigInt(recv.items.length);
      if (name === "append" && recv instanceof EArray)
        return new EArray(recv.items.concat([args[0]]));
      if (recv instanceof EMap) {
        if (name === "get") {
          const hit = recv.entries.get(emoMapKey(args[0]));
          if (!hit)
            throw new Error("no key " + toStrDbg(args[0]) + " in this Map");
          return hit[1];
        }
        if (name === "set") {
          recv.entries.set(emoMapKey(args[0]), [args[0], args[1]]);
          return recv;
        }
        if (name === "has") {
          if (!isMapKey(args[0])) return false;
          return recv.entries.has(emoMapKey(args[0]));
        }
        if (name === "remove") {
          if (isMapKey(args[0])) recv.entries.delete(emoMapKey(args[0]));
          return recv;
        }
        if (name === "length") return BigInt(recv.entries.size);
        if (name === "keys")
          return new EArray(
            [...recv.entries.values()].map((kv: [any, any]) => kv[0])
          );
        if (name === "values")
          return new EArray(
            [...recv.entries.values()].map((kv: [any, any]) => kv[1])
          );
        if (name === "to_string") return toStr(recv);
      }
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "number") {
      if (name === "to_string") return String(recv);
      // A Byte receiver is a plain number; to_int64 widens to Int64.
      if (name === "to_int64") return BigInt(recv);
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "bigint") {
      if (name === "to_string") return recv.toString();
      if (name === "to_byte") return Number(BigInt.asUintN(8, recv));
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "boolean") {
      if (name === "to_string") return recv ? "true" : "false";
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "string") {
      if (name === "length") return BigInt(recv.length);
      if (name === "to_string") return recv;
      if (name === "is") return isType(recv, args[0] as string);
      if (name === "substring") {
        const start = num(args[0]);
        const len = num(args[1]);
        if (start < 0 || len < 0 || start + len > recv.length)
          throw new Error("`substring` expects (start Int64, length Int64) in bounds");
        return recv.substr(start, len);
      }
      if (name === "split") {
        const sep = args[0] as string;
        if (sep === "")
          throw new Error("`split` expects a non-empty String separator");
        return new EArray(recv.split(sep));
      }
      if (name === "trim") return recv.trim();
      if (name === "lower") return recv.toLowerCase();
      if (name === "index_of") return BigInt(recv.indexOf(args[0] as string));
      if (name === "starts_with") return recv.startsWith(args[0] as string);
      if (name === "to_int64") {
        const body = recv.startsWith("-") ? recv.slice(1) : recv;
        if (body === "" || !/^[0-9]+$/.test(body))
          throw new Error("cannot parse `" + recv + "` as an Int64");
        const v = BigInt(recv);
        if (BigInt.asIntN(64, v) !== v)
          throw new Error("cannot parse `" + recv + "` as an Int64");
        return v;
      }
      if (name === "to_bytes") {
        const enc = utf8Encode(recv);
        const out = new EBytes(enc.length);
        out.data.set(enc);
        return out;
      }
      // Static constructors: a type name is a bare string in value
      // position, told apart from a String by the method asked for.
      if (name === "from_int64") {
        if (recv === "Int64") return args[0];
        if (recv === "Byte") {
          const n = args[0] as bigint;
          if (n < 0n || n > 255n)
            throw new EEmoException(
              "`Byte.from_int64` needs a value in 0-255, got " + n
            );
          return Number(n);
        }
      }
      if (name === "from_bits" && recv === "Float64") {
        const buf = new ArrayBuffer(8);
        const dv = new DataView(buf);
        dv.setBigInt64(0, args[0] as bigint, true);
        return new EFloat(dv.getFloat64(0, true));
      }
    }
    throw new Error(
      "NoMethodError: `" + toStr(recv) + "` has no method `" + name + "`"
    );
  },

  caseError(v: any): never {
    throw new Error("no `case` branch matched this " + tag(v) + " value");
  },

  throwException(msg: any, data: any = E.mapNew([])): never {
    throw new EEmoException(msg, data);
  },

  renderError(e: any): string {
    if (e instanceof EEmoException)
      return "error[E3010]: uncaught exception: " + toStr(e.messageValue);
    return "error[E3010]: uncaught exception: " + (e && e.message);
  },

  // Registered by the emitted program: interface name → method/arity
  // list, for `is` narrowing against interfaces.
  interfaces: {} as Record<string, [string, number][]>,

  // ---- Processes ----

  spawn(task: () => Promise<any>): EPid {
    const pid = new EPid(_nextPid++);
    _mailboxes.set(pid.id, []);
    _als.run({ pid: pid.id }, () => {
      (async () => task())().catch((e) => _taskError(e));
    });
    return pid;
  },

  self(): EPid {
    const st = _als.getStore();
    if (!st) throw new Error("self_pid() outside a process");
    return new EPid(st.pid);
  },

  send(to: any, msg: any): any {
    const id = to instanceof EPid ? to.id : to;
    const waiter = _waiters.get(id);
    const q = _mailboxes.get(id) || [];
    if (waiter) {
      _waiters.delete(id);
      waiter(msg);
    } else {
      q.push(msg);
    }
    return msg;
  },

  // Selective receive: the dispatch runs each branch's body for the
  // first message it matches (returning anything but false); non-
  // matching messages stay in the mailbox in order; no match means the
  // task waits for the next delivery.
  async receive(dispatch: (msg: any) => Promise<any>): Promise<any> {
    const pid = _als.getStore()!.pid;
    for (;;) {
      const q = _mailboxes.get(pid)!;
      let i = 0;
      while (i < q.length) {
        const msg = q[i];
        q.splice(i, 1);
        const r = await dispatch(msg);
        if (r !== false) return r;
        q.splice(i, 0, msg);
        i++;
      }
      // Queue drained: the next delivery resolves us directly with the
      // message (send hands it to the waiter, not to the mailbox).
      const fresh = await new Promise<any>((res) => _waiters.set(pid, res));
      const r = await dispatch(fresh);
      if (r !== false) return r;
      // No branch took it: keep it at the head so FIFO order holds.
      q.unshift(fresh);
    }
  },

  halt(): never {
    throw new EHalt();
  },

  // Runs the entry under the main process (pid 0). Spawned tasks run
  // on the event loop; the program ends when the entry ends.
  runMain(entry: () => Promise<any>): Promise<void> {
    const pid = _nextPid++;
    _mailboxes.set(pid, []);
    return _als.run({ pid }, async () => {
      try {
        await entry();
      } catch (e) {
        _taskError(e);
      }
    });
  },
};

// `is` narrowing: an interface check when one is registered under the
// name, a class-name compare otherwise.
function isType(recv: any, typeName: string): boolean {
  if (recv === null || recv === undefined) return false;
  const sigs = E.interfaces[typeName];
  if (sigs) {
    return sigs.every(([m, arity]) => {
      const f = recv[m];
      return typeof f === "function" && f.length === arity;
    });
  }
  const cls = recv.constructor && recv.constructor.__emo;
  return cls === typeName;
}
