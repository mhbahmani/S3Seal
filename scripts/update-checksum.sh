#!/usr/bin/env bash
#
# Embed the SHA-256 of the wrapper into install.sh. Run this whenever mc
# changes; the test suite fails if the two disagree.

set -euo pipefail

cd "$(dirname "$0")/.."

if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum mc | cut -d' ' -f1)"
else
  sum="$(shasum -a 256 mc | cut -d' ' -f1)"
fi

tmp="$(mktemp)"
sed -E "s/^WRAPPER_SHA256=\"[^\"]*\"/WRAPPER_SHA256=\"$sum\"/" install.sh > "$tmp"
cat "$tmp" > install.sh
rm -f "$tmp"
printf 'install.sh now expects mc sha256 %s\n' "$sum"
