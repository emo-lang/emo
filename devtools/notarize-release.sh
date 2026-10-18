#!/bin/sh
# Notarizes the release's macOS archive from this machine. The archive
# is a local file now — built by devtools/build-release.sh into the
# dist dir, no forge release in between. This script signs the binary
# and its bundled dylibs with the keychain's Developer ID Application
# identity, submits the rebuilt zip to the notary service, and
# refreshes the dist's SHA256SUMS.
#
# Usage: notarize-release.sh [dist-dir] [--dry-run]
#
# The signing identity is auto-detected from the keychain (override
# with EMO_CODESIGN_IDENTITY). The notary credential follows
# package-release.sh: EMO_NOTARY_PROFILE, the App Store Connect API
# key trio, or the Apple ID quartet. Store the profile once with:
#   xcrun notarytool store-credentials emo-notary \
#     --apple-id <id> --team-id <team> --password <app-specific-password>
# then run: EMO_NOTARY_PROFILE=emo-notary just notarize dist
set -e

dist=dist
dry_run=false
for arg in "$@"; do
  case $arg in
  --dry-run) dry_run=true ;;
  *) dist=$arg ;;
  esac
done
if [ ! -d "$dist" ]; then
  echo "usage: notarize-release.sh [dist-dir] [--dry-run]" >&2
  exit 64
fi
dist=$(CDPATH= cd -- "$dist" && pwd)

identity=${EMO_CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  identity=$(
    security find-identity -v -p codesigning |
      sed -n 's/^ *[0-9]*) [A-F0-9]* "\(Developer ID Application:[^"]*\)"$/\1/p' |
      head -1
  )
fi
if [ -z "$identity" ]; then
  echo "notarize-release.sh: no Developer ID Application identity in the keychain" >&2
  exit 65
fi
echo "signing as: $identity"

# submit <archive> — one notary submission through whichever
# credential shape the environment provides.
submit() {
  if [ -n "$EMO_NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$1" -p "$EMO_NOTARY_PROFILE" --wait
  elif [ -n "$EMO_NOTARY_KEY" ] && [ -n "$EMO_NOTARY_KEY_ID" ] &&
    [ -n "$EMO_NOTARY_ISSUER" ]; then
    xcrun notarytool submit "$1" --key "$EMO_NOTARY_KEY" \
      --key-id "$EMO_NOTARY_KEY_ID" --issuer "$EMO_NOTARY_ISSUER" --wait
  elif [ -n "$EMO_NOTARY_APPLE_ID" ] && [ -n "$EMO_NOTARY_APP_PASSWORD" ] &&
    [ -n "$EMO_NOTARY_TEAM_ID" ]; then
    xcrun notarytool submit "$1" \
      --apple-id "$EMO_NOTARY_APPLE_ID" \
      --password "$EMO_NOTARY_APP_PASSWORD" \
      --team-id "$EMO_NOTARY_TEAM_ID" --wait
  else
    echo "notarize-release.sh: no notary credential — set EMO_NOTARY_PROFILE," \
      "the ASC key trio, or the Apple ID quartet (see the header comment)" >&2
    exit 66
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/emo-notarize.XXXXXX")
trap 'rm -rf "$work"' EXIT

set -- "$dist"/emo-*.zip
if [ ! -e "$1" ]; then
  echo "notarize-release.sh: $dist has no macOS zip — build first" >&2
  exit 65
fi
if [ "$#" -ne 1 ]; then
  echo "notarize-release.sh: expected exactly one macOS zip in $dist, found $#" >&2
  exit 65
fi

for zip in "$@"; do
  name=${zip%.zip}
  name=${name##*/}
  stage=$work/.stage-$name
  mkdir -p "$stage"
  unzip -q "$zip" -d "$stage"
  bin=$stage/$name/bin/emo
  if [ ! -f "$bin" ]; then
    echo "notarize-release.sh: $zip has no $name/bin/emo" >&2
    exit 65
  fi

  # The archive must be self-contained: every non-system dylib the
  # binary or its bundled libraries reference rides in lib/, pointed
  # at through @executable_path. Anything still pointing at an
  # absolute path (a stray Homebrew library, say) breaks on users'
  # Macs and dies under library validation — refuse rather than
  # notarize a broken archive.
  stray() {
    otool -L "$1" | awk 'NR>1 {print $1}' |
      grep '^/' | grep -v -e '^/usr/lib/' -e '^/System/'
  }
  for target in "$bin" "$stage/$name/lib/"*.dylib; do
    [ -f "$target" ] || continue
    if [ -n "$(stray "$target")" ]; then
      echo "notarize-release.sh: $(basename "$target") still references:" >&2
      stray "$target" >&2
      exit 65
    fi
  done

  # One identity across the binary and the bundled dylibs — library
  # validation under the hardened runtime rejects mixed-team loads.
  for lib in "$stage/$name/lib/"*.dylib; do
    [ -f "$lib" ] || continue
    codesign --force --options runtime --timestamp -s "$identity" "$lib"
  done
  codesign --force --options runtime --timestamp -s "$identity" "$bin"
  codesign --verify --strict "$bin"
  # Rebuild the zip from the same root — via a fresh file so no stale
  # entry can survive from the original packaging.
  (cd "$stage" && zip -q -r "$zip.new" "$name" && mv "$zip.new" "$zip")
  if [ "$dry_run" = true ]; then
    echo "dry run: would notarize $(basename "$zip")"
    continue
  fi
  # Accepted is all a bare executable gets: stapler embeds tickets
  # only into .app/.dmg/.pkg shapes, never a flat binary, so
  # Gatekeeper validates this archive's ticket online at first run.
  submit "$zip"
done

if [ "$dry_run" = true ]; then
  echo "dry run: would refresh $dist/SHA256SUMS"
  exit 0
fi

# The re-zipped archive changed, so the checksum file must change with
# it — recompute the sums over the whole release set.
(
  cd "$dist" &&
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum emo-*.zip emo-*.tar.gz >SHA256SUMS
    else
      shasum -a 256 emo-*.zip emo-*.tar.gz >SHA256SUMS
    fi
)

echo "notarized $(basename "$1") and refreshed $dist/SHA256SUMS"
