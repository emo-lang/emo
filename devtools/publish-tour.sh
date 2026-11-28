#!/bin/sh
# publish-tour — build the language tour site and carry it to
# docs.emo-lang.cn.
#
#   publish-tour.sh [--dry-run]
#
# The build renders docs/intro/tour.md and docs/zh-CN/intro/tour.md into static
# HTML (devtools/build-tour-site.py). The upload rides the same SSH
# channel as the release: EMO_DOCS_HOST (default
# ubuntu@www.emo-lang.cn) must already accept your key, and
# EMO_DOCS_ROOT is the site's static root (default
# /var/www/docs.emo-lang.cn/static).
#
# One-time server setup (DNS, nginx, TLS) is in
# devtools/nginx/docs.emo-lang.cn.conf.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
host=${EMO_DOCS_HOST:-ubuntu@www.emo-lang.cn}
root=${EMO_DOCS_ROOT:-/var/www/docs.emo-lang.cn/static}
out=${EMO_DOCS_OUT:-"$ROOT/_build/tour-site"}

dry=false
for arg in "$@"; do
  case $arg in
  --dry-run) dry=true ;;
  *)
    echo "usage: publish-tour.sh [--dry-run]" >&2
    exit 64
    ;;
  esac
done

python3 "$ROOT/devtools/build-tour-site.py" --out "$out" \
  --branch "${EMO_DOCS_BRANCH:-develop}"

if [ "$dry" = true ]; then
  echo "dry run: would upload $out to $host:$root"
  find "$out" -type f | sed "s|$out/|  |"
  exit 0
fi

ssh "$host" "mkdir -p '$root'"
# tar over the existing SSH channel: no rsync dependency and no
# --delete, so a publish only adds or replaces files. COPYFILE_DISABLE
# keeps macOS from wrapping every file in an AppleDouble ._ entry.
COPYFILE_DISABLE=1 tar -C "$out" -czf - . | ssh "$host" "tar -xzf - -C '$root'"

echo "publish: the tour is live at https://docs.emo-lang.cn/guides/tour/"
