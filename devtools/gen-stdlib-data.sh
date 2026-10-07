#!/bin/sh
# Generates the embedded-standard-library data module from a registry
# directory: (relative path, content) pairs as OCaml string literals,
# with the same relative keys the filesystem registry's collect_files
# produces. The stdlib rides the compiler binary (T25.2,
# plan/step-25-toolchain.md) — edit the registry, then rebuild.
#
# Usage: gen-stdlib-data.sh <registry-dir>  (module on stdout)
set -e

root=$1

echo '(* Generated from stdlib/registry by devtools/gen-stdlib-data.sh —'
echo '   edit the registry, not this file. *)'
echo 'let files : (string * string) list = ['
# -o -type l: dune's macOS sandbox materializes the source tree as
# symlinks; without it the rule generates an empty list in CI.
find "$root" \( -type f -o -type l \) -name '*.emo' | LC_ALL=C sort |
  while IFS= read -r f; do
  rel=${f#"$root"/}
  printf '  ("%s",\n    "' "$rel"
  # OCaml string escaping: backslashes and quotes; newlines stay literal.
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$f"
  printf '");\n'
done
echo ']'
