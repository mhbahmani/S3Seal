#!/usr/bin/env bash
#
# s3seal installer
#
#   curl -fsSL https://raw.githubusercontent.com/mhbahmani/s3seal/master/install.sh | bash
#
# Asks which clients to protect and where to install. Press Enter to accept the
# defaults. Installs s3seal, moves official clients out of PATH when you agree,
# and runs "s3seal enable" for each protected client.

set -euo pipefail

DEFAULT_REPO="mhbahmani/s3seal"

DEV=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    -h|--help)
      printf 'usage: install.sh [--dev]\n  --dev  install from the master branch instead of the latest release\n'
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

REPO="${S3SEAL_REPO:-$DEFAULT_REPO}"

# The newest published release. A repository without releases falls back to its
# newest tag. Prints nothing when neither exists.
latest_release() {  # REPO
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  if [[ -z "$tag" ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/$1/tags" 2>/dev/null \
      | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | sort -V | tail -n1)"
  fi
  printf '%s' "$tag"
}

# Which version to download. Resolved only when the files come from GitHub.
if (( DEV )); then
  REF=master
elif [[ -n "${S3SEAL_REF:-}" ]]; then
  REF="$S3SEAL_REF"
else
  REF=""
fi

CONFIG_DIR="${S3SEAL_CONFIG_DIR:-$HOME/.config/s3seal}"

# Files to install.
FILES="libexec/mc libexec/aws libexec/s3seal lib/common.sh lib/ini.sh lib/aws.sh lib/mc.sh lib/keys.sh lib/ui.sh"
ENTRIES="libexec/mc libexec/aws libexec/s3seal"


# Colours only when writing to a terminal. Output goes to stderr, so functions
# can still return values on stdout.
if [[ -t 2 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
else
  BOLD=''; DIM=''; RESET=''; RED=''; GREEN=''; YELLOW=''; CYAN=''
fi

banner() {
  printf '\n  %ss3seal%s  %sencrypted S3 credentials for mc and aws%s\n' "$BOLD" "$RESET" "$DIM" "$RESET" >&2
}
step() { printf '\n%s%s▸ %s%s\n' "$BOLD" "$CYAN" "$*" "$RESET" >&2; }
info() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET" >&2; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf '  %s✖%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# Upgrades run through "s3seal upgrade" and never ask questions.
# S3SEAL_YES=1 accepts every default without asking, for scripted installs.
INTERACTIVE=0
if [[ -z "${S3SEAL_UPGRADE:-}" && -z "${S3SEAL_YES:-}" ]] && { : < /dev/tty; } 2>/dev/null; then
  INTERACTIVE=1
fi

# ask QUESTION DEFAULT(y|n): returns 0 for yes. Without a terminal, uses DEFAULT.
ask() {
  local reply=''
  if (( INTERACTIVE )); then
    read -r -p "$1 " reply < /dev/tty || true
  fi
  reply="${reply:-$2}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ask_dir QUESTION DEFAULT: prints the chosen directory, with ~ expanded.
ask_dir() {
  local reply=''
  if (( INTERACTIVE )); then
    read -r -p "$1 [$2]: " reply < /dev/tty || true
  fi
  reply="${reply:-$2}"
  printf '%s' "${reply/#\~/$HOME}"
}


is_wrapper() { grep -q '^# s3seal:' "$1" 2>/dev/null; }

# On many Linux distributions "mc" is Midnight Commander, not MinIO's client.
is_minio_mc() { "$1" --version 2>/dev/null | grep -q 'RELEASE\.'; }

# Resolves symlinks, so links into our own install are recognised.
resolve_path() {
  local s="$1" t
  while [[ -L "$s" ]]; do
    t="$(readlink "$s")"
    [[ "$t" == /* ]] && s="$t" || s="$(dirname "$s")/$t"
  done
  printf '%s/%s' "$(cd "$(dirname "$s")" && pwd)" "$(basename "$s")"
}

# Prints the official client for NAME (a list of candidate names), skipping
# s3seal's own links. Prints nothing if there is none.
find_official() {
  local names="$1" name d c r
  if [[ -r "$CONFIG_DIR/${names%% *}-path" ]]; then
    c="$(head -n1 "$CONFIG_DIR/${names%% *}-path")"
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  fi
  for name in $names; do
    for d in ${PATH//:/ }; do
      [[ -n "$d" ]] || continue
      c="$d/$name"
      [[ -f "$c" && -x "$c" ]] || continue
      r="$(resolve_path "$c")"
      [[ "$r" == */s3seal/libexec/* ]] && continue
      if [[ "$name" == mc ]] && ! is_minio_mc "$c"; then
        warn "$c is not the MinIO client (Midnight Commander?); ignoring it" >&2
        continue
      fi
      printf '%s' "$c"
      return 0
    done
  done
  return 1
}

version_of() { sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n1; }

client_label() {
  case "$1" in
    mc) printf 'mc    the MinIO client' ;;
    aws) printf 'aws   the AWS CLI' ;;
  esac
}

# Checkbox menu over the names given. Up and down move, space toggles, Enter
# confirms. All start checked. Prints the chosen names on stdout.
checkbox_menu() {
  local -a names=("$@") checked=()
  local n=${#names[@]} i cur=0 key rest first=1 mark ptr
  for ((i = 0; i < n; i++)); do checked[i]=1; done
  printf 'Select the clients to protect (arrows move, space toggles, Enter confirms):\n' >&2
  while true; do
    if (( ! first )); then printf '\033[%dA' "$n" >&2; fi
    first=0
    for ((i = 0; i < n; i++)); do
      mark=' '; ptr=' '
      if (( checked[i] )); then mark='x'; fi
      if (( i == cur )); then ptr='>'; fi
      printf '\033[2K %s [%s] %s\n' "$ptr" "$mark" "$(client_label "${names[i]}")" >&2
    done
    IFS= read -rsn1 key < /dev/tty || break
    if [[ "$key" == $'\e' ]]; then
      IFS= read -rsn2 rest < /dev/tty || true
      case "$rest" in
        '[A') if (( cur > 0 )); then cur=$((cur - 1)); else cur=$((n - 1)); fi ;;
        '[B') cur=$(((cur + 1) % n)) ;;
      esac
    elif [[ "$key" == ' ' ]]; then
      checked[cur]=$((1 - checked[cur]))
    elif [[ -z "$key" ]]; then
      break
    fi
  done
  local out=''
  for ((i = 0; i < n; i++)); do
    if (( checked[i] )); then out+="${names[i]} "; fi
  done
  printf '%s' "$out"
}

# Installs gpg with the system's package manager, after asking.
install_gpg() {
  local cmd=''
  if command -v brew >/dev/null 2>&1; then cmd='brew install gnupg'
  elif command -v apt-get >/dev/null 2>&1; then cmd='sudo apt-get install -y gnupg'
  elif command -v dnf >/dev/null 2>&1; then cmd='sudo dnf install -y gnupg2'
  elif command -v pacman >/dev/null 2>&1; then cmd='sudo pacman -S --noconfirm gnupg'
  fi
  [[ -n "$cmd" ]] || fail "gpg is required, and no known package manager was found. Install gnupg and re-run."
  if ask "gpg is needed to encrypt credentials. Install it now with '$cmd'? [Y/n]:" y; then
    $cmd || fail "installing gpg failed"
  else
    fail "gpg is required. Install it and re-run."
  fi
}

# --- questions ---------------------------------------------------------------
banner
if ! command -v gpg >/dev/null 2>&1; then
  if (( INTERACTIVE )); then
    install_gpg
  else
    fail "gpg is required. Install it (for example: sudo apt-get install gnupg) and re-run."
  fi
fi
command -v curl >/dev/null 2>&1 || fail "curl is required"

SEAL_MC=0 SEAL_AWS=0
if [[ -z "${S3SEAL_UPGRADE:-}" ]]; then
  step "Clients"
  # Only clients that are installed here can be protected.
  PRESENT=()
  if [[ -n "$(find_official "mc mcli" 2>/dev/null || true)" ]]; then PRESENT+=(mc); fi
  if [[ -n "$(find_official "aws" 2>/dev/null || true)" ]]; then PRESENT+=(aws); fi

  SELECTED=""
  if (( ${#PRESENT[@]} == 0 )); then
    info "No supported client was found on PATH (mc, aws). Install one and re-run the installer."
  elif (( INTERACTIVE )); then
    info ""
    SELECTED="$(checkbox_menu "${PRESENT[@]}")"
  else
    SELECTED="${PRESENT[*]}"
  fi
  case " $SELECTED " in *" mc "*) SEAL_MC=1 ;; esac
  case " $SELECTED " in *" aws "*) SEAL_AWS=1 ;; esac
  info ""
fi

step "Install location"
if [[ -n "${S3SEAL_SHARE_DIR:-}" ]]; then
  SHARE_DIR="$S3SEAL_SHARE_DIR"
else
  SHARE_DIR="$(ask_dir "Install s3seal to" "$HOME/.local/share/s3seal")"
fi
# The commands go in a bin folder next to the installed copy.
BIN_DIR="${S3SEAL_INSTALL_DIR:-$SHARE_DIR/bin}"
LIBEXEC_DIR="${S3SEAL_LIBEXEC_DIR:-}"   # asked later, only if an official client must move

# --- download and verify -----------------------------------------------------
info ""
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/libexec" "$stage/lib"

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$script_dir" && -f "$script_dir/libexec/mc" && -f "$script_dir/lib/common.sh" ]]; then
  REF="${REF:-checkout}"
  info "Copying s3seal from this checkout..."
  for f in $FILES; do cp "$script_dir/$f" "$stage/$f"; done
else
  step "Download"
  if [[ -z "$REF" ]]; then
    command -v curl >/dev/null 2>&1 || fail "curl is required to download s3seal"
    REF="$(latest_release "$REPO")"
    [[ -n "$REF" ]] || fail "no release found for $REPO; use --dev to install master"
  fi
  if (( DEV )); then info_release="development build from master"; else info_release="release $REF"; fi
  RAW_URL="https://raw.githubusercontent.com/$REPO/$REF"
  info "$info_release from $REPO"
  for f in $FILES; do
    curl -fsSL "$RAW_URL/$f" -o "$stage/$f" || fail "download failed: $RAW_URL/$f"
  done
  # shellcheck disable=SC2086  # word splitting is the point here
  set -- $FILES
  ok "downloaded $# files"
fi

step "Check"
for f in $ENTRIES; do
  head -n1 "$stage/$f" | grep -q '^#!' || fail "$f does not look like a script"
  grep -q '^# s3seal:' "$stage/$f" || fail "$f is not an s3seal file"
done
for f in $FILES; do
  bash -n "$stage/$f" || fail "$f failed a syntax check; refusing to install"
done
# shellcheck source=lib/common.sh
. "$stage/lib/common.sh"
# shellcheck source=lib/keys.sh
. "$stage/lib/keys.sh"

# --- install -----------------------------------------------------------------
step "Install"
installed_version=""
[[ -f "$SHARE_DIR/libexec/s3seal" ]] && installed_version="$(version_of "$SHARE_DIR/libexec/s3seal")"
new_version="$(version_of "$stage/libexec/s3seal")"

changed=()
for f in $FILES; do
  cmp -s "$stage/$f" "$SHARE_DIR/$f" || changed+=("$f")
done

if [[ -z "$installed_version" ]]; then
  state=fresh
elif (( ${#changed[@]} == 0 )); then
  state=same
elif [[ "$installed_version" == "$new_version" ]]; then
  state=refresh
else
  state=upgrade
fi

case "$state" in
  fresh)   info "Installing s3seal $new_version ($REF)." ;;
  same)    ok "s3seal $new_version is already installed and up to date." ;;
  refresh) info "s3seal $new_version ($REF) is already installed. Refreshing ${#changed[@]} changed file(s)." ;;
  upgrade) info "Upgrading s3seal $installed_version -> $new_version ($REF)." ;;
esac

# A libexec/s3seal folder left by an older layout would block the program file.
if [[ -d "$SHARE_DIR/libexec/s3seal" && -f "$SHARE_DIR/libexec/s3seal/s3seal" ]]; then
  rm -rf "$SHARE_DIR/libexec/s3seal"
fi
mkdir -p "$SHARE_DIR/libexec" "$SHARE_DIR/lib" "$BIN_DIR"
if [[ "$state" != same ]]; then
  for f in "${changed[@]}"; do
    case "$f" in
      lib/*) mode=0644 ;;
      *) mode=0755 ;;
    esac
    # Write beside the target and rename over it: a running s3seal keeps its old
    # file, so an upgrade started from s3seal itself cannot corrupt the process.
    install -m "$mode" "$stage/$f" "$SHARE_DIR/$f.new"
    mv -f "$SHARE_DIR/$f.new" "$SHARE_DIR/$f"
  done
  ok "installed s3seal $new_version into $SHARE_DIR"
fi
printf '%s %s\n' "$REPO" "$REF" > "$SHARE_DIR/source"

# Replaces a symlink or an older regular-file wrapper; refuses anything else.
link_command() {
  local target="$BIN_DIR/$1"
  if [[ -L "$target" && "$(readlink "$target")" == "$SHARE_DIR/libexec/$1" ]]; then
    return 0
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" ]] || is_wrapper "$target"; then
      rm -f "$target"
    else
      fail "$target exists and is not s3seal; move it aside and re-run"
    fi
  fi
  ln -s "$SHARE_DIR/libexec/$1" "$target"
}
link_command s3seal
ok "linked s3seal into $BIN_DIR"

# Name of the user owning PATH (GNU and BSD stat differ).
owner_of() { stat -c %U "$1" 2>/dev/null || stat -f %Su "$1"; }

# Moves FROM to TO. On failure, explains which part of the permissions blocks
# it, and prints the command that does it with sudo.
move_client() {  # FROM TO
  local from="$1" to="$2" src_dir dst_dir owner
  src_dir="$(dirname "$from")"
  dst_dir="$(dirname "$to")"
  if mkdir -p "$dst_dir" 2>/dev/null && mv -f "$from" "$to" 2>/dev/null; then
    ok "  moved to $to"
    return 0
  fi
  # Not root and the move was refused: the user already agreed to the move, so
  # escalate with sudo (it asks for the password on this terminal).
  if [[ "$(id -u)" != 0 && -z "${S3SEAL_NO_SUDO:-}" ]] && command -v sudo >/dev/null 2>&1; then
    info "  $(id -un) cannot move it directly. Using sudo for this move."
    if sudo mkdir -p "$dst_dir" && sudo mv -f "$from" "$to"; then
      ok "  moved to $to"
      return 0
    fi
  fi
  owner="$(owner_of "$from")"
  warn "  could not move $from to $to"
  info "    running as user: $(id -un)"
  if [[ ! -w "$src_dir" ]]; then
    info "    $src_dir is not writable by $(id -un) (owned by $(owner_of "$src_dir"))"
  fi
  if ! mkdir -p "$dst_dir" 2>/dev/null; then
    info "    $dst_dir cannot be created by $(id -un)"
  elif [[ ! -w "$dst_dir" ]]; then
    info "    $dst_dir is not writable by $(id -un)"
  fi
  if [[ "$owner" != "$(id -un)" ]]; then
    info "    $from is owned by $owner"
  fi
  info "  Moving it needs root. Run this command yourself:"
  info "      sudo mv $from $to"
  return 1
}

# --- protected clients ------------------------------------------------------
# Moves an official client out of PATH (with consent) and records where it is,
# then lets "s3seal enable" take over the name.
setup_client() {  # NAME CANDIDATES
  local tool="$1" found new
  found="$(find_official "$2")" || true
  if [[ -z "$found" ]]; then
    warn "$tool: no official client found on PATH. Install it, then run: $SHARE_DIR/libexec/s3seal enable $tool"
    return 0
  fi

  local here; here="$(dirname "$found")"
  if [[ "$here" != "$HOME/.local/libexec" && ( -z "$LIBEXEC_DIR" || "$here" != "$LIBEXEC_DIR" ) ]]; then
    if (( INTERACTIVE )) && ask "  Move it out of PATH so s3seal can use the name $tool? [Y/n]:" y; then
      if [[ -z "$LIBEXEC_DIR" ]]; then
        LIBEXEC_DIR="$(ask_dir "  Keep it in" "$HOME/.local/libexec")"
      fi
      new="$LIBEXEC_DIR/$tool"
      if move_client "$found" "$new"; then
        found="$new"
      elif (( INTERACTIVE )); then
        printf '  Run the command above in another terminal, then press Enter to continue.\n' >&2
        read -r -p '  ' _ < /dev/tty || true
        if [[ -f "$new" && ! -e "$found" ]]; then
          ok "  moved to $new"
          found="$new"
        else
          warn "  $found was not moved; continuing with its current location"
        fi
      fi
    else
      info "  left in place; $BIN_DIR must come before its directory on PATH."
    fi
  fi

  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$found" > "$CONFIG_DIR/$tool-path"
  S3SEAL_INSTALL_DIR="$BIN_DIR" "$SHARE_DIR/libexec/s3seal" enable "$tool" \
    || warn "could not enable $tool; run: s3seal enable $tool"
}

if [[ -z "${S3SEAL_UPGRADE:-}" ]]; then
  if (( SEAL_MC || SEAL_AWS )); then step "Official clients"; fi
  if (( SEAL_MC )); then setup_client mc "mc mcli"; fi
  if (( SEAL_AWS )); then setup_client aws "aws"; fi
fi

# --- GPG key -----------------------------------------------------------------
# Reads a value without echoing it.
ask_secret() {
  local v=''
  read -rs -p "$1" v < /dev/tty || true
  echo > /dev/tty
  printf '%s' "$v"
}

# Asks only for a passphrase (twice, not echoed), then creates the key pair.
# The key is labelled with the user running the installer and the date, so the
# user never has to think about key names. Prints the fingerprint.
new_key_flow() {
  local pass pass2 fpr label
  label="s3seal $(id -un) $(date +%Y-%m-%d)"
  info "Choose a passphrase for the encryption key. You will need it when s3seal reads credentials."
  while true; do
    pass="$(ask_secret 'Passphrase (at least 8 characters): ')"
    if (( ${#pass} < 8 )); then warn "at least 8 characters"; continue; fi
    pass2="$(ask_secret 'Repeat the passphrase: ')"
    [[ "$pass" == "$pass2" ]] && break
    warn "the passphrases do not match"
  done
  fpr="$(key_create "$label" "$pass")"
  [[ -n "$fpr" ]] || fail "could not create the GPG key"
  printf '%s' "$fpr"
}

setup_key() {
  local current answer fpr
  if [[ -n "${S3SEAL_GPG_RECIPIENT:-}" ]]; then
    ok "using the GPG key from S3SEAL_GPG_RECIPIENT"
    return 0
  fi

  if current="$(key_current)"; then
    ok "s3seal already has its key ($current). Keeping it."
    if (( INTERACTIVE )) && ask "Replace it with a new key pair? Every stored credential is re-encrypted first, and the old pair is removed if s3seal created it. [y/N]:" n; then
      info "Creating the new key pair."
      fpr="$(new_key_flow)"
      key_rekey "$fpr" >/dev/null
      ok "stored credentials are now encrypted to $fpr"
    fi
    return 0
  fi

  if (( ! INTERACTIVE )); then
    warn "no GPG key yet. Run the installer in a terminal to create one."
    return 0
  fi
  info ""
  info "s3seal encrypts credentials with a GPG key. It keeps the private key in your GPG keyring."
  read -r -p "Use an existing GPG key? Enter its email or key ID, or press Enter to create one for s3seal: " answer < /dev/tty || true
  if [[ -n "$answer" ]]; then
    gpg --batch --list-secret-keys "$answer" >/dev/null 2>&1 || fail "no secret key matches '$answer'"
    key_use "$answer" no
    ok "using your key $answer"
  else
    fpr="$(new_key_flow)"
    key_use "$fpr" yes
    ok "created the key pair $fpr"
  fi
}

if [[ -z "${S3SEAL_UPGRADE:-}" ]]; then
  step "Encryption key"
  setup_key
fi

# --- summary -----------------------------------------------------------------
step "Status"
"$SHARE_DIR/libexec/s3seal" status >&2 || true

# One note for the whole install: the commands folder must come first on PATH.
case ":$PATH:" in
  "$BIN_DIR:"*) ;;
  *)
    case "${SHELL:-}" in
      */zsh) rc="$HOME/.zshrc" ;;
      */bash) rc="$HOME/.bashrc" ;;
      *) rc="$HOME/.profile" ;;
    esac
    info ""
    warn "To use s3seal's mc and aws, add this line to $rc, then open a new shell:"
    info ""
    info "    export PATH=\"${BIN_DIR/#$HOME/\$HOME}:\$PATH\""
    info "" ;;
esac

step "Getting started"
info "add a mc alias      mc alias set NAME URL      keys are stored encrypted"
info "list mc aliases     mc alias ls"
info "add an aws profile  aws configure --profile NAME"
info "list aws profiles   aws configure list-profiles"
info "check what is sealed  s3seal status"
