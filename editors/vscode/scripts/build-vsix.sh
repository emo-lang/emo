#!/usr/bin/env bash
# Build a distributable .vsix for the Emo VS Code extension.
#
#   editors/vscode/scripts/build-vsix.sh [--out FILE]
#
# Steps:
#   1. build emo-lsp and stage it, with the standard-library registry,
#      under server/ (install-server.sh)
#   2. install the extension's dependencies when node_modules is missing
#   3. bundle the extension with esbuild and package it with vsce
#
# With no --out, the archive lands beside package.json as
# emo-tools-lsp-<version>.vsix.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"       # editors/vscode

out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      if [ $# -lt 2 ]; then
        echo "build-vsix.sh: --out needs a path" >&2
        exit 64
      fi
      out="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: build-vsix.sh [--out FILE]"
      exit 0
      ;;
    *)
      echo "build-vsix.sh: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

echo "==> staging emo-lsp and the standard-library registry"
bash "$here/scripts/install-server.sh"

if [ ! -d "$here/node_modules" ]; then
  echo "==> installing extension dependencies"
  (cd "$here" && npm install)
fi

echo "==> bundling the extension"
(cd "$here" && npm run build)

if [ -z "$out" ]; then
  version="$(node -p "require('$here/package.json').version")"
  out="$here/emo-tools-lsp-$version.vsix"
fi

echo "==> packaging $out"
(cd "$here" && npx --yes @vscode/vsce package --out "$out")

echo
echo "built $out"
