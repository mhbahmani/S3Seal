# shellcheck shell=bash
# AWS CLI support.
#
# A sealed profile keeps its keys in $CONFIG_DIR/aws/PROFILE.secret.asc. Its
# section in ~/.aws/config gets a credential_process line that calls
# "s3seal credential-process", and its keys are removed from
# ~/.aws/credentials. Needs lib/common.sh and lib/ini.sh.

AWS_CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
AWS_CREDS="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
AWS_STORE="$CONFIG_DIR/aws"
AWS_SECRET_KEYS=(aws_access_key_id aws_secret_access_key aws_session_token)

# Keys of the profile most recently loaded by aws_load_stored or aws_load_current.
CRED_AK='' CRED_SK='' CRED_TOK=''

secret_file()    { printf '%s/%s.secret.asc' "$AWS_STORE" "$1"; }
is_sealed()      { [[ -r "$(secret_file "$1")" ]]; }
config_section() { if [[ "$1" == default ]]; then printf default; else printf 'profile %s' "$1"; fi; }
is_secret_key()  {
  case "$1" in
    aws_access_key_id|aws_secret_access_key|aws_session_token) return 0 ;;
  esac
  return 1
}

credential_process_cmd() { printf '%s credential-process aws %s' "$S3SEAL_HOME/bin/s3seal" "$1"; }

# Store record: key=value lines. Only newlines are forbidden in values.
aws_store_put() {  # PROFILE AK SK [TOKEN]
  local profile="$1" ak="$2" sk="$3" tok="${4:-}" rec
  rec="aws_access_key_id=$ak"$'\n'"aws_secret_access_key=$sk"
  if [[ -n "$tok" ]]; then rec+=$'\n'"aws_session_token=$tok"; fi
  printf '%s\n' "$rec" | encrypt_private "$(secret_file "$profile")" \
    || die "GPG encryption failed for profile '$profile'"
}

aws_load_stored() {  # PROFILE: sets CRED_*
  local profile="$1" plain line k v
  plain="$(run_gpg --quiet --batch --decrypt "$(secret_file "$profile")")" \
    || die "GPG decryption failed for profile '$profile'"
  CRED_AK='' CRED_SK='' CRED_TOK=''
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      aws_access_key_id) CRED_AK="$v" ;;
      aws_secret_access_key) CRED_SK="$v" ;;
      aws_session_token) CRED_TOK="$v" ;;
    esac
  done <<< "$plain"
}

# Sealed keys if the profile is sealed, otherwise its plaintext keys.
aws_load_current() {
  if is_sealed "$1"; then
    aws_load_stored "$1"
    return
  fi
  CRED_AK="$(ini_get "$AWS_CREDS" "$1" aws_access_key_id)"
  CRED_SK="$(ini_get "$AWS_CREDS" "$1" aws_secret_access_key)"
  CRED_TOK="$(ini_get "$AWS_CREDS" "$1" aws_session_token)"
}

json_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }

# Output for the AWS SDK's credential_process. Nothing else may go to stdout.
aws_credential_process() {
  local profile="$1"
  valid_name "$profile" || die "invalid profile name '$profile'"
  is_sealed "$profile" || die "profile '$profile' is not sealed"
  aws_load_stored "$profile"
  [[ -n "$CRED_AK" && -n "$CRED_SK" ]] || die "stored keys for '$profile' are incomplete"
  printf '{"Version":1,"AccessKeyId":"%s","SecretAccessKey":"%s"' \
    "$(json_string "$CRED_AK")" "$(json_string "$CRED_SK")"
  if [[ -n "$CRED_TOK" ]]; then printf ',"SessionToken":"%s"' "$(json_string "$CRED_TOK")"; fi
  printf '}\n'
}

