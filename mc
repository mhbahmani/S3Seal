#!/usr/bin/env bash
#
# sealedmc: a drop-in wrapper around the MinIO client (mc) that keeps
# credentials in per-alias GPG-encrypted files instead of plaintext in
# ~/.mc/config.json.
#
# Credentials are decrypted into the environment of a single exec'd mc
# process. They are never written to disk unencrypted, never passed in
# argv, and never stored in shell history.
#
# https://github.com/YOUR-GITHUB-USER/sealedmc

set -euo pipefail

VERSION="1.0.0"

CONFIG_DIR="${SEALEDMC_CONFIG_DIR:-$HOME/.config/sealedmc}"
STORE="$CONFIG_DIR/aliases"
RECIPIENT_FILE="$CONFIG_DIR/recipient"
MC_PATH_FILE="$CONFIG_DIR/mc-path"

die() { printf 'sealedmc: %s\n' "$*" >&2; exit 1; }
warn() { printf 'sealedmc: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Locate the real mc binary.
#
# The wrapper is installed as "mc" in ~/.local/bin, so the real binary must
# live somewhere outside PATH (or at least be resolvable without going
# through this script again).
# ---------------------------------------------------------------------------
resolve_self() {
  local s="$0"
  while [[ -L "$s" ]]; do
    local t; t="$(readlink "$s")"
    [[ "$t" == /* ]] && s="$t" || s="$(dirname "$s")/$t"
  done
  printf '%s' "$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"
}

SELF="$(resolve_self)"

is_self() {
  local candidate
  candidate="$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")" || return 0
  [[ "$candidate" == "$SELF" ]]
}

# On many Linux distributions /usr/bin/mc is Midnight Commander, so a binary
# called "mc" is only accepted as a fallback if it identifies as MinIO's.
is_minio_mc() {
  "$1" --version 2>/dev/null | grep -q 'RELEASE\.'
}

find_mc_binary() {
  # Explicit configuration is trusted as long as it is not this wrapper.
  local explicit=()
  [[ -n "${MC_BIN:-}" ]] && explicit+=("$MC_BIN")
  [[ -r "$MC_PATH_FILE" ]] && explicit+=("$(head -n1 "$MC_PATH_FILE")")

  local c
  for c in ${explicit[@]+"${explicit[@]}"}; do
    [[ -n "$c" && -x "$c" ]] || continue
    is_self "$c" && continue
    printf '%s' "$c"
    return 0
  done

  # Some distributions ship the MinIO client as "mcli".
  for c in \
    "$HOME/.local/libexec/mc" \
    "/usr/local/libexec/mc" \
    "/opt/minio/mc" \
    "/usr/local/bin/mcli" \
    "/usr/bin/mcli" \
    "/usr/local/bin/mc" \
    "/usr/bin/mc"
  do
    [[ -x "$c" ]] || continue
    is_self "$c" && continue
    is_minio_mc "$c" || continue
    printf '%s' "$c"
    return 0
  done
  return 1
}

if [[ -n "${SEALEDMC_ACTIVE:-}" ]]; then
  die "recursion detected: the resolved mc binary is this wrapper. Set MC_BIN to the real mc."
fi

# Exported before probing candidates, so that running another copy of this
# wrapper with --version fails instead of recursing.
export SEALEDMC_ACTIVE=1

MC_REAL="$(find_mc_binary)" || die "cannot find the real MinIO client binary.
Set MC_BIN, or write its absolute path to $MC_PATH_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# mc reads aliases from MC_HOST_<alias>, so an alias name has to be a valid
# shell identifier. Names containing "-" or "." cannot be supported.
valid_alias() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

require_valid_alias() {
  valid_alias "$1" || die "alias '$1' cannot be used.
Names must match [A-Za-z_][A-Za-z0-9_]* because mc reads them as MC_HOST_<name>."
}

store_path() { printf '%s/%s.url.asc' "$STORE" "$1"; }

recipient() {
  local r=''
  if [[ -n "${SEALEDMC_GPG_RECIPIENT:-}" ]]; then
    r="$SEALEDMC_GPG_RECIPIENT"
  elif [[ -r "$RECIPIENT_FILE" ]]; then
    r="$(tr -d '[:space:]' < "$RECIPIENT_FILE")"
  fi
  [[ -n "$r" ]] || die "no GPG recipient configured.
Set SEALEDMC_GPG_RECIPIENT, or write a key id / email to $RECIPIENT_FILE"
  printf '%s' "$r"
}

# mc splits MC_HOST_<alias> with the regexes
#   ^(https?://)(.*?):(.*?):(.*)@(.*?)$   (access key, secret, session token)
#   ^(https?://)(.*?):(.*)@(.*?)$         (access key, secret)
# and does not percent-decode the captures. Keys therefore have to be stored
# verbatim, and a ":" in either key would be misparsed.
check_key() {
  local what="$1" value="$2"
  [[ -n "$value" ]] || die "$what is empty"
  [[ "$value" != *:* ]] || die "$what contains ':', which mc cannot read from MC_HOST_"
  [[ "$value" != *[[:space:]]* ]] || die "$what contains whitespace"
}

# gpg's own diagnostics are shown only when something goes wrong.
run_gpg() {
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/sealedmc.XXXXXX")"
  gpg "$@" 2>"$errf" || rc=$?
  if (( rc )) || [[ -n "${SEALEDMC_DEBUG:-}" ]]; then
    sed 's/^/sealedmc: /' "$errf" >&2
  fi
  rm -f "$errf"
  return "$rc"
}

decrypt_alias() {
  local a="$1" f
  f="$(store_path "$a")"
  [[ -r "$f" ]] || die "no stored credentials for alias '$a'"
  run_gpg --quiet --batch --decrypt "$f" \
    || die "GPG decryption failed for alias '$a'"
}

encrypt_to_store() {
  local name="$1" full="$2" rcpt="$3" target tmp
  target="$(store_path "$name")"
  tmp="$target.tmp.$$"
  (
    umask 077
    trap 'rm -f "$tmp"' EXIT
    mkdir -p "$STORE"
    printf '%s' "$full" \
      | run_gpg --quiet --batch --yes --armor --encrypt \
            --recipient "$rcpt" --output "$tmp" \
      && mv -f "$tmp" "$target"
  ) || die "GPG encryption failed for alias '$name'"
}

# Prompt on the controlling terminal rather than stdin, so that piping into
# mc (e.g. "cat file | mc pipe ...") does not consume the prompt input.
prompt_tty() {
  local varname="$1" text="$2" silent="${3:-}" value
  { : < /dev/tty; } 2>/dev/null || die "no terminal available to read '$text'"
  if [[ "$silent" == "silent" ]]; then
    read -rs -p "$text" value < /dev/tty; echo > /dev/tty
  else
    read -r -p "$text" value < /dev/tty
  fi
  printf -v "$varname" '%s' "$value"
}

# ---------------------------------------------------------------------------
# alias subcommand: handled entirely here, never forwarded to mc
# ---------------------------------------------------------------------------

cmd_alias_set() {
  local name="$1" url="$2" ak="${3:-}" sk="${4:-}"

  require_valid_alias "$name"
  [[ "$url" =~ ^https?://[^/@]+/?$ ]] \
    || die "url must be a bare endpoint like https://minio.example.com (no path, no credentials)"

  # Fail before asking for secrets if they could not be stored anyway.
  local rcpt
  rcpt="$(recipient)"

  [[ -n "$ak" ]] || prompt_tty ak 'Access key: '
  [[ -n "$sk" ]] || prompt_tty sk 'Secret key: ' silent
  check_key "access key" "$ak"
  check_key "secret key" "$sk"

  local scheme host full
  scheme="${url%%://*}"
  host="${url#*://}"
  host="${host%%/*}"
  full="$scheme://$ak:$sk@$host"

  if [[ -z "${SEALEDMC_NO_VERIFY:-}" ]]; then
    if MC_HOST_sealedmcprobe="$full" "$MC_REAL" ls sealedmcprobe/ >/dev/null 2>&1; then
      printf 'Verified connection to %s://%s\n' "$scheme" "$host"
    else
      warn "warning: could not list buckets with these credentials (storing anyway)"
    fi
  fi

  encrypt_to_store "$name" "$full" "$rcpt"
  printf 'Stored alias %s -> %s://%s (encrypted)\n' "$name" "$scheme" "$host"
}

cmd_alias_remove() {
  require_valid_alias "$1"
  local f; f="$(store_path "$1")"
  [[ -e "$f" ]] || die "no stored credentials for alias '$1'"
  rm -f -- "$f"
  printf 'Removed alias %s\n' "$1"
}

cmd_alias_list() {
  shopt -s nullglob
  local f n url found=0
  for f in "$STORE"/*.url.asc; do
    found=1
    n="${f##*/}"; n="${n%.url.asc}"
    if [[ -n "${SEALEDMC_LIST_ENDPOINTS:-}" ]]; then
      url="$(decrypt_alias "$n")"
      printf '%-20s %s://%s\n' "$n" "${url%%://*}" "${url##*@}"
    else
      printf '%s\n' "$n"
    fi
  done
  (( found )) || printf 'No aliases stored in %s\n' "$STORE"
}

if [[ "${1:-}" == "alias" ]]; then
  sub="${2:-}"
  shift 2 2>/dev/null || shift $# 
  case "$sub" in
    set)
      [[ $# -ge 2 ]] || die "usage: mc alias set NAME URL [ACCESSKEY [SECRETKEY]]"
      for arg in "$@"; do
        case "$arg" in
          --api*|--path*)
            die "--api and --path are not supported: MC_HOST_ carries only a URL" ;;
        esac
      done
      cmd_alias_set "$@" ;;
    remove|rm)
      [[ $# -ge 1 ]] || die "usage: mc alias remove NAME"
      cmd_alias_remove "$1" ;;
    list|ls)
      cmd_alias_list ;;
    *)
      die "unsupported: 'mc alias ${sub:-}'. sealedmc handles set, remove and list." ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "--sealedmc-version" ]]; then
  printf 'sealedmc %s (wrapping %s)\n' "$VERSION" "$MC_REAL"
  exit 0
fi

# ---------------------------------------------------------------------------
# Any other command: export credentials for every alias it references
# ---------------------------------------------------------------------------
after_dd=0
for arg in "$@"; do
  if (( ! after_dd )); then
    case "$arg" in
      --) after_dd=1; continue ;;
      -*) continue ;;
    esac
  fi
  candidate="${arg%%/*}"
  valid_alias "$candidate" || continue
  [[ -r "$(store_path "$candidate")" ]] || continue
  var="MC_HOST_$candidate"
  [[ -n "${!var:-}" ]] && continue
  # Assigned separately: "export x=$(...)" would hide a decryption failure.
  value="$(decrypt_alias "$candidate")"
  export "$var=$value"
done

exec "$MC_REAL" "$@"
