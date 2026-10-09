#!/usr/bin/env bash
#
# s3seal uninstaller. Removes the commands and the installed copy. Encrypted
# credentials are kept unless --purge is given.

set -euo pipefail

CONFIG_DIR="${S3SEAL_CONFIG_DIR:-$HOME/.config/s3seal}"
PURGE=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) printf 'usage: uninstall.sh [--purge [--yes]]\n'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Sealed credentials need s3seal to read them; refuse to strand them.
sealed=()
for f in "$CONFIG_DIR"/aws/*.secret.asc "$CONFIG_DIR"/aliases/*.url.asc; do
  [[ -e "$f" ]] && sealed+=("$f")
done
if (( ${#sealed[@]} )); then
  printf 'Credentials are still sealed. Run "s3seal disable aws" and/or "s3seal disable mc" first, then re-run this.\n' >&2
  exit 1
fi

# Locate the installed copy from the s3seal link, if there is one.
SHARE_DIR=""
for dir in "${S3SEAL_INSTALL_DIR:-$HOME/.local/share/s3seal/bin}" "$HOME/.local/bin"; do
  if [[ -L "$dir/s3seal" ]]; then
    SHARE_DIR="$(dirname "$(dirname "$(dirname "$(readlink "$dir/s3seal")")")")"
    break
  fi
done
SHARE_DIR="${S3SEAL_SHARE_DIR:-${SHARE_DIR:-$HOME/.local/share/s3seal}}"
BIN_DIR="${S3SEAL_INSTALL_DIR:-$SHARE_DIR/bin}"

for name in mc aws s3seal; do
  target="$BIN_DIR/$name"
  if [[ -L "$target" && "$(readlink "$target")" == "$SHARE_DIR/libexec/s3seal/$name" ]]; then
    rm -f "$target"
    printf 'Removed %s\n' "$target"
  fi
done

if [[ -d "$SHARE_DIR" ]]; then
  rm -rf "$SHARE_DIR"
  printf 'Removed %s\n' "$SHARE_DIR"
fi

if [[ -r "$CONFIG_DIR/mc-path" ]]; then
  printf '\nThe official mc is still at %s; it was not removed.\n' "$(head -n1 "$CONFIG_DIR/mc-path")"
fi

if (( PURGE )); then
  if (( ! ASSUME_YES )); then
    if ! { : < /dev/tty; } 2>/dev/null; then
      printf 'Refusing to purge without a terminal to confirm; pass --yes.\n' >&2
      exit 1
    fi
    printf 'This permanently deletes %s, including every encrypted credential.\n' "$CONFIG_DIR" > /dev/tty
    read -r -p 'Type "purge" to continue: ' answer < /dev/tty
    if [[ "$answer" != purge ]]; then
      printf 'Aborted; nothing was purged.\n'
      exit 1
    fi
  fi
  rm -rf "$CONFIG_DIR"
  printf '\nPurged %s (encrypted credentials deleted).\n' "$CONFIG_DIR"
else
  printf '\nEncrypted credentials kept in %s\n' "$CONFIG_DIR"
  printf 'Re-run with --purge to delete them.\n'
fi
