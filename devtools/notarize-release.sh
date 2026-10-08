#!/bin/sh
# Notarizes a draft GitHub Release's macOS archives from this machine
# — the local half of T25.7. CI runners hold no Developer ID private
# key, so release.yml drafts the release unsigned; this script signs
# the binaries with the keychain's Developer ID Application identity,
# submits the rebuilt zips to the notary service, re-uploads the
# archives, and refreshes SHA256SUMS.
#
# Usage: notarize-release.sh <tag> [--dry-run]
#
# The signing identity is auto-detected from the keychain (override
# with EMO_CODESIGN_IDENTITY). The notary credential follows
# package-release.sh: EMO_NOTARY_PROFILE, the App Store Connect API
# key trio, or the Apple ID quartet. Store the profile once with:
#   xcrun notarytool store-credentials emo-notary \
#     --apple-id <id> --team-id <team> --password <app-specific-password>
# then run: EMO_NOTARY_PROFILE=emo-notary just notarize v0.26.7
set -e

tag=$1
dry_run=false
[ "${2:-}" = "--dry-run" ] && dry_run=true
if [ -z "$tag" ]; then
  echo "usage: notarize-release.sh <tag> [--dry-run]" >&2
  exit 64
fi
repo=${EMO_REPO:-emo-lang/emo}

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
gh release download "$tag" --repo "$repo" --pattern '*.zip' --dir "$work" --clobber

set -- "$work"/*.zip
if [ ! -e "$1" ]; then
  echo "notarize-release.sh: release $tag has no macOS zips" >&2
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
  # absolute path (a runner's Homebrew, say) breaks on users' Macs
  # and dies under library validation — refuse rather than notarize
  # a broken archive.
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
  # entry can survive from the download.
  (cd "$stage" && zip -q -r "$zip.new" "$name" && mv "$zip.new" "$zip")
  if [ "$dry_run" = true ]; then
    echo "dry run: would notarize and re-upload $zip"
    continue
  fi
  # Accepted is all a bare executable gets: stapler embeds tickets
  # only into .app/.dmg/.pkg shapes, never a flat binary, so
  # Gatekeeper validates this archive's ticket online at first run.
  submit "$zip"
done

if [ "$dry_run" = true ]; then
  echo "dry run: would re-upload the zips and refresh SHA256SUMS"
  exit 0
fi

gh release upload "$tag" --repo "$repo" "$work"/*.zip --clobber

# The re-zipped archives changed, so the checksum file must change
# with them — pull every asset back and recompute the sums whole.
gh release download "$tag" --repo "$repo" --dir "$work" --clobber
(cd "$work" && shasum -a 256 *.zip *.tar.gz >SHA256SUMS)
gh release upload "$tag" --repo "$repo" "$work/SHA256SUMS" --clobber

echo "notarized and re-uploaded $tag's macOS archives"
