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

# macOS signing (T25.7): EMO_CODESIGN_IDENTITY turns the signing hook
# on — the identity signs the binary with the hardened runtime. Notary
# credentials are any one of three shapes: EMO_NOTARY_PROFILE (a
# `notarytool store-credentials` profile in the keychain), the App
# Store Connect API key trio (EMO_NOTARY_KEY — a path to the .p8 —
# with EMO_NOTARY_KEY_ID and EMO_NOTARY_ISSUER), or the Apple ID
# quartet (EMO_NOTARY_APPLE_ID, EMO_NOTARY_APP_PASSWORD,
# EMO_NOTARY_TEAM_ID). With no credential set the archive ships
# unsigned (CI passes the secrets through verbatim; absent secrets
# mean absent values).
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

notarized=0
if [ "$os" = macos ] && [ -n "$EMO_CODESIGN_IDENTITY" ]; then
  if [ -n "$EMO_NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$out/$archive" -p "$EMO_NOTARY_PROFILE" --wait
    notarized=1
  elif [ -n "$EMO_NOTARY_KEY" ] && [ -n "$EMO_NOTARY_KEY_ID" ] &&
    [ -n "$EMO_NOTARY_ISSUER" ]; then
    xcrun notarytool submit "$out/$archive" --key "$EMO_NOTARY_KEY" \
      --key-id "$EMO_NOTARY_KEY_ID" --issuer "$EMO_NOTARY_ISSUER" --wait
    notarized=1
  elif [ -n "$EMO_NOTARY_APPLE_ID" ] && [ -n "$EMO_NOTARY_APP_PASSWORD" ] &&
    [ -n "$EMO_NOTARY_TEAM_ID" ]; then
    xcrun notarytool submit "$out/$archive" \
      --apple-id "$EMO_NOTARY_APPLE_ID" \
      --password "$EMO_NOTARY_APP_PASSWORD" \
      --team-id "$EMO_NOTARY_TEAM_ID" --wait
    notarized=1
  fi
fi
if [ "$notarized" = 1 ]; then
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
