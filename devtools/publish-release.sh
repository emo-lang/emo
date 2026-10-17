#!/bin/sh
# Publishes a release to the download site — the pipeline's last leg.
# GitHub stays behind the scenes: CI drafts the release, the signing
# Mac notarizes it, and this script carries the finished assets to
# www.emo-lang.cn, the only public download channel — GitHub is
# unreachable for much of the audience this release is for.
#
# Usage: publish-release.sh <tag> [--dry-run]
#
# Archives land on the site first; dist/releases.json — the
# latest-version pointer install.sh resolves — is rewritten last,
# through a temp file + rename, so no version is ever resolvable
# before its files are complete. Re-running is idempotent: the
# archives re-upload in place and the JSON re-merges.
#
# The upload rides SSH — no stored credentials here: EMO_RELEASE_HOST
# (default ubuntu@www.emo-lang.cn) must already accept your key.
# EMO_RELEASE_STATIC_ROOT is the site's static root (default
# /home/ubuntu/sites/website-cn/static, served at /cdn); EMO_REPO is
# the GitHub repository the draft lives under (default emo-lang/emo).
set -e

tag=$1
dry_run=false
[ "${2:-}" = "--dry-run" ] && dry_run=true
if [ -z "$tag" ]; then
  echo "usage: publish-release.sh <tag> [--dry-run]" >&2
  exit 64
fi
repo=${EMO_REPO:-emo-lang/emo}
host=${EMO_RELEASE_HOST:-ubuntu@www.emo-lang.cn}
root=${EMO_RELEASE_STATIC_ROOT:-/home/ubuntu/sites/website-cn/static}

work=$(mktemp -d "${TMPDIR:-/tmp}/emo-publish.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo "publish: downloading $tag's assets from the $repo draft"
gh release download "$tag" --repo "$repo" --dir "$work" --clobber

# The draft must carry the whole release: four archives and the
# checksums covering them — anything less means CI or notarize
# stopped midway.
sums=$work/SHA256SUMS
if [ ! -f "$sums" ]; then
  echo "publish-release.sh: release $tag has no SHA256SUMS" >&2
  exit 65
fi
set -- $(cd "$work" && ls emo-* 2>/dev/null | grep -v '\.sha256$')
if [ "$#" -ne 4 ]; then
  echo "publish-release.sh: expected 4 archives in release $tag, found $#" >&2
  exit 65
fi
for archive in "$@"; do
  case $archive in
  emo-"$tag"-*) ;;
  *)
    echo "publish-release.sh: $archive does not belong to $tag" >&2
    exit 65
    ;;
  esac
done

# Verify the sums whole before anything leaves this machine — the
# same check install.sh performs at the far end.
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$work" && sha256sum -c SHA256SUMS) || exit 65
else
  (cd "$work" && shasum -a 256 -c SHA256SUMS) || exit 65
fi

# Merge this tag into dist/releases.json. The file has one fixed
# shape — written here, read by scripts/install.sh: "latest" is the
# first key on its own line (so a plain sed resolves it without a jq
# dependency), and each release entry sits on one line. Previous
# entries come from the server's copy, so a re-publish never drops
# history. --dry-run touches nothing on the server, so it always
# shows a fresh history.
json=$work/releases.json
history=
if [ "$dry_run" = false ]; then
  if ssh "$host" cat "$root/dist/releases.json" >"$json.old" 2>/dev/null; then
    history=$(
      grep -E '^    \{ "tag": "v[0-9][^"]*", "date": "[0-9]{4}-[0-9]{2}-[0-9]{2}" \},?$' \
        "$json.old" | grep -v "\"tag\": \"$tag\"" || true
    )
    [ -n "$history" ] && history=$(printf '%s\n' "$history" | sed 's/,$//')
  else
    echo "publish: no releases.json on the server yet — starting fresh"
  fi
fi
entry="    { \"tag\": \"$tag\", \"date\": \"$(date -u +%F)\" }"
if [ -n "$history" ]; then
  entries=$(printf '%s\n%s' "$entry" "$history")
else
  entries=$entry
fi
entries=$(printf '%s\n' "$entries" | sed '$!s/$/,/')
{
  printf '{\n  "latest": "%s",\n' "$tag"
  printf '  "updated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "releases": [\n%s\n  ]\n}\n' "$entries"
} >"$json"

if [ "$dry_run" = true ]; then
  echo "dry run: would upload to $host:$root/dist/$tag/:"
  printf '  %s\n' "$@" SHA256SUMS
  echo "dry run: would write $root/dist/releases.json:"
  sed 's/^/  /' "$json"
  exit 0
fi

echo "publish: uploading the archives to $host"
ssh "$host" "mkdir -p '$root/dist/$tag'"
(cd "$work" && scp -q -- "$@" SHA256SUMS "$host:$root/dist/$tag/")

echo "publish: pointing releases.json at $tag"
scp -q "$json" "$host:$root/dist/releases.json.incoming"
ssh "$host" "mv '$root/dist/releases.json.incoming' '$root/dist/releases.json'"

echo "publish: $tag is live at https://www.emo-lang.cn/cdn/dist/$tag/"
