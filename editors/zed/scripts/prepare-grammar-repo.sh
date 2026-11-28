#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/grammars/tree-sitter-emo"
repo_dir="$root/.grammar/emo.git"

mkdir -p "$root/.grammar"
if [ ! -d "$repo_dir" ]; then
  git init --bare "$repo_dir" >/dev/null
fi

mkdir -p "$source_dir"
export GIT_DIR="$repo_dir"
export GIT_WORK_TREE="$source_dir"
export GIT_INDEX_FILE="$repo_dir/index.tmp"
export GIT_AUTHOR_NAME="Emo Grammar"
export GIT_AUTHOR_EMAIL="grammar@emo.local"
export GIT_COMMITTER_NAME="Emo Grammar"
export GIT_COMMITTER_EMAIL="grammar@emo.local"

git add -A
tree="$(git write-tree)"
current="$(git rev-parse --verify refs/heads/main 2>/dev/null || true)"
if [ -n "$current" ] && [ "$(git rev-parse "$current^{tree}")" = "$tree" ]; then
  commit="$current"
else
  commit="$(git commit-tree "$tree" -m "Update Emo tree-sitter grammar")"
  git update-ref refs/heads/main "$commit"
fi
git symbolic-ref HEAD refs/heads/main

python3 - "$root/extension.toml" "$commit" <<'PY'
import re
import sys

path, rev = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    text = f.read()
text, count = re.subn(r'(?m)^rev = ".*"$', f'rev = "{rev}"', text, count=1)
if count != 1:
    raise SystemExit(f"no `rev` entry found in {path}")
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

printf 'Grammar repository ready: %s\n' "$repo_dir"
printf 'Revision: %s\n' "$commit"
