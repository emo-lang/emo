#!/usr/bin/env bash
# Build the Emo language server this plugin drives.
#
#   editors/neovim/scripts/build-server.sh
#
# Leaves the binary at <repo>/_build/default/bin/emo_lsp_bin.exe, which
# the plugin finds on its own, and prints that path so you can pass it
# to `require('emo').setup({ server_path = ... })` if you move it.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"       # editors/neovim
repo="$(cd "$here/../.." && pwd)"              # repository root

(cd "$repo" && dune build bin/emo_lsp_bin.exe)

echo "$repo/_build/default/bin/emo_lsp_bin.exe"