# Moves a profile's keys into the store. The store is written first and the
# plaintext removed last, so an interruption can duplicate a key but never lose one.
aws_seal() {  # PROFILE AK SK [TOKEN]
  local profile="$1" ak="$2" sk="$3" tok="${4:-}" k
  valid_name "$profile" || die "cannot seal profile '$profile': name not supported"
  [[ "$S3SEAL_HOME" != *[[:space:]]* ]] \
    || die "cannot write credential_process: $S3SEAL_HOME contains whitespace"
  aws_store_put "$profile" "$ak" "$sk" "$tok"
  ini_set "$AWS_CONFIG" "$(config_section "$profile")" credential_process "$(credential_process_cmd "$profile")"
  for k in "${AWS_SECRET_KEYS[@]}"; do ini_del "$AWS_CREDS" "$profile" "$k"; done
}

# Seal every plaintext profile in ~/.aws/credentials. Profiles with temporary
# session tokens are skipped: they expire on their own and rotate constantly.
aws_enable() {
  local profile ak sk tok profiles sealed=0 skipped=0
  load_recipient
  profiles="$(ini_sections "$AWS_CREDS")"
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    ak="$(ini_get "$AWS_CREDS" "$profile" aws_access_key_id)"
    [[ -n "$ak" ]] || continue
    if [[ -n "$(ini_get "$AWS_CONFIG" "$(config_section "$profile")" credential_process)" ]]; then
      warn "skipping '$profile': its config already sets credential_process"
      skipped=$((skipped + 1)); continue
    fi
    if ! valid_name "$profile"; then
      warn "skipping '$profile': name not supported"
      skipped=$((skipped + 1)); continue
    fi
    tok="$(ini_get "$AWS_CREDS" "$profile" aws_session_token)"
    if [[ -n "$tok" ]]; then
      warn "skipping '$profile': temporary session credentials are not sealed"
      skipped=$((skipped + 1)); continue
    fi
    sk="$(ini_get "$AWS_CREDS" "$profile" aws_secret_access_key)"
    if [[ -z "$sk" ]]; then
      warn "skipping '$profile': no secret key"
      skipped=$((skipped + 1)); continue
    fi
    aws_seal "$profile" "$ak" "$sk" ""
    printf 'Sealed AWS profile %s\n' "$profile"
    sealed=$((sealed + 1))
  done <<< "$profiles"
  printf '%d sealed, %d skipped\n' "$sealed" "$skipped"
}

# Restore every sealed profile to plaintext in ~/.aws/credentials and delete the store.
aws_disable() {
  local f profile
  for f in "$AWS_STORE"/*.secret.asc; do
    [[ -e "$f" ]] || continue
    profile="${f##*/}"; profile="${profile%.secret.asc}"
    aws_load_stored "$profile"
    ini_set "$AWS_CREDS" "$profile" aws_access_key_id "$CRED_AK"
    ini_set "$AWS_CREDS" "$profile" aws_secret_access_key "$CRED_SK"
    if [[ -n "$CRED_TOK" ]]; then ini_set "$AWS_CREDS" "$profile" aws_session_token "$CRED_TOK"; fi
    ini_del "$AWS_CONFIG" "$(config_section "$profile")" credential_process
    rm -f -- "$f"
    printf 'Unsealed AWS profile %s (keys restored in plaintext)\n' "$profile"
  done
}

# Store a single key set by "aws configure set", keeping the other keys.
aws_set_secret() {  # PROFILE KEY VALUE
  local profile="$1" key="$2" val="$3"
  aws_load_current "$profile"
  case "$key" in
    aws_access_key_id) CRED_AK="$val" ;;
    aws_secret_access_key) CRED_SK="$val" ;;
    aws_session_token) CRED_TOK="$val" ;;
  esac
  aws_seal "$profile" "$CRED_AK" "$CRED_SK" "$CRED_TOK"
}

