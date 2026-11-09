// The canonical wasm host: the Node program an Emo WasmGC module runs
// under. It supplies every `emo` import the compiler emits — the three
// the module always needs (println, abort, float_str) and the
// file-system syscalls the file/os packages lower to — then calls the
// exported main. `emo run --target wasm` writes this file beside a temp
// copy of the artifact; a hand-rolled host implements exactly the
// imports below (docs/demo-targets.md keeps the table).
//
// The exchange protocol: string arguments cross as (ptr, len) into the
// exported linear memory; each syscall answers (tag, size) — tag 0 ok,
// tag 1 error — and the answer (the contents, or the reason text the
// host formatted whole) waits in `pending` for the guest's fetch call,
// which copies it into a buffer the guest bump-allocated. A
// count-bearing syscall answers (tag, i64 count) with the payload size
// riding the count on the error path (i64s cross as BigInt).
//
// Memory layout: the guest's bump allocator starts at 65536, so page 0
// below it stays the host's — float_str writes its answer at the fixed
// scratch 60000 and the guest copies it back out.
import { readFile } from "node:fs/promises";
import { readFileSync, writeFileSync, writeSync, readSync, openSync, closeSync, readdirSync, mkdirSync, rmdirSync, unlinkSync, renameSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { randomBytes } from "node:crypto";

// stdout through writeSync: the abort path exits mid-stream, and a
// buffered write lost to process.exit would truncate a program's own
// final lines.
const out = (s) => writeSync(1, s);

// The strerror texts the goldens pin — Node's error codes spelled the
// way C's strerror spells them. Codes outside the table fall back to
// the code name, the honest answer for an errno the golden set never
// reaches.
const STRERROR = {
  ENOENT: "No such file or directory",
  EISDIR: "Is a directory",
  ENOTDIR: "Not a directory",
  EACCES: "Permission denied",
  EPERM: "Operation not permitted",
  ELOOP: "Too many levels of symbolic links",
  ENAMETOOLONG: "File name too long",
  EROFS: "Read-only file system",
  ENOSPC: "No space left on device",
  EIO: "Input/output error",
  EMFILE: "Too many open files",
  EFBIG: "File too large",
  EINVAL: "Invalid argument",
  EINTR: "Interrupted system call",
  EAGAIN: "Resource temporarily unavailable",
  EEXIST: "File exists",
  EBADF: "Bad file descriptor",
  ENOTEMPTY: "Directory not empty",
  ESPIPE: "Illegal seek",
};

// The os syscalls answer `os: <what> <arg>: <strerror>` — the shape the
// c runtime's emo_os_fail spells, with the arg omitted for the calls
// that take none.
const osFail = (what, arg, err) => {
  const msg = STRERROR[err.code] || String(err.code || err.message || err);
  return "os: " + what + (arg ? " " + arg : "") + ": " + msg;
};

// The host's open files: fds count from 3, stdio keeps 0/1/2 (stdin is
// readable, stdout writable through the same surface os.write uses).
const fds = new Map();
let nextFd = 3;
const strerror = (err) =>
  STRERROR[err.code] || String(err.code || err.message || err);

let mem = null;
let pending = null;
const dec = new TextDecoder();
const enc = new TextEncoder();

// The import object, exported for drivers that instantiate the module
// themselves (the benchmark driver times fresh instantiations of one
// compiled module — node's startup and the compile stay out of its
// numbers). The closures close over this module's `mem`, assigned
// through setMemory after each instantiate resolves.
export const emoImports = () => ({
  println: (ptr, len) => {
    out(dec.decode(new Uint8Array(mem.buffer, ptr, len)) + "\n");
  },
  abort: (ptr, len) => {
    const msg = len ? dec.decode(new Uint8Array(mem.buffer, ptr, len)) : "";
    console.error("ABORT: " + msg);
    process.exit(1);
  },
  float_str: (f) => {
    const encoded = enc.encode(floatStr(f));
    new Uint8Array(mem.buffer, 60000, encoded.length).set(encoded);
    return [60000, encoded.length];
  },
  file_read: (ptr, len) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      pending = readFileSync(path);
      return [0, pending.length];
    } catch (err) {
      pending = enc.encode("file: cannot read " + path + ": " + strerror(err));
      return [1, pending.length];
    }
  },
  file_write: (ptr, len, dptr, dlen) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    const data = new Uint8Array(mem.buffer, dptr, dlen);
    try {
      writeFileSync(path, data);
      return [0, BigInt(data.length)];
    } catch (err) {
      pending = enc.encode("file: cannot write " + path + ": " + strerror(err));
      return [1, BigInt(pending.length)];
    }
  },
  fetch: (buf, cap) => {
    if (pending === null) throw new Error("fetch without a pending answer");
    const n = Math.min(pending.length, cap);
    new Uint8Array(mem.buffer, buf, n).set(pending.subarray(0, n));
    pending = null;
    return n;
  },
  os_open: (ptr, len, mode) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      const flags = mode === 0 ? "r" : mode === 1 ? "w" : "a";
      const fd = openSync(path, flags, 0o644);
      const n = nextFd++;
      fds.set(n, fd);
      return [0, BigInt(n)];
    } catch (err) {
      pending = enc.encode(osFail("open", path, err));
      return [1, BigInt(pending.length)];
    }
  },
  os_read: (fd, n) => {
    const f = fd === 0n ? 0 : fds.get(Number(fd));
    if (f === undefined) {
      pending = enc.encode("os: read: Bad file descriptor");
      return [1, pending.length];
    }
    if (n <= 0n) return [0, 0];
    try {
      const buf = Buffer.alloc(Number(n));
      const got = readSync(f, buf);
      pending = buf.subarray(0, got);
      return [0, got];
    } catch (err) {
      pending = enc.encode(osFail("read", "", err));
      return [1, BigInt(pending.length)];
    }
  },
  os_write: (fd, dptr, dlen) => {
    const f = fd === 1n ? 1 : fd === 2n ? 2 : fds.get(Number(fd));
    if (f === undefined) {
      pending = enc.encode("os: write: Bad file descriptor");
      return [1, BigInt(pending.length)];
    }
    try {
      writeSync(f, new Uint8Array(mem.buffer, dptr, dlen));
      return [0, BigInt(dlen)];
    } catch (err) {
      pending = enc.encode(osFail("write", "", err));
      return [1, BigInt(pending.length)];
    }
  },
  os_close: (fd) => {
    const f = fds.get(Number(fd));
    if (f === undefined) {
      pending = enc.encode("os: close: Bad file descriptor");
      return [1, BigInt(pending.length)];
    }
    try {
      closeSync(f);
      fds.delete(Number(fd));
      return [0, 0n];
    } catch (err) {
      pending = enc.encode(osFail("close", "", err));
      return [1, BigInt(pending.length)];
    }
  },
  os_list_dir: (ptr, len) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      const names = readdirSync(path, { withFileTypes: false })
        .filter((name) => name !== "." && name !== "..")
        .sort((a, b) => Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8")));
      pending = enc.encode(names.join("\0"));
      return [0, pending.length];
    } catch (err) {
      pending = enc.encode(osFail("opendir", path, err));
      return [1, pending.length];
    }
  },
  os_mkdir: (ptr, len) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      mkdirSync(path, 0o755);
      return [0, 0n];
    } catch (err) {
      pending = enc.encode(osFail("mkdir", path, err));
      return [1, BigInt(pending.length)];
    }
  },
  os_rmdir: (ptr, len) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      rmdirSync(path);
      return [0, 0n];
    } catch (err) {
      pending = enc.encode(osFail("rmdir", path, err));
      return [1, BigInt(pending.length)];
    }
  },
  os_unlink: (ptr, len) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      unlinkSync(path);
      return [0, 0n];
    } catch (err) {
      pending = enc.encode(osFail("unlink", path, err));
      return [1, BigInt(pending.length)];
    }
  },
  os_rename: (optr, olen, nptr, nlen) => {
    const oldPath = dec.decode(new Uint8Array(mem.buffer, optr, olen));
    const newPath = dec.decode(new Uint8Array(mem.buffer, nptr, nlen));
    try {
      renameSync(oldPath, newPath);
      return [0, 0n];
    } catch (err) {
      pending = enc.encode(osFail("rename", oldPath, err));
      return [1, BigInt(pending.length)];
    }
  },
  os_getcwd: () => {
    pending = enc.encode(process.cwd());
    return [0, pending.length];
  },
  os_chdir: (ptr, len) => {
    const path = dec.decode(new Uint8Array(mem.buffer, ptr, len));
    try {
      process.chdir(path);
      return [0, 0n];
    } catch (err) {
      pending = enc.encode(osFail("chdir", path, err));
      return [1, BigInt(pending.length)];
    }
  },
  // The entropy the os half's host can actually supply: Node's CSPRNG,
  // the same source the typescript target reads. A refused source is
  // the (R.error, "rand: getentropy: …") value, the c runtime's text.
  rand_bytes: (n) => {
    try {
      pending = randomBytes(n < 0n ? 0 : Number(n));
      return [0, pending.length];
    } catch (err) {
      pending = enc.encode("rand: getentropy: " + String(err.message || err));
      return [1, pending.length];
    }
  },
});
export const setMemory = (m) => {
  mem = m;
};

