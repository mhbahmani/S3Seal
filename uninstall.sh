#!/usr/bin/env bash
#
# s3seal uninstaller. Removes the commands and the installed copy. Encrypted
# credentials are kept unless --purge is given.

set -euo pipefail

INSTALL_DIR="${S3SEAL_INSTALL_DIR:-$HOME/.local/bin}"
SHARE_DIR="${S3SEAL_SHARE_DIR:-$HOME/.local/share/s3seal}"
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

# Sealed AWS profiles need s3seal's credential_process; refuse to break them.
sealed=0
for f in "$CONFIG_DIR"/aws/*.secret.asc; do
  [[ -e "$f" ]] && sealed=1
done
if (( sealed )); then
  printf 'AWS profiles are still sealed. Run "s3seal disable aws" first, then re-run this.\n' >&2
  exit 1
fi

for name in mc aws s3seal; do
  target="$INSTALL_DIR/$name"
  if [[ -L "$target" && "$(readlink "$target")" == "$SHARE_DIR/$name" ]]; then
    rm -f "$target"
    printf 'Removed %s\n' "$target"
  elif [[ -f "$target" ]] && grep -q '^# s3seal:' "$target" 2>/dev/null; then
    rm -f "$target"
    printf 'Removed %s\n' "$target"
  fi
done

if [[ -d "$SHARE_DIR" ]]; then
  rm -rf "$SHARE_DIR"
  printf 'Removed %s\n' "$SHARE_DIR"
fi

if [[ -r "$CONFIG_DIR/mc-path" ]]; then
  real_mc="$(head -n1 "$CONFIG_DIR/mc-path")"
  printf '\nThe real MinIO client is still at:\n    %s\n' "$real_mc"
  printf 'Put it back on your PATH if you want to use it directly, e.g.:\n'
  printf '    mv %s %s/mc\n' "$real_mc" "$INSTALL_DIR"
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
