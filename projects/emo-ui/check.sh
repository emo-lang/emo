#!/bin/sh
# The core's gate. The packages under projects/emo-ui/ are not swept into
# the compiler's own build (CHECK.md, the in-tree project layout), so this
# is where the portable core is verified.
#
#   ./check.sh
#
# `emo emoji build` is the pre-publish gate: it compiles the package's
# entry module (ui.emo, the module the manifest's short name names) once
# per target the manifest declares. Override the compiler with $EMO.

set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}
case "$EMO" in /*) ;; *) EMO="$PWD/$EMO" ;; esac

"$EMO" check ui.emo
"$EMO" run ui.emo
"$EMO" emoji build