// OCaml's %g — the rule the interpreter's `emo_to_string` follows, and
// the same one the TS runtime's `g6` implements: six significant
// digits, exponent form below 1e-4 or at 1e6 and above, exponent
// spelled with a sign and two digits.
const g6 = (x) => {
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
    return ms + "e" + (e < 0 ? "-" : "+") + String(Math.abs(e)).padStart(2, "0");
  }
  const decimals = Math.max(0, 5 - exp);
  let s = x.toFixed(decimals);
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s;
};
const floatStr = (f) => (Object.is(f, -0) ? "-0.0" : Number.isInteger(f) && Math.abs(f) < 1e16 ? f.toFixed(1) : g6(f));

// Executed directly (node wasm_host.mjs <module.wasm>): compile the
// artifact, supply the imports, run the entry. Imported (the benchmark
// driver): only the exported factory and setter are used.
// The argv path may differ from the specifier through a symlink
// (/tmp on macOS resolves to /private/tmp), so both spellings count.
const direct =
  process.argv[1] !== undefined &&
  (import.meta.url === pathToFileURL(process.argv[1]).href ||
    import.meta.url ===
      pathToFileURL(realpathSync(process.argv[1])).href);
if (direct) {
  const bytes = await readFile(process.argv[2]);
  const module_ = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(module_, { emo: emoImports() });
  setMemory(instance.exports.mem);
  instance.exports.main();
}
