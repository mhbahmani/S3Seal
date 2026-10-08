#!/usr/bin/env bash
#
# Regenerate the CHECKSUMS table in install.sh from the files it installs.
# Run this after any change to an installed file.

set -euo pipefail

cd "$(dirname "$0")/.."

FILES="bin/mc bin/aws bin/s3seal lib/common.sh lib/ini.sh lib/aws.sh lib/mc.sh"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

table=""
for f in $FILES; do
  table+="$(sha "$f")  $f"$'\n'
done

# Replace the lines between the CHECKSUMS heredoc start and the SUMS terminator.
TABLE="$table" MARKER="CHECKSUMS=\"\$(cat <<'SUMS'" awk '
  index($0, ENVIRON["MARKER"]) == 1 { print; printf "%s", ENVIRON["TABLE"]; skip = 1; next }
  skip && $0 == "SUMS" { skip = 0 }
  !skip { print }
' install.sh > install.sh.tmp
cat install.sh.tmp > install.sh
rm -f install.sh.tmp

printf 'install.sh updated for:\n%s' "$table"
