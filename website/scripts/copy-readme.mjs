import { copyFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const dest = join(here, "../src/content/page.md");
mkdirSync(dirname(dest), { recursive: true });
copyFileSync(join(here, "../../README.md"), dest);
console.log("README.md copied to src/content/page.md");
