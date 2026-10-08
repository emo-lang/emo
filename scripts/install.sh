#!/bin/sh
# The Emo toolchain installer — the one-line channel:
#
#   curl -fsSL https://raw.githubusercontent.com/emo-lang/emo/develop/scripts/install.sh | sh
#
# Detects the platform, fetches the matching archive from the latest
# GitHub Release, verifies its SHA256 against the release's
# SHA256SUMS, and installs the binary (plus the macOS dylibs it loads
# through @executable_path) under EMO_PREFIX, default ~/.emo:
#
#   ~/.emo/bin/emo
#   ~/.emo/lib/*.dylib    (macOS only — the archive is self-contained)
#
# Re-running upgrades in place; EMO_REPO and EMO_PREFIX redirect the
# source and destination for testing.
set -e

repo=${EMO_REPO:-emo-lang/emo}
prefix=${EMO_PREFIX:-$HOME/.emo}

case "$(uname -s)" in
Darwin) os=macos ;;
Linux) os=linux ;;
*)
  echo "install.sh: unsupported platform: $(uname -s)" >&2
  echo "install.sh: on Windows, install inside WSL2 as you would on Linux" >&2
  exit 1
  ;;
esac

# The release matrix names Apple Silicon arm64 and Linux aarch64.
case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
arm64 | aarch64)
  if [ "$os" = macos ]; then arch=arm64; else arch=aarch64; fi
  ;;
*)
  echo "install.sh: unsupported architecture: $(uname -m)" >&2
  exit 1
  ;;
esac

# releases/latest redirects to the newest tag — no API call, no rate
# limit.
latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  "https://github.com/$repo/releases/latest")
tag=${latest##*/}
case $tag in
v*) ;;
*)
  echo "install.sh: could not resolve the latest release of $repo" >&2
  exit 1
  ;;
esac

case $os in
macos) ext=zip ;;
linux) ext=tar.gz ;;
esac
archive=emo-$tag-$os-$arch.$ext

tmp=$(mktemp -d "${TMPDIR:-/tmp}/emo-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$archive" \
  "https://github.com/$repo/releases/download/$tag/$archive"

if command -v sha256sum >/dev/null 2>&1; then
  checksum=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  checksum="shasum -a 256"
else
  checksum=
fi
if [ -n "$checksum" ]; then
  curl -fsSL -o "$tmp/SHA256SUMS" \
    "https://github.com/$repo/releases/download/$tag/SHA256SUMS"
  expected=$(sed -n "s/^\([0-9a-f]*\)  $archive\$/\1/p" "$tmp/SHA256SUMS")
  if [ -z "$expected" ]; then
    echo "install.sh: $tag's SHA256SUMS has no entry for $archive" >&2
    exit 1
  fi
  actual=$($checksum "$tmp/$archive" | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then
    echo "install.sh: checksum mismatch for $archive" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
else
  echo "install.sh: no sha256 tool found — skipping checksum verification" >&2
fi

case $ext in
zip) unzip -q "$tmp/$archive" -d "$tmp" ;;
tar.gz) tar -xzf "$tmp/$archive" -C "$tmp" ;;
esac
root=$tmp/emo-$tag-$os-$arch
if [ ! -f "$root/bin/emo" ]; then
  echo "install.sh: $archive has no bin/emo" >&2
  exit 1
fi

mkdir -p "$prefix/bin" "$prefix/lib"
cp "$root/bin/emo" "$prefix/bin/emo.incoming"
chmod 755 "$prefix/bin/emo.incoming"
mv "$prefix/bin/emo.incoming" "$prefix/bin/emo"
for lib in "$root/lib"/*; do
  [ -f "$lib" ] || continue
  cp "$lib" "$prefix/lib/"
done

echo "installed $prefix/bin/emo ($("$prefix/bin/emo" version))"

# PATH setup: with bash or zsh as the login shell, append the export
# to its rc file — idempotently; other shells keep the printed hint.
line="export PATH=\"$prefix/bin:\$PATH\""
rc=
case "${SHELL:-}" in
*/zsh) rc=$HOME/.zshrc ;;
*/bash) rc=$HOME/.bashrc ;;
esac
case :$PATH: in
*:$prefix/bin:*) ;;
*)
  if [ -n "$rc" ]; then
    if [ -f "$rc" ] && grep -qF "$prefix/bin" "$rc"; then
      echo "install.sh: $rc already lists $prefix/bin"
    else
      printf '\n# added by the Emo installer\n%s\n' "$line" >>"$rc"
      echo "install.sh: added $prefix/bin to PATH in $rc"
      echo "install.sh: start a new shell, or run: source $rc"
    fi
  else
    echo "add it to PATH: $line"
  fi
  ;;
esac
echo "verify the environment with: emo doctor"
