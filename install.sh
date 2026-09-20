#!/usr/bin/env bash
#
# sealedmc installer
#
#   curl -fsSL https://raw.githubusercontent.com/YOUR-GITHUB-USER/sealedmc/main/install.sh | bash
#
# Installs the sealedmc wrapper as ~/.local/bin/mc. The wrapper takes over
# the "mc" name, so the real MinIO client must not be on PATH.

set -euo pipefail

REPO="${SEALEDMC_REPO:-YOUR-GITHUB-USER/sealedmc}"
REF="${SEALEDMC_REF:-main}"
RAW_URL="https://raw.githubusercontent.com/$REPO/$REF/mc"

INSTALL_DIR="${SEALEDMC_INSTALL_DIR:-$HOME/.local/bin}"
LIBEXEC_DIR="${SEALEDMC_LIBEXEC_DIR:-$HOME/.local/libexec}"
CONFIG_DIR="${SEALEDMC_CONFIG_DIR:-$HOME/.config/sealedmc}"
TARGET="$INSTALL_DIR/mc"

if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[0m'; Y=$'\033[33m'; G=$'\033[32m'; E=$'\033[31m'
else
  B=''; R=''; Y=''; G=''; E=''
fi

info()  { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$G" "$R" "$*"; }
warn()  { printf '%s!%s %s\n' "$Y" "$R" "$*"; }
fail()  { printf '%s✗%s %s\n' "$E" "$R" "$*" >&2; }

cat <<BANNER

${B}sealedmc installer${R}

sealedmc is a wrapper around the MinIO client. It stores each alias's
credentials in a separate GPG-encrypted file and decrypts them into the
environment of a single mc process, so nothing is ever kept in plaintext
in ~/.mc/config.json.

${B}Important:${R} the wrapper installs itself under the name "mc" in
$INSTALL_DIR. For this to work, the real mc binary must ${B}not${R} be
reachable on your PATH — otherwise whichever comes first wins, and you
would silently keep using the unwrapped client.

The recommended layout is:

    $INSTALL_DIR/mc        <- this wrapper (on PATH)
    $LIBEXEC_DIR/mc    <- the real MinIO client (off PATH)

BANNER

# --- dependencies ----------------------------------------------------------
missing=()
for dep in gpg; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if (( ${#missing[@]} )); then
  fail "missing required command(s): ${missing[*]}"
  info "Install them and re-run this script."
  exit 1
fi

# --- is an existing sealedmc install already in place? --------------------
UPGRADE=0
if [[ -f "$TARGET" ]] && grep -q '^# sealedmc:' "$TARGET" 2>/dev/null; then
  UPGRADE=1
fi

# --- refuse to install while the real mc is on PATH ------------------------
found_mc=""
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  # Our own wrapper (or a previous install of it) does not count.
  grep -q '^# sealedmc:' "$candidate" 2>/dev/null && continue
  found_mc="$candidate"
  break
done < <(type -a -p mc 2>/dev/null || true)

if [[ -n "$found_mc" ]]; then
  fail "the real mc binary is still on your PATH:"
  info ""
  info "    $found_mc"
  info ""
  info "Move it out of PATH so the wrapper can take over the \"mc\" name."
  info "Recommended:"
  info ""
  if [[ -w "$(dirname "$found_mc")" ]]; then
    info "    mkdir -p $LIBEXEC_DIR"
    info "    mv $found_mc $LIBEXEC_DIR/mc"
  else
    info "    mkdir -p $LIBEXEC_DIR"
    info "    sudo mv $found_mc $LIBEXEC_DIR/mc"
    info "    sudo chown \"\$(id -un)\" $LIBEXEC_DIR/mc"
  fi
  info ""
  info "Alternatively, remove $(dirname "$found_mc") from your PATH, or set"
  info "SEALEDMC_LIBEXEC_DIR to wherever you prefer to keep the real binary."
  info ""
  info "Then re-run this installer."
  exit 1
fi

# --- locate the real mc binary (now expected to be off PATH) ---------------
real_mc=""
for candidate in \
  "${MC_BIN:-}" \
  "$LIBEXEC_DIR/mc" \
  "/usr/local/libexec/mc" \
  "/opt/minio/mc"
do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  grep -q '^# sealedmc:' "$candidate" 2>/dev/null && continue
  real_mc="$candidate"
  break
done

if [[ -z "$real_mc" ]]; then
  fail "could not find the real mc binary."
  info ""
  info "sealedmc does not bundle the MinIO client; it wraps yours."
  info "Put the real binary at $LIBEXEC_DIR/mc, or set MC_BIN, then re-run."
  info ""
  info "To download it fresh:"
  info ""
  info "    mkdir -p $LIBEXEC_DIR"
  info "    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o $LIBEXEC_DIR/mc"
  info "    chmod +x $LIBEXEC_DIR/mc"
  info ""
  exit 1
fi
ok "found the real MinIO client at $real_mc"

# --- fetch the wrapper -----------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$script_dir" && -f "$script_dir/mc" ]]; then
  cp "$script_dir/mc" "$tmp"
  ok "using the wrapper from this checkout"
else
  command -v curl >/dev/null 2>&1 || { fail "curl is required to download the wrapper"; exit 1; }
  curl -fsSL "$RAW_URL" -o "$tmp" || { fail "download failed: $RAW_URL"; exit 1; }
  ok "downloaded the wrapper from $REPO@$REF"
fi

head -n1 "$tmp" | grep -q '^#!' || { fail "downloaded file does not look like a script"; exit 1; }
grep -q '^# sealedmc:' "$tmp" || { fail "downloaded file is not the sealedmc wrapper"; exit 1; }
bash -n "$tmp" || { fail "the wrapper failed a syntax check; refusing to install"; exit 1; }

mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp" "$TARGET"
if (( UPGRADE )); then
  ok "upgraded $TARGET"
else
  ok "installed $TARGET"
fi

# --- record where the real binary lives ------------------------------------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
printf '%s\n' "$real_mc" > "$CONFIG_DIR/mc-path"
ok "recorded the real mc path in $CONFIG_DIR/mc-path"

# --- PATH check ------------------------------------------------------------
path_ok=0
case ":$PATH:" in
  *":$INSTALL_DIR:"*) path_ok=1 ;;
esac

# --- GPG recipient check ---------------------------------------------------
recipient_ok=0
[[ -s "$CONFIG_DIR/recipient" || -n "${SEALEDMC_GPG_RECIPIENT:-}" ]] && recipient_ok=1

# --- summary ---------------------------------------------------------------
printf '\n%sInstallation complete.%s\n\n' "$B" "$R"

if (( ! path_ok )); then
  case "${SHELL:-}" in
    */zsh) rcfile="$HOME/.zshrc" ;;
    */bash) rcfile="$HOME/.bashrc" ;;
    *) rcfile="$HOME/.bashrc  (or ~/.zshrc)" ;;
  esac
  if [[ "$INSTALL_DIR" == "$HOME/.local/bin" ]]; then
    path_line='export PATH=$PATH:$HOME/.local/bin'
  else
    path_line="export PATH=\$PATH:$INSTALL_DIR"
  fi
  warn "$INSTALL_DIR is not on your PATH."
  info ""
  info "  Add this line to ${rcfile%% *} and start a new shell:"
  info ""
  info "      $path_line"
  info ""
fi

if (( ! recipient_ok )); then
  warn "no GPG recipient configured yet."
  info ""
  info "  sealedmc encrypts each alias to one of your own GPG keys."
  info "  Set it once:"
  info ""
  info "      echo 'you@example.com' > $CONFIG_DIR/recipient"
  info ""
  info "  (If you have no key yet: gpg --full-generate-key)"
  info ""
fi

info "Next steps:"
info ""
info "  1. Check the wrapper is the one being found:"
info "         command -v mc          # should print $TARGET"
info "         mc --sealedmc-version"
info ""
info "  2. Store an alias (you will be prompted for the keys):"
info "         mc alias set prod https://minio.example.com"
info ""
info "  3. Use mc exactly as before:"
info "         mc ls prod/"
info ""
info "  4. Remove any plaintext credentials left in the old config:"
info "         grep -o '\"url\"[^,]*' ~/.mc/config.json"
info "         $real_mc alias remove <name>     # bypasses the wrapper"
info ""
