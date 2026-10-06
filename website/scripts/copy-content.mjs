import { cpSync, copyFileSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../..");
const content = join(here, "../src/content");

// The repository-root README.md is the landing page's markdown.
// src/content/ has no tracked files, so it may not exist yet on a fresh
// checkout — create it before writing into it.
mkdirSync(content, { recursive: true });
copyFileSync(join(repo, "README.md"), join(content, "page.md"));

// The docs/ tree becomes the documentation pages, structure preserved.
const docsDest = join(content, "docs");
rmSync(docsDest, { recursive: true, force: true });
cpSync(join(repo, "docs"), docsDest, { recursive: true });

console.log("content synced: README.md -> page.md, docs/ -> docs/");
