#!/usr/bin/env bash
#
# s3seal: a drop-in wrapper around the MinIO client (mc) that keeps
# credentials in per-alias GPG-encrypted files instead of plaintext in
# ~/.mc/config.json.
#
# Credentials are decrypted into the environment of a single exec'd mc
# process. They are never written to disk unencrypted, never passed in
# argv, and never stored in shell history.
#
# https://github.com/mhbahmani/s3seal

set -euo pipefail

VERSION="1.1.0"

CONFIG_DIR="${S3SEAL_CONFIG_DIR:-$HOME/.config/s3seal}"
STORE="$CONFIG_DIR/aliases"
RECIPIENT_FILE="$CONFIG_DIR/recipient"
MC_PATH_FILE="$CONFIG_DIR/mc-path"

die() { printf 's3seal: %s\n' "$*" >&2; exit 1; }
warn() { printf 's3seal: %s\n' "$*" >&2; }

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

if [[ -n "${S3SEAL_ACTIVE:-}" ]]; then
  die "recursion detected: the resolved mc binary is this wrapper. Set MC_BIN to the real mc."
fi

# Exported before probing candidates, so that running another copy of this
# wrapper with --version fails instead of recursing.
export S3SEAL_ACTIVE=1

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
  if [[ -n "${S3SEAL_GPG_RECIPIENT:-}" ]]; then
    r="$S3SEAL_GPG_RECIPIENT"
  elif [[ -r "$RECIPIENT_FILE" ]]; then
    r="$(tr -d '[:space:]' < "$RECIPIENT_FILE")"
  fi
  [[ -n "$r" ]] || die "no GPG recipient configured.
Set S3SEAL_GPG_RECIPIENT, or write a key id / email to $RECIPIENT_FILE"
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
  errf="$(mktemp "${TMPDIR:-/tmp}/s3seal.XXXXXX")"
  gpg "$@" 2>"$errf" || rc=$?
  if (( rc )) || [[ -n "${S3SEAL_DEBUG:-}" ]]; then
    sed 's/^/s3seal: /' "$errf" >&2
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

# Extract a string field from one line of mc's JSON output, undoing the JSON
# escapes Go produces (\" \\ \/ \uXXXX for ASCII, and the control escapes).
json_field() {
  local line="$1" key="$2" re raw out='' i c hex
  re="\"$key\":\"(([^\"\\\\]|\\\\.)*)\""
  [[ "$line" =~ $re ]] || return 0
  raw="${BASH_REMATCH[1]}"
  i=0
  while (( i < ${#raw} )); do
    c="${raw:i:1}"
    if [[ "$c" == "\\" ]]; then
      c="${raw:i+1:1}"
      case "$c" in
        u)
          hex="${raw:i+2:4}"
          printf -v c '%b' "\\x${hex:2:2}"
          i=$((i + 6)); out+="$c"; continue ;;
        n) c=$'\n' ;;
        t) c=$'\t' ;;
        r) c=$'\r' ;;
        b) c=$'\b' ;;
        f) c=$'\f' ;;
      esac
      out+="$c"; i=$((i + 2))
    else
      out+="$c"; i=$((i + 1))
    fi
  done
  printf '%s' "$out"
}

