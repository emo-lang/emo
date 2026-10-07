#!/bin/sh
# Assembles the release archive for one platform from a built emo
# binary (T25.6). The stdlib rides inside the binary (T25.2), so the
# archive carries the executable, the license, and nothing else.
#
# Usage: package-release.sh <emo-binary> <version> <os> <arch> <out-dir>
#
# Produces <out-dir>/emo-<version>-<os>-<arch>.{zip|tar.gz} plus a
# .sha256 beside it. macOS zips: notarization staples a zip, never a
# tar; the version argument carries its own v prefix (the VERSION file
# reads v1.2.3).
set -e

bin=$1
version=$2
os=$3
arch=$4
out=$5

name="emo-$version-$os-$arch"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ ! -x "$bin" ]; then
  echo "package-release.sh: $bin is not an executable" >&2
  exit 65
fi

mkdir -p "$out"
# Resolve the output directory now — the script changes into the staging
# directory below, and a relative $out would resolve from there.
out=$(CDPATH= cd -- "$out" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/$name/bin"
cp "$bin" "$stage/$name/bin/emo"
chmod 755 "$stage/$name/bin/emo"
cp "$root/LICENSE" "$stage/$name/LICENSE"

# macOS signing (T25.7): the four EMO_ variables together turn the
# hooks on — the identity signs the binary with the hardened runtime,
# notarytool submits the zip, stapler attaches the ticket. With any of
# them unset the hooks stay off and the archive ships unsigned (CI
# passes the secrets through verbatim; absent secrets mean absent
# values).
if [ "$os" = macos ] && [ -n "$EMO_CODESIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp \
    -s "$EMO_CODESIGN_IDENTITY" "$stage/$name/bin/emo"
fi

cd "$stage"
case "$os" in
macos)
  zip -q -r "$out/$name.zip" "$name"
  archive="$name.zip"
  ;;
*)
  tar -czf "$out/$name.tar.gz" "$name"
  archive="$name.tar.gz"
  ;;
esac
cd "$out"

if [ "$os" = macos ] && [ -n "$EMO_CODESIGN_IDENTITY" ] &&
  [ -n "$EMO_NOTARY_APPLE_ID" ] && [ -n "$EMO_NOTARY_APP_PASSWORD" ] &&
  [ -n "$EMO_NOTARY_TEAM_ID" ]; then
  xcrun notarytool submit "$out/$archive" \
    --apple-id "$EMO_NOTARY_APPLE_ID" \
    --password "$EMO_NOTARY_APP_PASSWORD" \
    --team-id "$EMO_NOTARY_TEAM_ID" --wait
  xcrun stapler staple "$out/$archive"
fi

# shasum ships with macOS, sha256sum with Linux; the output shape is
# the same "hash  name" line either way.
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive" >"$archive.sha256"
else
  shasum -a 256 "$archive" >"$archive.sha256"
fi
echo "$out/$archive"
