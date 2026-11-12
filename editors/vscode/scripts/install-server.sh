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

# dune rides the opam switch; a bare shell has neither dune nor opam on
# PATH, and opam itself may sit outside PATH (Homebrew, ~/.opam).
if ! command -v dune >/dev/null 2>&1; then
  opam_bin=""
  for candidate in opam /opt/homebrew/bin/opam /usr/local/bin/opam "$HOME/.opam/opam"; do
    if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
      opam_bin="$candidate"
      break
    fi
  done
  if [ -n "$opam_bin" ]; then
    eval "$("$opam_bin" env --switch 5.5.2 2>/dev/null)" ||
      eval "$("$opam_bin" env 2>/dev/null)" || true
  fi
fi

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
