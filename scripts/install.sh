#!/bin/sh
# The Emo toolchain installer — the one-line channel:
#
#   curl -fsSL https://www.emo-lang.cn/cdn/install.sh | sh
#
# Detects the platform, fetches the matching archive for the latest
# release from the download site, verifies its SHA256 against the
# release's SHA256SUMS, and installs the binary (plus the macOS dylibs
# it loads through @executable_path) under EMO_PREFIX, default ~/.emo:
#
#   ~/.emo/bin/emo
#   ~/.emo/lib/*.dylib    (macOS only — the archive is self-contained)
#
# Re-running upgrades in place; EMO_BASE_URL and EMO_PREFIX redirect
# the source and destination for testing, EMO_VERSION pins a tag
# instead of the latest release.
set -e

base=${EMO_BASE_URL:-https://www.emo-lang.cn/cdn}
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

# The release matrix names the archives macOS arm64 and Linux aarch64 /
# amd64 — uname's x86_64 must map to the archive's amd64.
case "$(uname -m)" in
arm64) arch=arm64 ;;
aarch64) arch=aarch64 ;;
x86_64 | amd64) arch=amd64 ;;
*)
  echo "install.sh: unsupported architecture: $(uname -m)" >&2
  exit 1
  ;;
esac

# Intel Macs are not a shipping target — say so here rather than let
# the download 404.
if [ "$os" = macos ] && [ "$(uname -m)" != arm64 ]; then
  echo "install.sh: no Intel macOS build — Emo ships macOS for Apple Silicon only" >&2
  exit 1
fi

# curl rides every platform the installer targets, but a box with wget
# alone should not fall at the first step — fetch through whichever
# exists.
fetch() {
  url=$1
  out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "install.sh: neither curl nor wget found — install one and retry" >&2
    exit 1
  fi
}

echo "install.sh: platform detected: $os/$arch"

# The download site's dist/releases.json carries the latest-version
# pointer. The file has one fixed shape — written by
# publish-release.sh, first key on its own line — so a plain sed
# resolves it without a jq dependency. Every network step prints
# before and after: a silent minute reads as a hang.
if [ -n "${EMO_VERSION:-}" ]; then
  tag=$EMO_VERSION
  echo "install.sh: using the pinned release $tag"
else
  echo "install.sh: resolving the latest release…"
  tmp_json=$(mktemp "${TMPDIR:-/tmp}/emo-install-releases.XXXXXX")
  fetch "$base/dist/releases.json" "$tmp_json"
  tag=$(sed -n 's/^  "latest": "\([^"]*\)",$/\1/p' "$tmp_json")
  rm -f "$tmp_json"
  echo "install.sh: latest release is $tag"
fi
case $tag in
v*) ;;
*)
  echo "install.sh: could not resolve the latest release from $base/dist/releases.json" >&2
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
echo "install.sh: downloading ${archive}…"
fetch "$base/dist/$tag/$archive" "$tmp/$archive"
echo "install.sh: download complete"

if command -v sha256sum >/dev/null 2>&1; then
  checksum=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  checksum="shasum -a 256"
else
  checksum=
fi
if [ -n "$checksum" ]; then
  echo "install.sh: verifying the SHA256 checksum…"
  fetch "$base/dist/$tag/SHA256SUMS" "$tmp/SHA256SUMS"
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
  echo "install.sh: checksum ok"
else
  echo "install.sh: no sha256 tool found — skipping checksum verification" >&2
fi

echo "install.sh: unpacking…"
case $ext in
zip) unzip -q "$tmp/$archive" -d "$tmp" ;;
tar.gz) tar -xzf "$tmp/$archive" -C "$tmp" ;;
esac
root=$tmp/emo-$tag-$os-$arch
if [ ! -f "$root/bin/emo" ]; then
  echo "install.sh: $archive has no bin/emo" >&2
  exit 1
fi

# Re-running upgrades in place. The archive's dylibs are read-only
# (Homebrew's openssl ships them 444), and cp cannot open an existing
# read-only destination for writing — so stage each file beside the
# target and mv it into place, which replaces the directory entry and
# works whatever the old file's mode.
echo "install.sh: installing to ${prefix}…"
mkdir -p "$prefix/bin" "$prefix/lib"
rm -f "$prefix/bin/emo.incoming"
cp "$root/bin/emo" "$prefix/bin/emo.incoming"
chmod 755 "$prefix/bin/emo.incoming"
mv "$prefix/bin/emo.incoming" "$prefix/bin/emo"
for lib in "$root/lib"/*; do
  [ -f "$lib" ] || continue
  base=${lib##*/}
  rm -f "$prefix/lib/$base.incoming"
  cp "$lib" "$prefix/lib/$base.incoming"
  mv "$prefix/lib/$base.incoming" "$prefix/lib/$base"
done

echo "installed $prefix/bin/emo ($("$prefix/bin/emo" version))"

# PATH setup: with bash or zsh as the login shell, append the export
# to its rc file — idempotently; other shells keep the printed hint.
# Every branch below leaves the current shell without the emo command,
# so each speaks the same two-line warning, bold yellow when stdout is
# a terminal — escape codes would only litter a piped log.
line="export PATH=\"$prefix/bin:\$PATH\""
rc=
case "${SHELL:-}" in
*/zsh) rc=$HOME/.zshrc ;;
*/bash) rc=$HOME/.bashrc ;;
esac
if [ -t 1 ]; then
  hl_on=$(printf '\033[1;33m')
  hl_off=$(printf '\033[0m')
else
  hl_on=
  hl_off=
fi
say() {
  printf '%s%s%s\n' "$hl_on" "$1" "$hl_off"
}
case :$PATH: in
*:$prefix/bin:*) ;;
*)
  if [ -n "$rc" ]; then
    if [ -f "$rc" ] && grep -qF "$prefix/bin" "$rc"; then
      say "install.sh: $rc already lists $prefix/bin — this shell just has not loaded it."
      say "install.sh: open a new shell, or run: source $rc"
    else
      printf '\n# added by the Emo installer\n%s\n' "$line" >>"$rc"
      say "install.sh: IMPORTANT — the emo command is not visible in THIS shell yet."
      say "install.sh: open a new shell, or run right now: source $rc"
    fi
  else
    say "install.sh: this shell is neither bash nor zsh — add emo to PATH yourself:"
    say "install.sh: $line"
  fi
  ;;
esac
echo "verify the environment with: emo doctor"
