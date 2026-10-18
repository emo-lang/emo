#!/bin/sh
# Smoke-runs a freshly built, extracted archive directory: the binary
# announces its version and runs a hello-world through the
# interpreter, with a manifest under the shipping package-name rules
# (demo/smoke — owners prefixed with emo are reserved).
#
# Usage: smoke-verify.sh <extracted-root-dir>    (bin/emo inside)
# Env: EMO_RELEASE_TAG
set -e
root=$1
tag=${EMO_RELEASE_TAG:?EMO_RELEASE_TAG}
if [ -z "$root" ] || [ ! -x "$root/bin/emo" ]; then
  echo "smoke-verify.sh: usage: smoke-verify.sh <extracted-root-dir with bin/emo>" >&2
  exit 64
fi
cd "$root"
./bin/emo version
printf 'package {\n  name = "demo/smoke"\n  version = "0.1.0"\n  targets = ["ocaml"]\n\n  deps {}\n}\n' > package.emo
printf 'println(6 * 7)\n' > smoke.emo
./bin/emo run smoke.emo | grep 42
