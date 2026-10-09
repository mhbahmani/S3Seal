# shellcheck shell=bash
# mc support: finding the real client, moving aliases between mc's config.json
# and the encrypted store, and the helpers the mc wrapper shares. Needs common.sh.

MC_STORE="$CONFIG_DIR/aliases"
MC_PATH_FILE="$CONFIG_DIR/mc-path"
# shellcheck disable=SC2034  # read by the mc wrapper
RECIPIENT_FILE="$CONFIG_DIR/recipient"
MC_CONFIG_FILE="${MC_CONFIG_DIR:-$HOME/.mc}/config.json"

# On many Linux distributions /usr/bin/mc is Midnight Commander, so a binary
# called "mc" is only accepted if it identifies as MinIO's client.
is_minio_mc() { "$1" --version 2>/dev/null | grep -q 'RELEASE\.'; }

# Prints the real client, in this order: MC_BIN, the path recorded by the
# installer or "s3seal enable", the private locations, then PATH. Never prints an
# s3seal entry point.
mc_real_binary() {
  local c d
  for c in ${MC_BIN:-} "$(head -n1 "$MC_PATH_FILE" 2>/dev/null || true)"; do
    [[ -n "$c" && -x "$c" ]] || continue
    is_s3seal_entry "$c" && continue
    printf '%s' "$c"
    return 0
  done
  # Some distributions ship the MinIO client as "mcli".
  for c in \
    "$HOME/.local/libexec/mc" "/usr/local/libexec/mc" "/opt/minio/mc" \
    "/usr/local/bin/mcli" "/usr/bin/mcli" "/usr/local/bin/mc" "/usr/bin/mc"
  do
    [[ -x "$c" ]] || continue
    is_s3seal_entry "$c" && continue
    is_minio_mc "$c" || continue
    printf '%s' "$c"
    return 0
  done
  for d in ${PATH//:/ }; do
    for c in "$d/mc" "$d/mcli"; do
      [[ -f "$c" && -x "$c" ]] || continue
      is_s3seal_entry "$c" && continue
      is_minio_mc "$c" || continue
      printf '%s' "$c"
      return 0
    done
  done
  return 1
}

mc_store_path() { printf '%s/%s.url.asc' "$MC_STORE" "$1"; }

# The endpoint of a sealed alias (scheme and host, no keys) is kept in plaintext,
# so listing aliases needs no passphrase.
mc_host_path() { printf '%s/%s.host' "$MC_STORE" "$1"; }
mc_write_host() { printf '%s\n' "$2" > "$(mc_host_path "$1")"; }

# Value of one JSON string field on one line of mc's output, JSON escapes undone.
json_field() {
  local line="$1" key="$2" re raw out='' i c hex
  re="\"$key\":\"(([^\"\\\\]|\\\\.)*)\""
  [[ "$line" =~ $re ]] || return 0
  raw="${BASH_REMATCH[1]}"
  i=0
  while (( i < ${#raw} )); do
    c="${raw:i:1}"
    # shellcheck disable=SC1003  # a single backslash, not a quote
    if [[ "$c" == '\' ]]; then
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

# One JSON line per alias that mc holds with a real secret key and that is not
# the public "play" demo alias or mc's placeholder entries. Needs MC_REAL.
mc_plaintext_aliases() {
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

# Names of the aliases in the encrypted store.
mc_sealed_aliases() {
  local f
  for f in "$MC_STORE"/*.url.asc; do
    [[ -e "$f" ]] || continue
    f="${f##*/}"; printf '%s\n' "${f%.url.asc}"
  done
}

mc_decrypt() {  # NAME: prints "scheme://ak:sk@host"
  local out
  out="$(run_gpg --quiet --batch --decrypt "$(mc_store_path "$1")")" \
    || die "GPG decryption failed for alias '$1'"
  printf '%s' "$out"
}

# Moves every plaintext alias of mc's config into the encrypted store and
# removes the plaintext copy. Aliases mc cannot express stay where they are.
mc_seal_all() {
  local line name url ak sk api path scheme host
  local migrated=0 skipped=0
  load_recipient
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="$(json_field "$line" alias)"
    url="$(json_field "$line" URL)"
    ak="$(json_field "$line" accessKey)"
    sk="$(json_field "$line" secretKey)"
    api="$(json_field "$line" api)"
    path="$(json_field "$line" path)"

    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "skipping '$name': not a usable alias name"
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
    if [[ "$ak" == *:* || "$sk" == *:* || "$ak$sk" == *[[:space:]]* ]]; then
      warn "skipping '$name': its keys contain ':' or whitespace, which MC_HOST_ cannot carry"
      skipped=$((skipped + 1)); continue
    fi
    if [[ -e "$(mc_store_path "$name")" ]]; then
      warn "skipping '$name': an encrypted alias with that name already exists"
      skipped=$((skipped + 1)); continue
    fi

    scheme="${url%%://*}"
    host="${url#*://}"; host="${host%%/*}"
    printf '%s://%s:%s@%s' "$scheme" "$ak" "$sk" "$host" | encrypt_private "$(mc_store_path "$name")" \
      || die "GPG encryption failed for alias '$name'"
    "$MC_REAL" ${MC_FLAGS[@]+"${MC_FLAGS[@]}"} alias remove "$name" >/dev/null \
      || die "stored '$name' encrypted, but could not remove it from mc's config; remove it with: $MC_REAL alias remove $name"
    mc_write_host "$name" "$scheme://$host"
    printf 'Sealed mc alias %s\n' "$name"
    migrated=$((migrated + 1))
  done < <(mc_plaintext_aliases)
  printf '%d sealed, %d skipped\n' "$migrated" "$skipped"
  (( skipped == 0 ))
}

# Writes the sealed aliases back into mc's config.json as plaintext, then
# removes them from the store. Does not contact the servers: the aliases are
# written directly, so unreachable endpoints work too.
mc_unseal_all() {
  local f name url rest host creds ak sk rows='' names=()
  for name in $(mc_sealed_aliases); do
    url="$(mc_decrypt "$name")"
    rest="${url#*://}"
    host="${rest##*@}"
    creds="${rest%@*}"
    ak="${creds%%:*}"
    sk="${creds#*:}"
    rows+="$name"$'\t'"${url%%://*}://$host"$'\t'"$ak"$'\t'"$sk"$'\n'
    names+=("$name")
  done
  (( ${#names[@]} )) || return 0
  printf '%s' "$rows" | mc_write_config
  for name in "${names[@]}"; do
    rm -f -- "$(mc_store_path "$name")"
    printf 'Unsealed mc alias %s (plaintext in %s)\n' "$name" "$MC_CONFIG_FILE"
  done
}

# Reads "name<TAB>url<TAB>accessKey<TAB>secretKey" lines on stdin and merges them
# into config.json, keeping every other entry. Written with mode 0600.
mc_write_config() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to write mc's config.json"
  mkdir -p "$(dirname "$MC_CONFIG_FILE")"
  # The program goes in -c so that stdin stays free for the alias rows.
  python3 -c "$(cat <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = {"version": "10", "aliases": {}}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
cfg.setdefault("aliases", {})
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    name, url, ak, sk = line.split("\t")
    cfg["aliases"][name] = {"url": url, "accessKey": ak, "secretKey": sk, "api": "S3v4", "path": "auto"}
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
)" "$MC_CONFIG_FILE"
}
