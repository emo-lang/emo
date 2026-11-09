// The wasm benchmark driver: compiles a module once, then instantiates
// and runs it fresh per timing run — node's own startup and the compile
// are excluded, so the number is the module's execution alone. The
// import object is the canonical host's (emo_wasm_host.mjs), so a bench
// may touch any syscall without this file growing a second copy.
// Prints the mean of the timed runs in whole milliseconds.
//
//   node benchmarks/wasm_driver.mjs <module.wasm>
import { readFile } from "node:fs/promises";
import { emoImports, setMemory } from "../src/emo_codegen/wasm/wasm_host.mjs";

const bytes = await readFile(process.argv[2]);
const module = await WebAssembly.compile(bytes);

const runs = 3;
let total = 0;
for (let i = 0; i <= runs; i++) {
  const start = performance.now();
  const instance = await WebAssembly.instantiate(module, { emo: emoImports() });
  setMemory(instance.exports.mem);
  instance.exports.main();
  const elapsed = performance.now() - start;
  if (i > 0) total += elapsed;
}
// The number rides stderr: the program's own stdout stays on stdout,
// and run.sh captures only stderr from here.
console.error(Math.round(total / runs));
