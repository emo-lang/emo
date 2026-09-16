import { copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
copyFileSync(join(here, "../../README.md"), join(here, "../src/content/page.md"));
console.log("README.md copied to src/content/page.md");
