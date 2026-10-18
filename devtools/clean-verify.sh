#!/bin/sh
# Extracts a Linux archive from /dist and smoke-runs it inside this
# clean Ubuntu container — the proof that the archive is
# self-contained: no toolchain, no opam, nothing but the base image.
# The script file is mounted in, never passed through a shell -c
# string, so no layer of quote processing can mangle what it writes.
#
# Mounts: /dist (the archives), /src (this repository).
# Env: EMO_RELEASE_TAG, EMO_RELEASE_ARCH (aarch64 or amd64).
set -e
tag=${EMO_RELEASE_TAG:?EMO_RELEASE_TAG}
arch=${EMO_RELEASE_ARCH:?EMO_RELEASE_ARCH}
mkdir -p /verify && cd /verify
tar xzf "/dist/emo-$tag-linux-$arch.tar.gz"
sh "/src/devtools/smoke-verify.sh" "/verify/emo-$tag-linux-$arch"
