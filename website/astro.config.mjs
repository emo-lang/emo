// @ts-check
import { defineConfig } from "astro/config";

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

export default defineConfig({
  site: "https://emo-lang.github.io",
  base: "/emo",
  markdown: {
    remarkPlugins: [remarkEmoAsRuby],
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
