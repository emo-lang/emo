#!/bin/sh
# Stage the repository's packages into a registry directory — the one
# map behind every family gate's staged registry and behind
# `just lock-refresh`.
#
#   scripts/stage-registry.sh <dest-dir>
#
# Two kinds of content land in <dest-dir>:
#
# - The family packages, which live in this tree rather than in the
#   bundled standard library: `emo/ui` and its platform backends, the
#   `fb` desktop tree's packages, `emo_desktop`, and `emo-db`'s four.
#   Each package's file set is exactly the set its gate stages — the
#   lockfile checksums are digests of exactly those files, so a list
#   here may only change together with the gate that pins it.
# - The whole bundled standard library, copied directory for directory:
#   EMO_REGISTRY replaces the bundled library rather than adding to it,
#   and the family projects pin standard-library packages beside their
#   family ones.
#
# Idempotent: run it over an existing destination and the files land
# again, byte for byte.

set -e

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/stage-registry.sh <dest-dir>" >&2
  exit 64
fi
DEST=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UI=$ROOT/projects/emo-ui
FB=$ROOT/projects/emo-desktop/fb
DB=$ROOT/projects/emo-db
STD=$ROOT/stdlib/registry

# family packages — each file list is its gate's own staging list
mkfamily() {
  mkdir -p "$DEST/$1/0.1.0"
}
put() {
  src=$1
  name=$2
  shift 2
  for f in "$@"; do
    cp "$src/$f" "$DEST/$name/0.1.0/"
  done
}

mkfamily emo/ui
put "$UI" emo/ui package.emo ui.emo debug.emo
mkfamily emo/ui_tui
put "$UI/tui" emo/ui_tui package.emo ui_tui.emo
mkfamily emo/ui_ssr
put "$UI/ssr" emo/ui_ssr package.emo ui_ssr.emo
mkfamily emo/ui_corpus
put "$UI/corpus" emo/ui_corpus package.emo main.emo
mkfamily emo/ui_browser
put "$UI/browser" emo/ui_browser package.emo ui_browser.emo css.emo
mkfamily emo/ui_gtk
put "$UI/gtk" emo/ui_gtk package.emo ui_gtk.emo box.emo shim.c
mkfamily emo/ui_macos
put "$UI/macos" emo/ui_macos package.emo ui_macos.emo box.emo shim.m

mkfamily emo/ui_fb
put "$FB" emo/ui_fb package.emo ui_fb.emo pointer.emo raster.emo \
  face_inter.emo face_mono.emo
mkfamily emo/ui_fb_canvas
put "$FB/canvas" emo/ui_fb_canvas package.emo ui_fb_canvas.emo
mkfamily emo/ui_fb_frame
put "$FB/frame" emo/ui_fb_frame package.emo ui_fb_frame.emo counter.emo
mkfamily emo/ui_fb_win
put "$FB/win" emo/ui_fb_win package.emo ui_fb_win.emo
mkfamily emo/ui_fb_winbuf
put "$FB/winbuf" emo/ui_fb_winbuf package.emo ui_fb_winbuf.emo
mkfamily emo/ui_apps
put "$FB/apps" emo/ui_apps package.emo ui_apps.emo counter.emo files.emo \
  editor.emo
mkfamily emo_desktop
put "$FB/desktop" emo_desktop package.emo emo_desktop.emo

mkfamily emo/rocksdb
mkdir -p "$DEST/emo/rocksdb/0.1.0/internal"
cp "$DB/rocksdb/package.emo" "$DB/rocksdb/rocksdb.emo" \
  "$DB/rocksdb/emo_rocksdb_shim.c" "$DEST/emo/rocksdb/0.1.0/"
cp "$DB"/rocksdb/internal/*.emo "$DEST/emo/rocksdb/0.1.0/internal/"
mkfamily emo/record
mkdir -p "$DEST/emo/record/0.1.0/internal"
cp "$DB/record/package.emo" "$DB/record/record.emo" "$DEST/emo/record/0.1.0/"
cp "$DB"/record/internal/*.emo "$DEST/emo/record/0.1.0/internal/"
mkfamily emo/engine
cp "$DB"/engine/package.emo "$DB"/engine/*.emo "$DEST/emo/engine/0.1.0/"
mkfamily emo/wire
cp "$DB"/wire/package.emo "$DB"/wire/*.emo "$DEST/emo/wire/0.1.0/"

# the bundled standard library, whole directories — EMO_REGISTRY replaces
# it, so every package a project pins must be reachable here
for name in "$STD"/*; do
  [ -d "$name/0.1.0" ] || continue
  short=$(basename "$name")
  mkdir -p "$DEST/$short/0.1.0"
  cp -R "$name/0.1.0/." "$DEST/$short/0.1.0/"
done
