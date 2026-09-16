import { cpSync, existsSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../.."); // repository root
const dist = resolve(here, "../dist");
const worktree = join(root, "gh-pages-worktree");

const run = (cmd, cwd = root) => execSync(cmd, { stdio: "inherit", cwd });

if (!existsSync(join(dist, "index.html"))) {
  console.error("dist/index.html not found — run `pnpm build` first.");
  process.exit(1);
}

// Fresh worktree on the gh-pages branch (created as an orphan if missing).
rmSync(worktree, { recursive: true, force: true });
run("git worktree prune");
const hasBranch =
  execSync("git show-ref --verify --quiet refs/heads/gh-pages && echo yes || echo no")
    .toString()
    .trim() === "yes";
if (hasBranch) {
  run(`git worktree add "${worktree}" gh-pages`);
} else {
  run(`git worktree add --orphan -b gh-pages "${worktree}"`);
}

// Replace the worktree content with the build output.
for (const entry of readdirSync(worktree)) {
  if (entry === ".git") continue;
  rmSync(join(worktree, entry), { recursive: true, force: true });
}
cpSync(dist, worktree, { recursive: true });
writeFileSync(join(worktree, ".nojekyll"), "");

run("git add -A", worktree);
run('git commit -m "Deploy website to GitHub Pages" || echo "nothing to commit"', worktree);
run("git push origin gh-pages", worktree);

run(`git worktree remove --force "${worktree}"`);
console.log("Deployed: gh-pages branch updated.");
