#!/bin/sh
# Generates the embedded manual-page data module from the docs: one
# (name, markdown) pair per page — docs/stdlib.md as "stdlib", each
# docs/stdlib/*.md under its base name. The pages ride the compiler
# binary the way the stdlib sources do (T24.2), so `emo man` answers on
# an installed binary with nothing beside it. Edit the docs, then
# rebuild.
#
# Usage: gen-man-data.sh <docs-dir>  (module on stdout)
set -e

root=$1

emit() {
  printf '  ("%s",\n    "' "$1"
  # OCaml string escaping: backslashes and quotes; newlines stay literal.
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$2"
  printf '");\n'
}

echo '(* Generated from docs by devtools/gen-man-data.sh —'
echo '   edit the docs, not this file. *)'
echo 'let pages : (string * string) list = ['
emit stdlib "$root/stdlib.md"
# -type l: dune's macOS sandbox materializes the source tree as
# symlinks; without it the rule generates an empty list in CI.
find "$root/stdlib" \( -type f -o -type l \) -name '*.md' | LC_ALL=C sort |
  while IFS= read -r f; do
    emit "$(basename "$f" .md)" "$f"
  done
echo ']'
