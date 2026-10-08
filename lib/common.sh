# shellcheck shell=bash
# Shared helpers for the s3seal entry points (mc, aws, s3seal).
# Sourced, never executed. Nothing in here prints secret values.

CONFIG_DIR="${S3SEAL_CONFIG_DIR:-$HOME/.config/s3seal}"

die()  { printf 's3seal: %s\n' "$*" >&2; exit 1; }
warn() { printf 's3seal: %s\n' "$*" >&2; }

# Follow symlinks, so that ~/.local/bin/aws finds lib/ next to its installed copy.
resolve_path() {
  local s="$1" t
  while [[ -L "$s" ]]; do
    t="$(readlink "$s")"
    [[ "$t" == /* ]] && s="$t" || s="$(dirname "$s")/$t"
  done
  printf '%s/%s' "$(cd "$(dirname "$s")" && pwd)" "$(basename "$s")"
}

# Profile names: no slashes, no leading dash or dot.
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; }

have_tty() { { : < /dev/tty; } 2>/dev/null; }

# Prompt on the controlling terminal, so piped stdin is not consumed.
prompt_tty() {
  local varname="$1" text="$2" silent="${3:-}" value
  have_tty || die "no terminal available to read '$text'"
  if [[ "$silent" == silent ]]; then
    read -rs -p "$text" value < /dev/tty; echo > /dev/tty
  else
    read -r -p "$text" value < /dev/tty
  fi
  printf -v "$varname" '%s' "$value"
}

# gpg diagnostics are shown only on failure, or always with S3SEAL_DEBUG.
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

# Sets RCPT to the GPG recipient, or dies. Not run in a subshell, so die exits.
load_recipient() {
  RCPT=''
  if [[ -n "${S3SEAL_GPG_RECIPIENT:-}" ]]; then
    RCPT="$S3SEAL_GPG_RECIPIENT"
  elif [[ -r "$CONFIG_DIR/recipient" ]]; then
    RCPT="$(tr -d '[:space:]' < "$CONFIG_DIR/recipient")"
  fi
  [[ -n "$RCPT" ]] || die "no GPG recipient configured.
Set S3SEAL_GPG_RECIPIENT, or write a key id / email to $CONFIG_DIR/recipient"
}

# Encrypt stdin to FILE (armored, mode 0600). Written through a temp file that
# is renamed into place, so a failure never leaves a partial file behind.
encrypt_private() {
  local target="$1" tmp
  load_recipient
  mkdir -p "$(dirname "$target")"
  tmp="$target.tmp.$$"
  (
    umask 077
    trap 'rm -f "$tmp"' EXIT
    run_gpg --quiet --batch --yes --armor --encrypt --recipient "$RCPT" --output "$tmp" \
      && mv -f "$tmp" "$target"
  )
}

# Names of the s3seal entry points, resolved from S3SEAL_HOME.
is_s3seal_entry() {
  local r
  r="$(resolve_path "$1")"
  [[ "$r" == "$S3SEAL_HOME/mc" || "$r" == "$S3SEAL_HOME/aws" || "$r" == "$S3SEAL_HOME/s3seal" ]]
}

# Print the first executable NAME on PATH that is not a s3seal entry point.
find_real() {
  local name="$1" d c IFS=:
  for d in $PATH; do
    [[ -n "$d" ]] || continue
    c="$d/$name"
    [[ -f "$c" && -x "$c" ]] || continue
    is_s3seal_entry "$c" && continue
    printf '%s' "$c"
    return 0
  done
  return 1
}
