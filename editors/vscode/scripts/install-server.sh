#!/usr/bin/env bash
# Build the Emo language server and stage it inside the extension.
#
#   editors/vscode/scripts/install-server.sh
#
# The extension looks for `server/emo-lsp` and `server/registry` next to
# its package root. Run this before `vsce package`, or point
# `emo.serverPath` / `emo.registry` at your own build.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"       # editors/vscode
repo="$(cd "$here/../.." && pwd)"              # repository root

echo "building emo-lsp in $repo ..."
(cd "$repo" && dune build bin/emo_lsp_bin.exe)

mkdir -p "$here/server"
rm -f "$here/server/emo-lsp"
cp "$repo/_build/default/bin/emo_lsp_bin.exe" "$here/server/emo-lsp"
chmod u+w,+x "$here/server/emo-lsp"

if [ -d "$repo/stdlib/registry" ]; then
  rm -rf "$here/server/registry"
  cp -R "$repo/stdlib/registry" "$here/server/registry"
fi

echo "installed $here/server/emo-lsp"
