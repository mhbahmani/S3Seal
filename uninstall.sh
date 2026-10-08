#!/usr/bin/env bash
#
# sealedmc uninstaller. Removes the wrapper and, optionally, restores the
# real mc binary to a directory on PATH. Encrypted credentials are kept
# unless --purge is given.

set -euo pipefail

INSTALL_DIR="${SEALEDMC_INSTALL_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${SEALEDMC_CONFIG_DIR:-$HOME/.config/sealedmc}"
TARGET="$INSTALL_DIR/mc"
PURGE=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      printf 'usage: uninstall.sh [--purge [--yes]]\n'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Purging deletes every stored credential, so it has to be confirmed.
if (( PURGE && ! ASSUME_YES )); then
  if ! { : < /dev/tty; } 2>/dev/null; then
    printf 'Refusing to purge without a terminal to confirm; pass --yes.\n' >&2
    exit 1
  fi
  printf 'This permanently deletes %s, including every encrypted alias.\n' "$CONFIG_DIR" > /dev/tty
  read -r -p 'Type "purge" to continue: ' answer < /dev/tty
  if [[ "$answer" != purge ]]; then
    printf 'Aborted; nothing was removed.\n'
    exit 1
  fi
fi

if [[ -f "$TARGET" ]] && grep -q '^# sealedmc:' "$TARGET" 2>/dev/null; then
  rm -f "$TARGET"
  printf 'Removed %s\n' "$TARGET"
else
  printf 'No sealedmc wrapper found at %s\n' "$TARGET"
fi

if [[ -r "$CONFIG_DIR/mc-path" ]]; then
  real_mc="$(head -n1 "$CONFIG_DIR/mc-path")"
  printf '\nThe real MinIO client is still at:\n    %s\n' "$real_mc"
  printf 'Put it back on your PATH if you want to use it directly, e.g.:\n'
  printf '    mv %s %s/mc\n' "$real_mc" "$INSTALL_DIR"
fi

if (( PURGE )); then
  rm -rf "$CONFIG_DIR"
  printf '\nPurged %s (encrypted credentials deleted).\n' "$CONFIG_DIR"
else
  printf '\nEncrypted credentials kept in %s\n' "$CONFIG_DIR"
  printf 'Re-run with --purge to delete them.\n'
fi
