#!/bin/sh
# Builds and tests the release archives on this machine — the release
# pipeline's build farm is local. macOS arm64 builds natively; both
# Linux archives build in Docker against Ubuntu 22.04 (the oldest
# supported glibc), the amd64 one under Rosetta emulation. Every
# archive is then smoke-run in a clean container before it ships.
# Intel Macs are not a shipping target — there is no macOS x86_64.
#
# Usage: build-release.sh <tag> [dist-dir]
#
# The Linux builds need the local builder images — built once and
# reused across releases:
#
#   just release-image arm64
#   just release-image amd64
#
# EMO_OCAML_SWITCH overrides the host opam switch (default 5.5.0).
set -e

tag=$1
dist=${2:-dist}
switch=${EMO_OCAML_SWITCH:-5.5.0}
if [ -z "$tag" ]; then
  echo "usage: build-release.sh <tag> [dist-dir]" >&2
  exit 64
fi
case "$(uname -s)/$(uname -m)" in
Darwin/arm64) ;;
*)
  echo "build-release.sh: run this on an Apple Silicon Mac — the macOS archive is arm64-only" >&2
  exit 64
  ;;
esac
if ! docker info >/dev/null 2>&1; then
  echo "build-release.sh: Docker Desktop must be running — the Linux archives build in containers" >&2
  exit 64
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$dist"
dist=$(CDPATH= cd -- "$dist" && pwd)
for f in "$dist"/emo-"$tag"-*; do
  [ -e "$f" ] || continue
  echo "build-release.sh: $f already exists — clear it or use a fresh dist dir" >&2
  exit 65
done

echo "build: macOS arm64 (native)"
opam exec --switch "$switch" -- dune build --profile release src/emo_cli/emo.exe
# A hard ceiling: a hung suite must fail the release, not stall it.
perl -e 'alarm shift; exec @ARGV' 2700 \
  opam exec --switch "$switch" -- dune test --profile release
"$root/devtools/package-release.sh" _build/default/src/emo_cli/emo.exe \
  "$tag" macos arm64 "$dist"

work=$(mktemp -d "${TMPDIR:-/tmp}/emo-release-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT
unzip -q "$dist/emo-$tag-macos-arm64.zip" -d "$work"
EMO_RELEASE_TAG="$tag" sh "$root/devtools/smoke-verify.sh" \
  "$work/emo-$tag-macos-arm64"
echo "build: macOS arm64 verified"

build_linux() {
  arch=$1
  # Archive names follow the Linux convention (aarch64); Docker and
  # the builder images follow its own (arm64).
  case $arch in
  aarch64) imgarch=arm64 ;;
  *) imgarch=$arch ;;
  esac
  image=emo-release:ubuntu22.04-$imgarch
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "build-release.sh: missing builder image $image — run: just release-image $imgarch" >&2
    exit 65
  fi
  echo "build: linux $arch (Docker)"
  docker run --rm --platform "linux/$imgarch" \
    -v "$root":/src:ro -v "$dist":/out \
    -e EMO_RELEASE_TAG="$tag" \
    "$image" sh /src/devtools/build-linux-release.sh "$arch"
  docker run --rm --platform "linux/$imgarch" \
    -v "$root":/src:ro -v "$dist":/dist:ro \
    -e EMO_RELEASE_TAG="$tag" -e EMO_RELEASE_ARCH="$arch" \
    ubuntu:22.04 sh /src/devtools/clean-verify.sh
  echo "build: linux $arch verified"
}

build_linux aarch64
build_linux amd64

(
  cd "$dist" &&
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum emo-*.zip emo-*.tar.gz >SHA256SUMS
    else
      shasum -a 256 emo-*.zip emo-*.tar.gz >SHA256SUMS
    fi
)
cat "$dist/SHA256SUMS"
echo "build: $dist holds the $tag release set (1 macOS zip, 2 Linux tar.gz)"