# Replaces "aws configure" for the profile. Non-secret answers go to the real CLI.
aws_configure_interactive() {  # PROFILE REAL_AWS
  local profile="$1" real="$2" ak sk tok region output hint=''
  have_tty || die "'aws configure' needs a terminal"
  aws_load_current "$profile"
  if [[ -n "$CRED_AK" ]]; then hint=" [****${CRED_AK: -4}]"; fi
  prompt_tty ak "AWS Access Key ID${hint}: "
  if [[ -n "$CRED_SK" ]]; then hint=' [keep]'; else hint=''; fi
  prompt_tty sk "AWS Secret Access Key${hint}: " silent
  prompt_tty region 'Default region name [keep]: '
  prompt_tty output 'Default output format [keep]: '

  ak="${ak:-$CRED_AK}"; sk="${sk:-$CRED_SK}"
  tok="$CRED_TOK"
  if [[ "$ak" != "$CRED_AK" || "$sk" != "$CRED_SK" ]]; then tok=''; fi
  if [[ -n "$ak$sk" ]]; then
    aws_seal "$profile" "$ak" "$sk" "$tok"
    printf 'Stored AWS credentials for profile %s (encrypted)\n' "$profile"
  fi
  if [[ -n "$region" ]]; then "$real" configure set region "$region" --profile "$profile"; fi
  if [[ -n "$output" ]]; then "$real" configure set output "$output" --profile "$profile"; fi
}

# The aws entry point. Only the commands that write or read keys are handled;
# everything else runs the real CLI unchanged.
aws_shim() {
  local args=("$@") n=$# i=0 j profile="" real sub rest=()
  real="$(find_real aws)" || die "cannot find the AWS CLI on PATH"

  # Global options before the subcommand pass through, except --profile.
  while (( i < n )); do
    case "${args[i]}" in
      --profile) profile="${args[i+1]-}"; i=$((i + 2)) ;;
      --profile=*) profile="${args[i]#--profile=}"; i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  if (( i >= n )) || [[ "${args[i]}" != configure ]]; then
    exec "$real" "$@"
  fi

  for ((j = i + 1; j < n; j++)); do
    case "${args[j]}" in
      --profile) profile="${args[j+1]-}"; j=$((j + 1)) ;;
      --profile=*) profile="${args[j]#--profile=}" ;;
      *) rest+=("${args[j]}") ;;
    esac
  done

  profile="${profile:-${AWS_PROFILE:-default}}"
  sub="${rest[0]-}"
  case "$sub" in
    "")
      aws_configure_interactive "$profile" "$real"
      ;;
    set)
      if (( ${#rest[@]} == 3 )) && is_secret_key "${rest[1]}"; then
        aws_set_secret "$profile" "${rest[1]}" "${rest[2]}"
      else
        exec "$real" "$@"
      fi
      ;;
    get)
      if (( ${#rest[@]} == 2 )) && is_secret_key "${rest[1]}" && is_sealed "$profile"; then
        aws_load_stored "$profile"
        case "${rest[1]}" in
          aws_access_key_id) printf '%s\n' "$CRED_AK" ;;
          aws_secret_access_key) printf '%s\n' "$CRED_SK" ;;
          aws_session_token) printf '%s\n' "$CRED_TOK" ;;
        esac
      else
        exec "$real" "$@"
      fi
      ;;
    import)
      # The real CLI writes plaintext keys; seal them straight after.
      "$real" "$@" || exit $?
      aws_enable
      ;;
    *)
      exec "$real" "$@"
      ;;
  esac
}

# Used by "s3seal status": plaintext profiles with static keys.
aws_plaintext_profiles() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ -n "$(ini_get "$AWS_CREDS" "$p" aws_access_key_id)" ]] || continue
    is_sealed "$p" && continue
    printf '%s\n' "$p"
  done <<< "$(ini_sections "$AWS_CREDS")"
}

aws_sealed_profiles() {
  local f
  for f in "$AWS_STORE"/*.secret.asc; do
    [[ -e "$f" ]] || continue
    f="${f##*/}"; printf '%s\n' "${f%.secret.asc}"
  done
}
