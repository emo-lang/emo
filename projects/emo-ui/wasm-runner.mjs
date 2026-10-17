// The host for the wasm target: `node wasm-runner.mjs out.wasm`.
//
// It is the same boundary the compiler's own wasm suite provides
// (`test/emo_cli/emo_cli_test.ml`) — println, abort, and float_str into
// the scratch area at 60000 — kept here as a file so both gates in this
// project can run a golden's bytes on the fifth target without a copy
// per run.
//
// `float_str` follows OCaml's `%g`, which is the rule the interpreter's
// `emo_to_string` follows and the TS runtime's `g6` implements: six
// significant digits, exponent form below 1e-4 or at 1e6 and above,
// exponent spelled with a sign and two digits.
import { readFile } from "node:fs/promises";

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

const floatStr = (f) =>
  Number.isInteger(f) && Math.abs(f) < 1e16 ? f.toFixed(1) : g6(f);

const bytes = await readFile(process.argv[2]);
let mem = null;
const dec = new TextDecoder();
const module = await WebAssembly.compile(bytes);
const instance = await WebAssembly.instantiate(module, {
  emo: {
    println: (ptr, len) => {
      process.stdout.write(
        dec.decode(new Uint8Array(mem.buffer, ptr, len)) + "\n",
      );
    },
    abort: (ptr, len) => {
      const msg = len ? dec.decode(new Uint8Array(mem.buffer, ptr, len)) : "";
      console.error("ABORT: " + msg);
      process.exit(1);
    },
    float_str: (f) => {
      const encoded = new TextEncoder().encode(floatStr(f));
      new Uint8Array(mem.buffer, 60000, encoded.length).set(encoded);
      return [60000, encoded.length];
    },
  },
});
mem = instance.exports.mem;
instance.exports.main();
