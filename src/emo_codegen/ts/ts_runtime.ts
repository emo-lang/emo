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
  constructor(messageValue: any) {
    super("uncaught exception");
    this.messageValue = messageValue;
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
  if (a instanceof EEnum && b instanceof EEnum)
    return a.type === b.type && a.member === b.member;
  if (a instanceof EBytes && b instanceof EBytes)
    return (
      a.data.length === b.data.length &&
      a.data.every((x: number, i: number) => x === b.data[i])
    );
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

// The one stringification rule: interpolation and `.to_string()` share
// it, exactly like the interpreter.
function toStr(v: any): string {
  if (typeof v === "number") return String(v);
  if (typeof v === "string") return v;
  if (typeof v === "boolean") return v ? "true" : "false";
  if (v === null || v === undefined) return "nil";
  if (isFloat(v)) return floatStr(v.v);
  if (isChar(v)) return v.c;
  if (v instanceof EBox) return toStr(v.v);
  if (v instanceof EBytes) return "Bytes[" + v.data.length + "]";
  if (v instanceof ETuple) return "(" + v.items.map(toStr).join(", ") + ")";
  if (v instanceof EArray) return "[" + v.items.map(toStr).join(", ") + "]";
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

function tag(v: any): string {
  if (typeof v === "number") return Number.isInteger(v) ? "Int" : "Float";
  if (typeof v === "string") return "String";
  if (typeof v === "boolean") return "Bool";
  if (isFloat(v)) return "Float";
  if (isChar(v)) return "Char";
  if (v instanceof ETuple) return "Tuple";
  if (v instanceof EArray) return "Array";
  if (v instanceof EEnum) return "Enum";
  if (v instanceof EBox) return "Box";
  if (v instanceof EBytes) return "Bytes";
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
  return isInt(a) && isInt(b);
}

const E: any = {
  float: (v: number) => new EFloat(v),
  char: (c: string) => new EChar(c),
  tuple: (...items: any[]) => new ETuple(items),
  array: (items: any[]) => new EArray(items),
  box: (v: any) => new EBox(v),
  bytesNew: (n: any) => {
    if (!isInt(n) || (n as number) < 0)
      throw new Error("`Bytes.new` needs a non-negative Int length");
    return new EBytes(n as number);
  },
  enum_: (type: string, member: string) => new EEnum(type, member),

  eq: deepEq,
  ne: (a: any, b: any) => !deepEq(a, b),
  truthy: (b: any) => b === true,
  println,
  interpolate: (items: any[]) => items.map(toStr).join(""),
  toStr,

  add(a: any, b: any) {
    if (typeof a === "string" && typeof b === "string") return a + b;
    if (bothInt(a, b)) return (a as number) + (b as number);
    return new EFloat(unfloat(a) + unfloat(b));
  },
  sub(a: any, b: any) {
    if (bothInt(a, b)) return (a as number) - (b as number);
    return new EFloat(unfloat(a) - unfloat(b));
  },
  mul(a: any, b: any) {
    if (bothInt(a, b)) return (a as number) * (b as number);
    return new EFloat(unfloat(a) * unfloat(b));
  },
  div(a: any, b: any) {
    if (bothInt(a, b)) return Math.trunc((a as number) / (b as number));
    return new EFloat(unfloat(a) / unfloat(b));
  },
  mod(a: any, b: any) {
    if (bothInt(a, b)) return (a as number) % (b as number);
    return new EFloat(unfloat(a) % unfloat(b));
  },
  // Bitwise work is integer work. JS bitwise ops run on int32, so
  // results past 2^31 follow the platform's word — the width family
  // (Int64/Byte) carries the exact contract later.
  requireInt(v: any, op: string): number {
    if (!isInt(v)) throw new EEmoException(`operator \`${op}\` expects an Int, got ${tag(v)}`);
    return v as number;
  },
  bitAnd(a: any, b: any) {
    return this.requireInt(a, "&") & this.requireInt(b, "&");
  },
  bitOr(a: any, b: any) {
    return this.requireInt(a, "|") | this.requireInt(b, "|");
  },
  bitXor(a: any, b: any) {
    return this.requireInt(a, "^") ^ this.requireInt(b, "^");
  },
  shl(a: any, b: any) {
    const n = this.requireInt(b, "<<");
    if (n < 0) throw new EEmoException("shift count must be non-negative");
    return this.requireInt(a, "<<") << n;
  },
  shr(a: any, b: any) {
    const n = this.requireInt(b, ">>");
    if (n < 0) throw new EEmoException("shift count must be non-negative");
    return this.requireInt(a, ">>") >> n;
  },
  bitNot(a: any) {
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

  index(coll: any, i: any): any {
    const items: any[] =
      coll instanceof EArray ? coll.items : (coll as ETuple).items;
    const n = i as number;
    if (n < 0 || n >= items.length)
      throw new Error("index " + n + " is out of bounds");
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
      if (name === "read" && recv instanceof EBox) return recv.v;
      if (name === "replace" && recv instanceof EBox) {
        recv.v = args[0];
        return args[0];
      }
      if (recv instanceof EBytes) {
        const d = recv.data;
        const idx = (mname2: string) => {
          if (typeof args[0] !== "number" || !Number.isInteger(args[0]))
            throw new Error("`" + mname2 + "` expects an Int index");
          if (args[0] < 0 || args[0] >= d.length)
            throw new Error(
              "index " + args[0] + " is out of bounds for a length-" + d.length + " Bytes"
            );
          return args[0] as number;
        };
        if (name === "length") return d.length;
        if (name === "get") return d[idx(name)];
        if (name === "set") {
          const i = idx(name);
          const v = args[1] as number;
          if (!Number.isInteger(v) || v < 0 || v > 255)
            throw new Error("`set` expects a byte value in 0-255");
          d[i] = v;
          return v;
        }
        if (name === "get_u16_le" || name === "get_u32_le") {
          const w = name === "get_u16_le" ? 2 : 4;
          const i = args[0] as number;
          if (
            typeof i !== "number" ||
            i < 0 ||
            i + w > d.length
          )
            throw new Error(
              "index " + args[0] + " is out of bounds for a " + name + " read"
            );
          let acc = 0;
          for (let k = w - 1; k >= 0; k--) acc = (acc << 8) | d[i + k];
          return acc;
        }
        if (name === "set_u16_le" || name === "set_u32_le") {
          const w = name === "set_u16_le" ? 2 : 4;
          const i = args[0] as number;
          let v = args[1] as number;
          if (
            typeof i !== "number" ||
            i < 0 ||
            i + w > d.length
          )
            throw new Error(
              "index " + args[0] + " is out of bounds for a " + name + " write"
            );
          if (!Number.isInteger(v))
            throw new Error("`" + name + "` expects an Int value");
          v = v >>> 0;
          for (let k = 0; k < w; k++) d[i + k] = (v >>> (8 * k)) & 0xff;
          return w === 2 ? v & 0xffff : v >>> 0;
        }
        if (name === "to_string") {
          let s = "";
          for (let i = 0; i < d.length; i++) s += String.fromCharCode(d[i]);
          return s;
        }
      }
      if (name === "length" && recv instanceof EArray)
        return recv.items.length;
      if (name === "append" && recv instanceof EArray)
        return new EArray(recv.items.concat([args[0]]));
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "number") {
      if (name === "to_string") return String(recv);
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "boolean") {
      if (name === "to_string") return recv ? "true" : "false";
      if (name === "is") return isType(recv, args[0] as string);
    }
    if (typeof recv === "string") {
      if (name === "length") return recv.length;
      if (name === "to_string") return recv;
      if (name === "is") return isType(recv, args[0] as string);
      if (name === "substring") {
        const start = args[0] as number;
        const len = args[1] as number;
        if (
          start < 0 ||
          len < 0 ||
          start + len > recv.length
        )
          throw new Error("`substring` expects (start Int, length Int) in bounds");
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
      if (name === "index_of") return recv.indexOf(args[0] as string);
      if (name === "starts_with") return recv.startsWith(args[0] as string);
      if (name === "to_int") {
        const body = recv.startsWith("-") ? recv.slice(1) : recv;
        if (body === "" || !/^[0-9]+$/.test(body))
          throw new Error("cannot parse `" + recv + "` as an Int");
        return parseInt(recv, 10);
      }
      if (name === "to_bytes") {
        const out = new EBytes(recv.length);
        for (let i = 0; i < recv.length; i++)
          out.data[i] = recv.charCodeAt(i) & 0xff;
        return out;
      }
    }
    throw new Error(
      "NoMethodError: `" + toStr(recv) + "` has no method `" + name + "`"
    );
  },

  caseError(v: any): never {
    throw new Error("no `case` branch matched this " + tag(v) + " value");
  },

  throwException(msg: any): never {
    throw new EEmoException(msg);
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