# Aliases mc itself still holds with a real secret key. The public "play"
# demo credentials and the placeholder entries mc writes by default are
# ignored. Prints one JSON line per alias.
plaintext_aliases() {
  local line name sk
  while IFS= read -r line; do
    [[ "$line" == *'"status":"success"'* ]] || continue
    [[ "$line" == *'"src":"env"'* ]] && continue
    name="$(json_field "$line" alias)"
    sk="$(json_field "$line" secretKey)"
    [[ -n "$sk" && "$sk" != "YOUR-SECRET-KEY-HERE" ]] || continue
    [[ "$name" == "play" && "$(json_field "$line" accessKey)" == "Q3AM3UQ867SPQQA43P2F" ]] && continue
    printf '%s\n' "$line"
  done < <("$MC_REAL" ${MC_FLAGS[@]+"${MC_FLAGS[@]}"} alias list --json 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# Global flag handling
#
# mc accepts global flags anywhere on the command line, so the subcommand is
# the first argument that is neither a flag nor a flag's value.
# ---------------------------------------------------------------------------

# Global flags that take a separate value argument.
flag_takes_value() {
  case "$1" in
    -C|--config-dir|--resolve|--limit-upload|--limit-download|--custom-header|-H) return 0 ;;
  esac
  return 1
}

# Split "$@" into MC_FLAGS (global flags, with their values) and POSITIONAL.
split_args() {
  MC_FLAGS=(); POSITIONAL=()
  local after_dd=0
  while (( $# )); do
    if (( after_dd )); then POSITIONAL+=("$1"); shift; continue; fi
    case "$1" in
      --) after_dd=1 ;;
      -*)
        MC_FLAGS+=("$1")
        if flag_takes_value "$1" && (( $# > 1 )); then
          MC_FLAGS+=("$2"); shift
        fi ;;
      *) POSITIONAL+=("$1") ;;
    esac
    shift
  done
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

  if [[ -z "${S3SEAL_NO_VERIFY:-}" ]]; then
    local probe_flags=() f
    for f in ${MC_FLAGS[@]+"${MC_FLAGS[@]}"}; do
      [[ "$f" == "--insecure" ]] && probe_flags+=("$f")
    done
    if MC_HOST_s3sealprobe="$full" "$MC_REAL" ${probe_flags[@]+"${probe_flags[@]}"} \
         ls s3sealprobe/ >/dev/null 2>&1; then
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
  local f n url found=0
  for f in "$STORE"/*.url.asc; do
    [[ -e "$f" ]] || continue
    found=1
    n="${f##*/}"; n="${n%.url.asc}"
    if [[ -n "${S3SEAL_LIST_ENDPOINTS:-}" ]]; then
      url="$(decrypt_alias "$n")"
      printf '%-20s %s://%s\n' "$n" "${url%%://*}" "${url##*@}"
    else
      printf '%s\n' "$n"
    fi
  done
  (( found )) || printf 'No aliases stored in %s\n' "$STORE"

  local leftover names=''
  leftover="$(plaintext_aliases)"
  if [[ -n "$leftover" ]]; then
    while IFS= read -r f; do
      names+=" $(json_field "$f" alias)"
    done <<< "$leftover"
    warn "warning: mc's own config still holds plaintext credentials for:$names"
    warn "run 'mc alias migrate' to encrypt them and remove the plaintext copies"
  fi
}

# Move aliases out of mc's config.json into the encrypted store. With names,
# only those aliases are migrated.
cmd_alias_migrate() {
  local rcpt line name url ak sk api path scheme host
  local migrated=0 skipped=0 wanted=" $* "
  rcpt="$(recipient)"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="$(json_field "$line" alias)"
    [[ $# -eq 0 || "$wanted" == *" $name "* ]] || continue

    url="$(json_field "$line" URL)"
    ak="$(json_field "$line" accessKey)"
    sk="$(json_field "$line" secretKey)"
    api="$(json_field "$line" api)"
    path="$(json_field "$line" path)"

    if ! valid_alias "$name"; then
      warn "skipping '$name': not a valid shell identifier (re-add it under a name like ${name//[^A-Za-z0-9_]/_})"
      skipped=$((skipped + 1)); continue
    fi
    if [[ -n "$api" && "$api" != [Ss]3[Vv]4 ]] || [[ -n "$path" && "$path" != auto ]]; then
      warn "skipping '$name': uses api=$api path=$path, which MC_HOST_ cannot express"
      skipped=$((skipped + 1)); continue
    fi
    if [[ ! "$url" =~ ^https?://[^/@]+/?$ ]]; then
      warn "skipping '$name': url '$url' has a path"
      skipped=$((skipped + 1)); continue
    fi
    if [[ "$ak" == *[:[:space:]]* || "$sk" == *[:[:space:]]* ]]; then
      warn "skipping '$name': its keys contain ':' or whitespace, which MC_HOST_ cannot carry"
      skipped=$((skipped + 1)); continue
    fi
    if [[ -e "$(store_path "$name")" ]]; then
      warn "skipping '$name': an encrypted alias with that name already exists"
      skipped=$((skipped + 1)); continue
    fi

    scheme="${url%%://*}"
    host="${url#*://}"; host="${host%%/*}"
    encrypt_to_store "$name" "$scheme://$ak:$sk@$host" "$rcpt"
    "$MC_REAL" ${MC_FLAGS[@]+"${MC_FLAGS[@]}"} alias remove "$name" >/dev/null \
      || die "stored '$name' encrypted, but could not remove it from mc's config; remove it with: $MC_REAL alias remove $name"
    printf 'Migrated alias %s -> %s://%s (plaintext copy removed)\n' "$name" "$scheme" "$host"
    migrated=$((migrated + 1))
  done < <(plaintext_aliases)

  printf '%d migrated, %d skipped\n' "$migrated" "$skipped"
  (( skipped == 0 ))
}

alias_main() {
  local sub="${1:-}"
  (( $# )) && shift
  case "$sub" in
    set|s)
      [[ $# -ge 2 && $# -le 4 ]] || die "usage: mc alias set NAME URL [ACCESSKEY [SECRETKEY]]"
      cmd_alias_set "$@" ;;
    remove|rm)
      [[ $# -eq 1 ]] || die "usage: mc alias remove NAME"
      cmd_alias_remove "$1" ;;
    list|ls)
      cmd_alias_list ;;
    migrate)
      cmd_alias_migrate "$@" ;;
    *)
      die "unsupported: 'mc alias ${sub}'. s3seal handles set, remove, list and migrate." ;;
  esac
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--s3seal-version" ]]; then
  printf 's3seal %s (wrapping %s)\n' "$VERSION" "$MC_REAL"
  exit 0
fi

# Shell completion (complete -C mc mc) runs mc with COMP_LINE set. Never
# decrypt there: a pinentry prompt on every <Tab> would be unusable.
if [[ -n "${COMP_LINE:-}" ]]; then
  exec "$MC_REAL" "$@"
fi

split_args "$@"

if [[ "${POSITIONAL[0]:-}" == "alias" ]]; then
  for f in ${MC_FLAGS[@]+"${MC_FLAGS[@]}"}; do
    case "$f" in
      --api*|--path*)
        die "--api and --path are not supported: MC_HOST_ carries only a URL" ;;
      -h|--help)
        exec "$MC_REAL" alias "${POSITIONAL[@]:1}" --help ;;
    esac
  done
  alias_main "${POSITIONAL[@]:1}"
  exit $?
fi

# "mc config host add" is the legacy spelling of "mc alias set" and would
# write plaintext credentials.
if [[ "${POSITIONAL[0]:-}" == "config" && "${POSITIONAL[1]:-}" == "host" ]]; then
  die "'mc config host' is not supported; use 'mc alias set|list|remove'"
fi

# ---------------------------------------------------------------------------
# Any other command: export credentials for every alias it references
# ---------------------------------------------------------------------------
for arg in ${POSITIONAL[@]+"${POSITIONAL[@]}"}; do
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
