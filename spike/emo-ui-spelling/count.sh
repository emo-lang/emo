#!/usr/bin/env bash
# Source cost of each spelling, as lexical counts.
#
#   ./count.sh
#
# The numbers are proxies, not a proof of readability: non-comment lines,
# bytes, and the tokens a parsed tree literal would delete outright — every
# `children:` label and every bracket. They are meaningful here only
# because both spellings produce byte-identical trees (main.emo asserts
# it), so a lexical difference between screens_a.emo and screens_b.emo
# cannot be a difference in what the program builds.
#
# Comments are excluded only when a line is nothing but a comment; a
# trailing `// ...` still counts, and a `children:` inside a string would
# too. Neither occurs in these files.

set -euo pipefail
cd "$(dirname "$0")"

files=(
  ui.emo components.emo debug.emo model.emo tags.emo app.emo features.emo
  measure.emo screens_a.emo screens_b.emo main.emo naive_crash.emo
)

printf '%-18s %6s %7s %10s %9s %8s %9s\n' \
  file L bytes 'children:' brackets sugar 'sugar/L'

for f in "${files[@]}"; do
  awk -v file="$f" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        t = line[i]
        sub(/^[ \t]+/, "", t)
        if (t == "" || t ~ /^\/\//) continue
        L++
        bytes += length(line[i]) + 1
        c += gsub(/children:/, "children:", line[i])
        b += gsub(/\[/, "[", line[i])
        b += gsub(/\]/, "]", line[i])
      }
      sugar = c + b
      printf "%-18s %6d %7d %10d %9d %8d %9.3f\n",
             file, L, bytes, c, b, sugar, (L ? sugar / L : 0)
    }
  ' "$f"
done
