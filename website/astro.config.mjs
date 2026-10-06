// @ts-check
import { defineConfig } from "astro/config";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join, relative } from "node:path";
import { existsSync, statSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..");
const contentDir = resolve(here, "src", "content");

const BASE = "/emo";
const REPO_URL = "https://github.com/emo-lang/emo";
const REPO_BRANCH = "develop";

// Highlight ```emo blocks with the closest familiar grammar (Ruby):
// def/end, snake_case, string interpolation all match well.
function remarkEmoAsRuby() {
  const walk = (node) => {
    if (node.type === "code" && node.lang === "emo") {
      node.lang = "ruby";
    }
    for (const child of node.children ?? []) {
      walk(child);
    }
  };
  return (tree) => walk(tree);
}

// The repository markdown (README.md, docs/*.md) links by repository path,
// so a relative link must be re-pointed for the site: a link into a copied
// docs page becomes its route, anything else becomes a GitHub blob/tree URL.
function remarkRepoLinks() {
  return (tree, file) => {
    const abs = file && file.path;
    if (!abs || !abs.startsWith(contentDir)) return;

    // page.md is the copied README; everything else keeps its docs/ path.
    const rel = relative(contentDir, abs);
    const repoRel = rel === "page.md" ? "README.md" : rel;
    const repoDir = dirname(repoRel);

    const rewrite = (url) => {
      if (
        !url ||
        url.startsWith("#") ||
        url.startsWith("/") ||
        /^[a-z][a-z0-9+.-]*:/i.test(url)
      ) {
        return url;
      }
      const cut = url.search(/[?#]/);
      const pathPart = cut === -1 ? url : url.slice(0, cut);
      const suffix = cut === -1 ? "" : url.slice(cut);
      if (!pathPart) return url;

      // Prefer the markdown-relative target, then a repository-root-relative
      // path — several files link that way.
      const candidates = [
        join(repoDir, pathPart),
        pathPart,
        pathPart.replace(/^(\.\.\/)+/, ""),
      ];
      const target =
        candidates.find((p) =>
          existsSync(join(repoRoot, p.replace(/\/$/, ""))),
        ) ?? candidates[0];
      if (target === "README.md") return `${BASE}/${suffix}`;

      const isDir = target.endsWith("/");
      const clean = target.replace(/\/$/, "");

      if (!isDir && target.startsWith("docs/")) {
        const slug = target.replace(/^docs\//, "").replace(/\.md$/, "");
        if (existsSync(join(contentDir, "docs", `${slug}.md`))) {
          return `${BASE}/docs/${slug}/${suffix}`;
        }
      }

      const repoAbs = join(repoRoot, clean);
      const kind =
        existsSync(repoAbs) && statSync(repoAbs).isDirectory() ? "tree" : "blob";
      return `${REPO_URL}/${kind}/${REPO_BRANCH}/${clean}${suffix}`;
    };

    const walk = (node) => {
      if (node.type === "link" || node.type === "definition") {
        node.url = rewrite(node.url);
      }
      for (const child of node.children ?? []) {
        walk(child);
      }
    };
    walk(tree);
  };
}

export default defineConfig({
  site: "https://emo-lang.github.io",
  base: BASE,
  markdown: {
    remarkPlugins: [remarkRepoLinks, remarkEmoAsRuby],
    shikiConfig: {
      themes: {
        light: "github-light",
        dark: "github-dark",
      },
      wrap: true,
    },
  },
  vite: {
    server: {
      fs: {
        // Allow importing the repository-root README.md during dev.
        allow: [".."],
      },
    },
  },
});
