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

[[ "${1:-}" == "--purge" ]] && PURGE=1

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
