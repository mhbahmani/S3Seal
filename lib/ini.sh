# shellcheck shell=bash
# Minimal INI editing for ~/.aws/config and ~/.aws/credentials. Only the named
# section and key change; comments and other sections are copied unchanged.
# Arguments reach awk through ENVIRON, so backslashes in values survive.

# shellcheck disable=SC2016  # awk program: its $ and ENVIRON are not for the shell
_INI_AWK='
function header(l,  n) { n = l; sub(/^[ \t]*\[/, "", n); sub(/\][ \t]*$/, "", n); return n }
function out(s) { if (mode != "get") print s }
BEGIN {
  mode = ENVIRON["INI_MODE"]; sec = ENVIRON["INI_SEC"]
  key = ENVIRON["INI_KEY"];   val = ENVIRON["INI_VAL"]
}
/^[ \t]*\[/ {
  if (mode == "set" && cur == sec && !done) { out(key " = " val); done = 1 }
  cur = header($0)
  if (cur == sec) seen = 1
  out($0); next
}
cur == sec && $0 ~ ("^[ \t]*" key "[ \t]*=") {
  if (mode == "get") { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }
  if (mode == "set" && !done) { out(key " = " val); done = 1 }
  next
}
{ out($0) }
END {
  if (mode == "set" && !done) {
    if (!seen) out("[" sec "]")
    out(key " = " val)
  }
}
'

# ini_get FILE SECTION KEY: prints the value, nothing if absent.
ini_get() {
  [[ -f "$1" ]] || return 0
  INI_MODE=get INI_SEC="$2" INI_KEY="$3" INI_VAL='' awk "$_INI_AWK" "$1"
}

# ini_sections FILE: prints each section name, one per line.
ini_sections() {
  [[ -f "$1" ]] || return 0
  awk '/^[ \t]*\[/ { n = $0; sub(/^[ \t]*\[/, "", n); sub(/\][ \t]*$/, "", n); print n }' "$1"
}

# ini_edit MODE FILE SECTION KEY [VALUE]. Creates the file with mode 0600 when needed.
ini_edit() {
  local mode="$1" file="$2" src tmp
  if [[ -f "$file" ]]; then
    src="$file"
  else
    [[ "$mode" == del ]] && return 0
    src=/dev/null
  fi
  mkdir -p "$(dirname "$file")"
  (
    umask 077
    tmp="$file.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    INI_MODE="$mode" INI_SEC="$3" INI_KEY="$4" INI_VAL="${5:-}" \
      awk "$_INI_AWK" "$src" > "$tmp" && mv -f "$tmp" "$file"
  ) || die "could not update $file"
}

ini_set() { ini_edit set "$@"; }        # FILE SECTION KEY VALUE
ini_del() { ini_edit del "$1" "$2" "$3"; }  # FILE SECTION KEY
