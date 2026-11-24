// The host for the wasm target: `node wasm-runner.mjs out.wasm`.
//
// The boundary is the compiler's canonical host
// (`src/emo_codegen/wasm/wasm_host.mjs`) — the program `emo run --target
// wasm` and the compiler's own wasm suite run a module under — reached
// through the import object it exports, never copied. This file once kept
// its own three-import copy of that boundary; the wasm runtime grew its
// file, os, rand and time doors around the copy, and a golden that linked
// at T48.6 stopped linking. One host, one import list: a door the runtime
// gains is a door every gate here supplies.

import { readFile } from "node:fs/promises";
import { emoImports, setMemory } from "../../src/emo_codegen/wasm/wasm_host.mjs";

const bytes = await readFile(process.argv[2]);
const module = await WebAssembly.compile(bytes);
const instance = await WebAssembly.instantiate(module, { emo: emoImports() });
setMemory(instance.exports.mem);
instance.exports.main();
