#!/bin/sh
# Runs INSIDE the emo-release builder container (see
# release-builder.Dockerfile). The mounts carry the repository at /src
# (read-only) and the dist directory at /out; EMO_RELEASE_TAG names
# the release. Argument: the architecture name used in archive names
# (aarch64 or amd64).
#
# The source is copied to a writable /build with _build, dist, and the
# git directory left behind — nothing the container writes lands in
# the host's source tree.
set -e
tag=${EMO_RELEASE_TAG:?EMO_RELEASE_TAG}
arch=$1
case $arch in
aarch64 | amd64) ;;
*)
  echo "usage: build-linux-release.sh <aarch64|amd64>" >&2
  exit 64
  ;;
esac

# The image runs as the opam user; / is root-owned, so the writable
# build root takes a sudo mkdir.
sudo mkdir -p /build && sudo chown "$(id -u):$(id -g)" /build
cd /src
tar -cf - --exclude=./_build --exclude=./dist --exclude=./.git . |
  (cd /build && tar -xf -)
cd /build

opam exec -- dune build --profile release src/emo_cli/emo.exe
# A hard ceiling: a hung suite must fail the release, not stall it.
timeout 2700 opam exec -- dune test --profile release

# The mounted dist dir belongs to the host user; take it so the
# packaging below can write.
sudo chown "$(id -u):$(id -g)" /out
sh devtools/package-release.sh _build/default/src/emo_cli/emo.exe \
  "$tag" linux "$arch" /out
