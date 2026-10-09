#!/usr/bin/env bash
#
# Test suite for s3seal. Needs only bash and gpg; python3 is used for the
# interactive prompt tests when available.
#
#   tests/run.sh                        run everything
#   tests/run.sh migrate                run tests whose name contains "migrate"
#   TEST_BASH=/bin/bash tests/run.sh    run the scripts under another bash
#
# Each test gets a throwaway HOME, GNUPGHOME, AWS config files, and fake mc
# and aws binaries that record their arguments and environment.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/libexec/mc"
TEST_BASH="${TEST_BASH:-bash}"
FILTER="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/s3seal-test.XXXXXX")"
trap 'gpgconf --homedir "$WORK/gnupg" --kill all >/dev/null 2>&1; rm -rf "$WORK"' EXIT

PASS=0 FAIL=0 FAILED=()

# gpg lives outside /usr/bin on macOS (Homebrew), so tests add its directory to PATH.
GPG_DIR="$(dirname "$(command -v gpg)")"

# Portable in-place edit: BSD sed (macOS) and GNU sed take -i differently.
set_version() {  # FILE VERSION
  sed "s/^VERSION=.*/VERSION=\"$2\"/" "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
# Tests must never open a passphrase window: pinentry is replaced by a program
# that fails at once, so a passphrase request becomes an ordinary error.
printf 'allow-loopback-pinentry\npinentry-program /bin/false\n' > "$GNUPGHOME/gpg-agent.conf"
gpgconf --homedir "$GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
gpg --batch --quiet --passphrase '' --quick-gen-key 's3seal test <test@s3seal.invalid>' \
  default default never >/dev/null 2>&1 || { echo "cannot create a GPG test key" >&2; exit 1; }

# --- fake clients -----------------------------------------------------------
FAKE_MC="$WORK/fake-mc"
cat > "$FAKE_MC" <<'EOF2'
#!/usr/bin/env bash
{
  printf 'ARGS:'; printf ' [%s]' "$@"; printf '\n'
  env | grep '^MC_HOST_' | sort | sed 's/^/ENV: /'
} >> "${FAKE_MC_LOG:-/dev/null}"
args=" $* "
case "$args" in
  *" --version "*) echo "mc version RELEASE.2024-01-01T00-00-00Z"; exit 0 ;;
  *" alias list --json "*) cat "${FAKE_MC_CONFIG:-/dev/null}" 2>/dev/null; exit 0 ;;
  *" alias remove "*)
    name="${@: -1}"
    grep -v "\"alias\":\"$name\"" "$FAKE_MC_CONFIG" > "$FAKE_MC_CONFIG.new"
    mv "$FAKE_MC_CONFIG.new" "$FAKE_MC_CONFIG"; exit 0 ;;
  *" ls s3sealprobe/ "*) exit "${FAKE_MC_LS_RC:-0}" ;;
esac
exit 0
EOF2
chmod +x "$FAKE_MC"

FAKE_AWS="$WORK/fake-aws"
cat > "$FAKE_AWS" <<'EOF2'
#!/usr/bin/env bash
{ printf 'AWS:'; printf ' [%s]' "$@"; printf '\n'; } >> "${FAKE_AWS_LOG:-/dev/null}"
case " $* " in
  *" configure import "*)
    printf '\n[imported]\naws_access_key_id = AKIMPORT\naws_secret_access_key = SKIMPORT\n' \
      >> "$AWS_SHARED_CREDENTIALS_FILE" ;;
esac
exit 0
EOF2
chmod +x "$FAKE_AWS"

MIDNIGHT="$WORK/midnight-mc"
printf '#!/bin/sh\necho "GNU Midnight Commander 4.8.30"\n' > "$MIDNIGHT"
chmod +x "$MIDNIGHT"

# --- harness ----------------------------------------------------------------
setup() {
  T="$WORK/t.$1"
  mkdir -p "$T/home"
  export HOME="$T/home"
  export S3SEAL_CONFIG_DIR="$HOME/.config/s3seal"
  export S3SEAL_GPG_RECIPIENT="test@s3seal.invalid"
  export S3SEAL_NO_VERIFY=1
  export MC_BIN="$FAKE_MC"
  export FAKE_MC_LOG="$T/mc.log"
  export FAKE_MC_CONFIG="$T/config.jsonl"
  : > "$FAKE_MC_LOG"; : > "$FAKE_MC_CONFIG"
  unset S3SEAL_LIST_ENDPOINTS S3SEAL_ACTIVE COMP_LINE FAKE_MC_LS_RC
  unset AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  for v in $(env | sed -n 's/^\(MC_HOST_[^=]*\)=.*/\1/p'); do unset "$v"; done
}

# Run a script; output in $OUT (stdout and stderr), exit code in $RC.
run_entry() {
  local entry="$1"; shift
  local nosid=()
  command -v setsid >/dev/null 2>&1 && nosid=(setsid)
  OUT="$(${nosid[@]+"${nosid[@]}"} "$TEST_BASH" "$entry" "$@" < /dev/null 2>&1)" && RC=0 || RC=$?
}
run_mc() { run_entry "$WRAPPER" "$@"; }

# Like run_entry, but $OUT is stdout only.
run_out() {
  local entry="$1"; shift
  OUT="$("$TEST_BASH" "$entry" "$@" 2>"$T/stderr" < /dev/null)" && RC=0 || RC=$?
}

fail() { printf '    %s\n' "$*"; return 1; }
assert_rc()      { [[ "$RC" == "$1" ]] || fail "expected exit $1, got $RC; output: $OUT"; }
assert_out()     { [[ "$OUT" == *"$1"* ]] || fail "output lacks '$1': $OUT"; }
assert_not_out() { [[ "$OUT" != *"$1"* ]] || fail "output unexpectedly has '$1': $OUT"; }
assert_log()     { grep -qF -- "$1" "$FAKE_MC_LOG" || fail "mc log lacks '$1': $(cat "$FAKE_MC_LOG")"; }
assert_not_log() { ! grep -qF -- "$1" "$FAKE_MC_LOG" || fail "mc log unexpectedly has '$1'"; }
assert_file()    { [[ -e "$1" ]] || fail "missing file $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "unexpected file $1"; }
assert_aws_log() { grep -qF -- "$1" "$FAKE_AWS_LOG" || fail "aws log lacks '$1': $(cat "$FAKE_AWS_LOG")"; }
assert_not_in()  { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 unexpectedly contains '$2'"; }
assert_in()      { grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 lacks '$2'"; }

stored() { gpg --quiet --batch --decrypt "$S3SEAL_CONFIG_DIR/aliases/$1.url.asc" 2>/dev/null; }
store() { run_mc alias set "$1" "$2" "$3" "$4"; [[ "$RC" == 0 ]] || fail "store $1 failed: $OUT"; }

# AWS environment: fake aws on PATH, config files under $T/aws.
aws_env() {
  mkdir -p "$T/bin" "$T/aws"
  cp "$FAKE_AWS" "$T/bin/aws"
  export PATH="$T/bin:$GPG_DIR:/usr/bin:/bin"
  export AWS_CONFIG_FILE="$T/aws/config"
  export AWS_SHARED_CREDENTIALS_FILE="$T/aws/credentials"
  export FAKE_AWS_LOG="$T/aws.log"
  : > "$FAKE_AWS_LOG"
  export S3SEAL_INSTALL_DIR="$HOME/.local/share/s3seal/bin"
}

seed_credentials() {
  cat > "$AWS_SHARED_CREDENTIALS_FILE" <<'CREDS'
# keep this comment
[prod]
aws_access_key_id = AKPROD1
aws_secret_access_key = SKPROD/1+x

[temp]
aws_access_key_id = ASIATEMP
aws_secret_access_key = SKTEMP
aws_session_token = TOKTEMP

[other]
aws_access_key_id = AKOTHER
aws_secret_access_key = SKOTHER
CREDS
}

run_test() {
  local name="$1"
  [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
  local rc
  ( setup "$name"; set -e; "test_$name" ); rc=$?
  if (( rc == 0 )); then
    PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$name"); printf 'FAIL %s\n' "$name"
  fi
}

# --- mc: storing and using aliases ------------------------------------------
test_set_stores_encrypted_and_exports() {
  store prod https://minio.example.com AKIA0001 'secret/with+special@chars'
  assert_out "Stored alias prod -> https://minio.example.com (encrypted)"
  local f="$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  assert_file "$f"
  [[ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" == 600 ]] || fail "store file is not 0600"
  ! grep -q 'secret' "$f" || fail "secret appears in the store file"
  run_mc ls prod/bucket
  assert_rc 0
  assert_log "ENV: MC_HOST_prod=https://AKIA0001:secret/with+special@chars@minio.example.com"
  assert_log "ARGS: [ls] [prod/bucket]"
}

test_set_rejects_colon_in_keys() {
  run_mc alias set prod https://minio.example.com 'AK:1' SECRET123
  assert_rc 1; assert_out "access key contains ':'"
  run_mc alias set prod https://minio.example.com AK1 'SE:CRET'
  assert_rc 1; assert_out "secret key contains ':'"
}

test_set_rejects_bad_names_and_urls() {
  run_mc alias set -prod https://minio.example.com AK SECRET123
  assert_rc 1; assert_out "cannot be used"
  run_mc alias set my-minio https://minio.example.com AK SECRET123
  assert_rc 0; assert_out "Stored alias my-minio"
  run_mc alias set prod https://minio.example.com/path AK SECRET123
  assert_rc 1; assert_out "bare endpoint"
  run_mc alias set prod https://user:pw@minio.example.com AK SECRET123
  assert_rc 1; assert_out "bare endpoint"
}

test_set_checks_recipient_before_prompting() {
  unset S3SEAL_GPG_RECIPIENT
  run_mc alias set prod https://minio.example.com
  assert_rc 1; assert_out "no GPG recipient configured"; assert_not_out "terminal"
}

test_set_without_terminal_fails_cleanly() {
  command -v setsid >/dev/null 2>&1 || return 0
  run_mc alias set prod https://minio.example.com
  assert_rc 1; assert_out "no terminal available"
}

test_set_prompts_on_terminal() {
  command -v python3 >/dev/null 2>&1 || return 0
  OUT="$(printf 'Access key\tAKPROMPT\nSecret key\tSKPROMPT/+x\n' \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$WRAPPER" alias set prod https://minio.example.com)"
  assert_out "Stored alias prod"
  assert_not_out "SKPROMPT"
  [[ "$(stored prod)" == "https://AKPROMPT:SKPROMPT/+x@minio.example.com" ]] || fail "stored: $(stored prod)"
}

test_set_verifies_connection() {
  unset S3SEAL_NO_VERIFY
  store prod https://minio.example.com AK1 SECRET123
  assert_out "Verified connection"
  assert_log "ENV: MC_HOST_s3sealprobe=https://AK1:SECRET123@minio.example.com"
  export FAKE_MC_LS_RC=1
  store dev https://minio.example.com AK1 SECRET123
  assert_out "could not list buckets"
  assert_file "$S3SEAL_CONFIG_DIR/aliases/dev.url.asc"
}

test_global_flag_before_alias_is_intercepted() {
  unset S3SEAL_NO_VERIFY
  run_mc --insecure alias set prod https://minio.example.com AK1 SECRET123
  assert_rc 0
  assert_out "Stored alias prod"
  assert_not_log "[alias] [set]"
  assert_log "ARGS: [--insecure] [ls] [s3sealprobe/]"
  run_mc --config-dir /tmp/x alias list
  assert_rc 0; assert_out "prod"
  assert_log "ARGS: [--config-dir] [/tmp/x] [alias] [list] [--json]"
  ! grep -q '\[list\]$' "$FAKE_MC_LOG" || fail "alias list was forwarded to mc"
}

test_legacy_config_host_is_blocked() {
  run_mc config host add prod https://minio.example.com AK1 SECRET123
  assert_rc 1; assert_out "'mc config host' is not supported"
  assert_not_log "[config]"
}

test_api_and_path_flags_rejected() {
  run_mc alias set prod https://minio.example.com AK1 SECRET123 --api S3v2
  assert_rc 1; assert_out "--api and --path are not supported"
  run_mc alias set --path=on prod https://minio.example.com AK1 SECRET123
  assert_rc 1; assert_out "--api and --path are not supported"
}

test_unsupported_alias_subcommands() {
  run_mc alias import prod cfg.json
  assert_rc 1; assert_out "unsupported: 'mc alias import'"
}

test_aliases_after_double_dash_are_exported() {
  store prod https://minio.example.com AK1 SECRET123
  run_mc rm -- prod/bucket/obj
  assert_rc 0
  assert_log "ENV: MC_HOST_prod=https://AK1:SECRET123@minio.example.com"
  assert_log "ARGS: [rm] [--] [prod/bucket/obj]"
}

test_multiple_aliases_and_flags() {
  store prod https://prod.example.com AK1 SECRET123
  store dev https://dev.example.com AK2 SECRET456
  run_mc --json cp --recursive prod/a dev/b
  assert_rc 0
  assert_log "ENV: MC_HOST_dev=https://AK2:SECRET456@dev.example.com"
  assert_log "ENV: MC_HOST_prod=https://AK1:SECRET123@prod.example.com"
}

test_unreferenced_aliases_stay_encrypted() {
  store prod https://prod.example.com AK1 SECRET123
  store dev https://dev.example.com AK2 SECRET456
  run_mc ls prod/
  assert_log "MC_HOST_prod"
  assert_not_log "MC_HOST_dev"
}

test_decryption_failure_aborts() {
  store prod https://minio.example.com AK1 SECRET123
  echo garbage > "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  run_mc ls prod/
  assert_rc 1
  assert_out "GPG decryption failed for alias 'prod'"
  assert_not_log "ARGS: [ls]"
}

test_existing_env_alias_wins() {
  store prod https://minio.example.com AK1 SECRET123
  echo garbage > "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  export MC_HOST_prod="https://ENVKEY:ENVSECRET@other.example.com"
  run_mc ls prod/
  assert_rc 0
  assert_log "ENV: MC_HOST_prod=https://ENVKEY:ENVSECRET@other.example.com"
}

test_completion_never_decrypts() {
  store prod https://minio.example.com AK1 SECRET123
  echo garbage > "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  export COMP_LINE="mc ls prod/"
  run_mc mc prod/ ls
  assert_rc 0
  assert_not_log "MC_HOST_prod"
}

test_list_and_endpoints() {
  run_mc alias list
  assert_out "No aliases stored"
  store prod https://minio.example.com AK1 SECRET123
  run_mc alias ls
  assert_rc 0; assert_out "prod"; assert_not_out "minio.example.com"
  export S3SEAL_LIST_ENDPOINTS=1
  run_mc alias list
  assert_out "https://minio.example.com"; assert_not_out "SECRET123"
}

test_list_warns_about_plaintext() {
  cat > "$FAKE_MC_CONFIG" <<'JSON'
{"status":"success","alias":"play","URL":"https://play.min.io","accessKey":"Q3AM3UQ867SPQQA43P2F","secretKey":"zuf+tfteSlswRu7BJ86wekitnifILbZam1KYY3TG","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"s3","URL":"https://s3.amazonaws.com","accessKey":"YOUR-ACCESS-KEY-HERE","secretKey":"YOUR-SECRET-KEY-HERE","api":"S3v4","path":"dns","src":"/x/config.json"}
{"status":"success","alias":"local","URL":"http://localhost:9000","path":"auto","src":"/x/config.json"}
JSON
  run_mc alias list
  assert_not_out "plaintext credentials"
  echo '{"status":"success","alias":"prod","URL":"https://minio.example.com","accessKey":"AK1","secretKey":"SECRET123","api":"S3v4","path":"auto","src":"/x/config.json"}' >> "$FAKE_MC_CONFIG"
  run_mc alias list
  assert_out "plaintext credentials for: prod"
  assert_out "s3seal migrate mc"
}

test_remove() {
  store prod https://minio.example.com AK1 SECRET123
  run_mc alias rm prod
  assert_rc 0; assert_out "Removed alias prod"
  assert_no_file "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  run_mc alias remove prod
  assert_rc 1; assert_out "no stored credentials"
}

test_remove_rejects_path_traversal() {
  mkdir -p "$S3SEAL_CONFIG_DIR/aliases"
  touch "$S3SEAL_CONFIG_DIR/victim.url.asc"
  run_mc alias remove ../victim
  assert_rc 1
  assert_file "$S3SEAL_CONFIG_DIR/victim.url.asc"
}

test_migrate() {
  cat > "$FAKE_MC_CONFIG" <<'JSON'
{"status":"success","alias":"play","URL":"https://play.min.io","accessKey":"Q3AM3UQ867SPQQA43P2F","secretKey":"zuf+tfteSlswRu7BJ86wekitnifILbZam1KYY3TG","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"prod","URL":"https://minio.example.com","accessKey":"AK1","secretKey":"a&b/c+d\"e\\f","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"my-minio","URL":"https://m.example.com","accessKey":"AK2","secretKey":"SECRET456","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"legacy","URL":"https://l.example.com","accessKey":"AK3","secretKey":"SECRET789","api":"S3v2","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"envy","URL":"https://e.example.com","accessKey":"AK4","secretKey":"SECRET000","api":"S3v4","src":"env"}
JSON
  run_entry "$ROOT/libexec/s3seal" migrate mc
  assert_rc 1
  assert_out "Sealed mc alias prod"
  assert_out "Sealed mc alias my-minio"
  assert_out "skipping 'legacy'"
  assert_out "2 sealed, 1 skipped"
  assert_not_out "envy"
  [[ "$(stored prod)" == 'https://AK1:a&b/c+d"e\f@minio.example.com' ]] || fail "stored: $(stored prod)"
  assert_log "ARGS: [alias] [remove] [prod]"
  ! grep -q '"alias":"prod"' "$FAKE_MC_CONFIG" || fail "prod still in plaintext config"
  grep -q '"alias":"play"' "$FAKE_MC_CONFIG" || fail "play was touched"
}

test_migrate_does_not_overwrite() {
  store prod https://minio.example.com AK1 SECRET123
  echo '{"status":"success","alias":"prod","URL":"https://other.example.com","accessKey":"AKX","secretKey":"SECRETX1","api":"S3v4","path":"auto","src":"/x/config.json"}' > "$FAKE_MC_CONFIG"
  run_entry "$ROOT/libexec/s3seal" migrate mc
  assert_rc 1; assert_out "already exists"
  [[ "$(stored prod)" == "https://AK1:SECRET123@minio.example.com" ]] || fail "existing alias overwritten"
}

test_encrypt_failure_leaves_no_temp_files() {
  export S3SEAL_GPG_RECIPIENT="nobody@nowhere.invalid"
  run_mc alias set prod https://minio.example.com AK1 SECRET123
  assert_rc 1
  assert_out "GPG encryption failed"
  assert_out "s3seal: gpg: "
  local left; left="$(find "$S3SEAL_CONFIG_DIR" -name '*.tmp.*' 2>/dev/null)"
  [[ -z "$left" ]] || fail "temp files left: $left"
}

test_recursion_guard() {
  export S3SEAL_ACTIVE=1
  run_mc ls
  assert_rc 1; assert_out "recursion detected"
}

test_mc_path_file_and_self_skipping() {
  unset MC_BIN
  mkdir -p "$S3SEAL_CONFIG_DIR"
  printf '%s\n' "$FAKE_MC" > "$S3SEAL_CONFIG_DIR/mc-path"
  run_mc --s3seal-version
  assert_rc 0; assert_out "wrapping $FAKE_MC"
  export MC_BIN="$WRAPPER"
  run_mc --s3seal-version
  assert_rc 0; assert_out "wrapping $FAKE_MC"
}

test_midnight_commander_is_not_used() {
  unset MC_BIN
  mkdir -p "$HOME/.local/libexec"
  cp "$MIDNIGHT" "$HOME/.local/libexec/mc"
  run_mc --s3seal-version
  assert_not_out "$HOME/.local/libexec/mc"
  cp "$FAKE_MC" "$HOME/.local/libexec/mc"
  run_mc --s3seal-version
  assert_rc 0; assert_out "wrapping $HOME/.local/libexec/mc"
}

# --- mc: enable, disable and migrate ----------------------------------------
mc_plaintext_config() {
  cat > "$FAKE_MC_CONFIG" <<'JSON'
{"status":"success","alias":"prod","URL":"https://minio.example.com","accessKey":"AK1","secretKey":"SECRET123","api":"S3v4","path":"auto","src":"/x/config.json"}
JSON
}

test_mc_enable_seals_with_yes() {
  mc_plaintext_config
  export S3SEAL_INSTALL_DIR="$HOME/.local/share/s3seal/bin"
  run_out "$ROOT/libexec/s3seal" enable mc --yes
  assert_rc 0
  assert_out "Sealed mc alias prod"
  assert_out "mc is sealed."
  assert_file "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  [[ "$(readlink "$HOME/.local/share/s3seal/bin/mc")" == "$ROOT/libexec/mc" ]] || fail "mc not linked"
  ! grep -q '"alias":"prod"' "$FAKE_MC_CONFIG" || fail "plaintext alias still in mc config"
}

test_mc_enable_without_terminal_points_at_migrate() {
  mc_plaintext_config
  export S3SEAL_INSTALL_DIR="$HOME/.local/share/s3seal/bin"
  run_entry "$ROOT/libexec/s3seal" enable mc
  assert_rc 0
  assert_out "Left 1 credential(s) in plaintext"
  assert_out "s3seal migrate mc"
  assert_out "mc alias set NAME URL"
  assert_no_file "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
}

test_mc_disable_writes_back_without_contacting_servers() {
  mc_plaintext_config
  export S3SEAL_INSTALL_DIR="$HOME/.local/share/s3seal/bin" MC_CONFIG_DIR="$T/mccfg"
  run_out "$ROOT/libexec/s3seal" enable mc --yes
  assert_rc 0
  export FAKE_MC_LS_RC=1
  run_out "$ROOT/libexec/s3seal" disable mc --yes
  assert_rc 0
  assert_out "Unsealed mc alias prod"
  assert_no_file "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  assert_in "$T/mccfg/config.json" '"accessKey": "AK1"'
  assert_in "$T/mccfg/config.json" '"url": "https://minio.example.com"'
  assert_in "$T/mccfg/config.json" '"secretKey": "SECRET123"'
  [[ "$(stat -c %a "$T/mccfg/config.json" 2>/dev/null || stat -f %Lp "$T/mccfg/config.json")" == 600 ]] \
    || fail "mc config is not 0600"
  assert_no_file "$HOME/.local/share/s3seal/bin/mc"
}

test_enable_replaces_old_plain_copy_in_bin() {
  aws_env; seed_credentials
  mkdir -p "$S3SEAL_INSTALL_DIR"
  printf '#!/bin/sh\n# s3seal: old copy\n' > "$S3SEAL_INSTALL_DIR/aws"
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  assert_rc 0
  [[ -L "$S3SEAL_INSTALL_DIR/aws" ]] || fail "old copy was not replaced by a link"
}

test_status_lists_names_comma_separated() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" status
  assert_out "PLAINTEXT:  prod, temp, other (run: s3seal migrate aws)"
  assert_out "enabled:    no"
}

# --- INI editing -------------------------------------------------------------
test_ini_edits_touch_only_their_section() {
  (
    # shellcheck disable=SC2030,SC2031
    S3SEAL_HOME="$ROOT"; export S3SEAL_HOME
    # shellcheck source=/dev/null
    . "$ROOT/lib/common.sh"; . "$ROOT/lib/ini.sh"
    f="$T/ini"
    printf '# top\n[a]\nx = 1\n[b]\nx = 2\n' > "$f"
    ini_set "$f" b y 3
    ini_set "$f" a x 9
    ini_set "$f" c z 4
    ini_del "$f" b x
    printf '# top\n[a]\nx = 9\n[b]\ny = 3\n[c]\nz = 4\n' > "$T/expected"
    cmp -s "$f" "$T/expected" || fail "unexpected content: $(cat "$f")"
    [[ "$(ini_get "$f" a x)" == 9 ]] || fail "ini_get"
    [[ -z "$(ini_get "$f" a missing)" ]] || fail "absent key should be empty"
  )
}

test_ini_keeps_backslashes_and_mode() {
  (
    # shellcheck disable=SC2030,SC2031
    S3SEAL_HOME="$ROOT"; export S3SEAL_HOME
    # shellcheck source=/dev/null
    . "$ROOT/lib/common.sh"; . "$ROOT/lib/ini.sh"
    f="$T/new/creds"
    ini_set "$f" p aws_secret_access_key 'a\b\\c'
    [[ "$(ini_get "$f" p aws_secret_access_key)" == 'a\b\\c' ]] || fail "backslashes altered"
    [[ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" == 600 ]] || fail "new file is not 0600"
  )
}

# --- AWS: enable, credential_process, disable -------------------------------
test_aws_enable_seals_plaintext_profiles() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  assert_rc 0
  assert_out "Sealed AWS profile prod"
  assert_out "Sealed AWS profile other"
  assert_not_in "$AWS_SHARED_CREDENTIALS_FILE" AKPROD1
  assert_not_in "$AWS_SHARED_CREDENTIALS_FILE" SKPROD
  assert_in "$AWS_SHARED_CREDENTIALS_FILE" "# keep this comment"
  assert_in "$AWS_SHARED_CREDENTIALS_FILE" "TOKTEMP"
  assert_in "$AWS_CONFIG_FILE" "[profile prod]"
  assert_in "$AWS_CONFIG_FILE" "credential_process = $ROOT/libexec/s3seal credential-process aws prod"
  assert_file "$S3SEAL_CONFIG_DIR/aws/prod.secret.asc"
  assert_not_in "$S3SEAL_CONFIG_DIR/aws/prod.secret.asc" AKPROD1
  [[ "$(readlink "$HOME/.local/share/s3seal/bin/aws")" == "$ROOT/libexec/aws" ]] || fail "aws shim not linked"
}

test_aws_enable_is_repeatable() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  assert_rc 0
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  assert_rc 0
  assert_in "$AWS_CONFIG_FILE" "credential_process"
  [[ "$(grep -c 'credential_process' "$AWS_CONFIG_FILE")" == 2 ]] || fail "credential_process duplicated"
}

test_aws_credential_process_prints_json_only() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  run_out "$ROOT/libexec/s3seal" credential-process aws prod
  assert_rc 0
  [[ "$(printf '%s\n' "$OUT" | wc -l | tr -d " ")" == 1 ]] || fail "stdout is not a single line: $OUT"
  [[ "$OUT" == '{"Version":1,"AccessKeyId":"AKPROD1","SecretAccessKey":"SKPROD/1+x"}' ]] || fail "json: $OUT"
  run_out "$ROOT/libexec/s3seal" credential-process aws temp
  assert_rc 1
}

test_aws_passthrough_leaves_keys_out_of_args() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  run_out "$HOME/.local/share/s3seal/bin/aws" --profile prod s3 ls
  assert_rc 0
  assert_aws_log "AWS: [--profile] [prod] [s3] [ls]"
  ! grep -q 'SKPROD' "$FAKE_AWS_LOG" || fail "secret reached aws arguments"
}

test_aws_set_secret_seals_then_completes() {
  aws_env
  run_out "$ROOT/libexec/aws" configure set aws_access_key_id AKNEW --profile fresh
  assert_rc 0
  assert_not_in "$AWS_SHARED_CREDENTIALS_FILE" AKNEW
  assert_file "$S3SEAL_CONFIG_DIR/aws/fresh.secret.asc"
  run_out "$ROOT/libexec/s3seal" credential-process aws fresh
  assert_rc 1
  run_out "$ROOT/libexec/aws" configure set aws_secret_access_key SKNEW --profile fresh
  assert_rc 0
  run_out "$ROOT/libexec/s3seal" credential-process aws fresh
  assert_rc 0
  [[ "$OUT" == '{"Version":1,"AccessKeyId":"AKNEW","SecretAccessKey":"SKNEW"}' ]] || fail "json: $OUT"
  ! grep -q 'SKNEW' "$FAKE_AWS_LOG" || fail "secret reached the real aws"
}

test_aws_configure_get_reads_store() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  run_out "$ROOT/libexec/aws" configure get aws_secret_access_key --profile prod
  assert_rc 0
  [[ "$OUT" == "SKPROD/1+x" ]] || fail "got: $OUT"
  run_out "$ROOT/libexec/aws" configure get region --profile prod
  assert_aws_log "[configure] [get] [region] [--profile] [prod]"
}

test_aws_configure_interactive() {
  command -v python3 >/dev/null 2>&1 || return 0
  aws_env
  OUT="$(printf 'AWS Access Key ID\tAKTTY\nAWS Secret Access Key\tSKTTY/x\nDefault region name\tus-west-2\nDefault output format\t\n' \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/libexec/aws" configure --profile tty)"
  assert_out "Stored AWS credentials for profile tty"
  assert_not_out "SKTTY"
  assert_file "$S3SEAL_CONFIG_DIR/aws/tty.secret.asc"
  assert_aws_log "[configure] [set] [region] [us-west-2] [--profile] [tty]"
  run_out "$ROOT/libexec/s3seal" credential-process aws tty
  [[ "$OUT" == '{"Version":1,"AccessKeyId":"AKTTY","SecretAccessKey":"SKTTY/x"}' ]] || fail "json: $OUT"
}

test_aws_import_is_sealed() {
  aws_env
  run_out "$ROOT/libexec/aws" configure import --csv "$T/whatever.csv"
  assert_rc 0
  assert_not_in "$AWS_SHARED_CREDENTIALS_FILE" AKIMPORT
  assert_file "$S3SEAL_CONFIG_DIR/aws/imported.secret.asc"
}

test_aws_disable_restores_plaintext() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  run_out "$ROOT/libexec/s3seal" disable aws --yes
  assert_rc 0
  assert_out "Unsealed AWS profile prod"
  assert_in "$AWS_SHARED_CREDENTIALS_FILE" "aws_access_key_id = AKPROD1"
  assert_in "$AWS_SHARED_CREDENTIALS_FILE" "aws_secret_access_key = SKPROD/1+x"
  assert_not_in "$AWS_CONFIG_FILE" "credential_process"
  assert_no_file "$S3SEAL_CONFIG_DIR/aws/prod.secret.asc"
  assert_no_file "$HOME/.local/share/s3seal/bin/aws"
}

test_aws_disable_without_terminal_keeps_sealed() {
  command -v setsid >/dev/null 2>&1 || return 0
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  OUT="$(setsid "$TEST_BASH" "$ROOT/libexec/s3seal" disable aws < /dev/null 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "Left 2 credential(s) sealed"
  assert_file "$S3SEAL_CONFIG_DIR/aws/prod.secret.asc"
  assert_not_in "$AWS_SHARED_CREDENTIALS_FILE" AKPROD1
}

test_aws_status_reports_plaintext() {
  aws_env; seed_credentials
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  printf '[late]\naws_access_key_id = AKLATE\naws_secret_access_key = SKLATE\n' >> "$AWS_SHARED_CREDENTIALS_FILE"
  run_out "$ROOT/libexec/s3seal" status
  assert_out "sealed:     other, prod"
  assert_out "PLAINTEXT:  temp, late"
}

test_aws_enable_without_cli_fails() {
  aws_env; seed_credentials
  rm -f "$T/bin/aws"
  run_out "$ROOT/libexec/s3seal" enable aws --yes
  assert_rc 1
  assert_in "$AWS_SHARED_CREDENTIALS_FILE" "AKPROD1"
}

# --- installer and uninstaller ----------------------------------------------
install_env() {
  mkdir -p "$T/bin"
  export PATH="$T/bin:$GPG_DIR:/usr/bin:/bin"
  export S3SEAL_YES=1
  unset S3SEAL_INSTALL_DIR S3SEAL_SHARE_DIR MC_BIN
}

# install.sh piped into bash downloads the files; a fake curl serves them from $1.
fake_curl() {
  cat > "$T/bin/curl" <<EOF2
#!/bin/sh
src="$1"
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
rel="\$(printf '%s' "\$url" | cut -d/ -f7-)"
[ -f "\$src/\$rel" ] || exit 22
mkdir -p "\$(dirname "\$out")"
cp "\$src/\$rel" "\$out"
EOF2
  chmod +x "$T/bin/curl"
}

test_install_from_checkout() {
  install_env
  cp "$FAKE_MC" "$T/bin/mc"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "Copying s3seal from this checkout"
  assert_out "mc: found the official client at $T/bin/mc"
  assert_out "Current state:"
  for f in libexec/mc libexec/aws libexec/s3seal lib/common.sh lib/ini.sh lib/aws.sh lib/mc.sh; do
    cmp -s "$ROOT/$f" "$HOME/.local/share/s3seal/$f" || fail "$f not installed"
  done
  [[ "$(readlink "$HOME/.local/share/s3seal/bin/s3seal")" == "$HOME/.local/share/s3seal/libexec/s3seal" ]] || fail "s3seal not linked"
  [[ "$(cat "$S3SEAL_CONFIG_DIR/mc-path")" == "$T/bin/mc" ]] || fail "mc-path not recorded"
  assert_file "$T/bin/mc"
}

test_install_leaves_official_client_without_consent() {
  install_env
  cp "$FAKE_MC" "$T/bin/mc"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "left in place"
  assert_file "$T/bin/mc"
}

test_install_explains_move_that_needs_root() {
  command -v python3 >/dev/null 2>&1 || return 0
  install_env
  export S3SEAL_NO_SUDO=1
  unset S3SEAL_YES
  cp "$FAKE_MC" "$T/bin/mc"
  chmod 555 "$T/bin"
  OUT="$(printf 'Select the clients\t\nInstall s3seal to\t\nMove it out of PATH\ty\nKeep it in\t%s\nRun the command above\t\n' "$T/libexec" \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh")"
  chmod 755 "$T/bin"
  assert_out "running as user: $(id -un)"
  assert_out "$T/bin is not writable by $(id -un)"
  assert_out "sudo mv $T/bin/mc $T/libexec/mc"
  assert_file "$T/bin/mc"
  [[ "$(cat "$S3SEAL_CONFIG_DIR/mc-path")" == "$T/bin/mc" ]] || fail "mc-path should keep the old location"
}

test_install_asks_before_moving_official_client() {
  command -v python3 >/dev/null 2>&1 || return 0
  install_env
  unset S3SEAL_YES
  cp "$FAKE_MC" "$T/bin/mc"
  OUT="$(printf 'Select the clients\t\nInstall s3seal to\t\nMove it out of PATH\ty\nKeep it in\t%s\n' "$T/libexec" \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh")"
  assert_out "moved to $T/libexec/mc"
  assert_file "$T/libexec/mc"
  assert_no_file "$T/bin/mc"
  [[ "$(cat "$S3SEAL_CONFIG_DIR/mc-path")" == "$T/libexec/mc" ]] || fail "mc-path not updated"
}

test_install_finds_only_present_clients() {
  install_env
  cp "$FAKE_MC" "$T/bin/mc"
  export S3SEAL_YES=1
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "found the official client"
  assert_no_file "$S3SEAL_CONFIG_DIR/aws-path"
}

test_install_reports_missing_clients() {
  install_env
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "No supported client was found on PATH"
  assert_out "Install one and re-run"
}

test_install_ignores_midnight_commander() {
  install_env
  cp "$MIDNIGHT" "$T/bin/mc"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "No supported client was found on PATH"
  assert_not_out "Protect"
}

test_install_replaces_old_layout_file() {
  install_env
  mkdir -p "$HOME/.local/share/s3seal/libexec"
  printf '#!/bin/sh\n# s3seal: old layout\n' > "$HOME/.local/share/s3seal/libexec/s3seal"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  [[ -f "$HOME/.local/share/s3seal/libexec/s3seal" ]] || fail "current layout not installed"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "already installed and up to date"
}

test_install_replaces_nested_libexec_folder() {
  install_env
  mkdir -p "$HOME/.local/share/s3seal/libexec/s3seal"
  printf '#!/bin/sh\n# s3seal: nested layout\n' > "$HOME/.local/share/s3seal/libexec/s3seal/s3seal"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  [[ -f "$HOME/.local/share/s3seal/libexec/s3seal" ]] || fail "current layout not installed"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_out "already installed and up to date"
}

test_install_twice_is_idempotent() {
  install_env
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "Installing s3seal 1.1.0"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "s3seal 1.1.0 is already installed and up to date"
  assert_not_out "Installing s3seal"
  [[ "$(readlink "$HOME/.local/share/s3seal/bin/s3seal")" == "$HOME/.local/share/s3seal/libexec/s3seal" ]] || fail "link lost"
}

test_install_verifies_download_checksum() {
  install_env
  fake_curl "$ROOT"
  OUT="$("$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "all files match their checksums"
  assert_file "$HOME/.local/share/s3seal/lib/aws.sh"

  rm -rf "$T/tampered"; mkdir -p "$T/tampered"
  cp -r "$ROOT/libexec" "$ROOT/lib" "$T/tampered/"
  set_version "$T/tampered/libexec/s3seal" tampered
  fake_curl "$T/tampered"
  rm -rf "$HOME/.local/share/s3seal"
  OUT="$("$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 1; assert_out "checksum mismatch"
  assert_no_file "$HOME/.local/share/s3seal/bin/s3seal"

  OUT="$(S3SEAL_REF=some-branch "$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "not verified"
}

test_install_then_enable_aws_end_to_end() {
  install_env
  aws_env; seed_credentials
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" || fail "install failed: $OUT"
  run_out "$HOME/.local/share/s3seal/bin/s3seal" enable aws --yes
  assert_rc 0
  assert_out "Sealed AWS profile prod"
  run_out "$HOME/.local/share/s3seal/bin/s3seal" disable aws --yes
  assert_rc 0
}

test_uninstall_removes_commands_and_keeps_credentials() {
  install_env
  "$TEST_BASH" "$ROOT/install.sh" >/dev/null 2>&1 || fail "install failed"
  mkdir -p "$S3SEAL_CONFIG_DIR"; echo keep > "$S3SEAL_CONFIG_DIR/recipient"
  OUT="$("$TEST_BASH" "$ROOT/uninstall.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "Encrypted credentials kept"
  assert_no_file "$HOME/.local/share/s3seal/bin/s3seal"
  assert_no_file "$HOME/.local/share/s3seal"
  assert_file "$S3SEAL_CONFIG_DIR/recipient"
}

test_uninstall_purge_needs_confirmation() {
  command -v setsid >/dev/null 2>&1 || return 0
  mkdir -p "$S3SEAL_CONFIG_DIR"; echo keep > "$S3SEAL_CONFIG_DIR/recipient"
  OUT="$(setsid "$TEST_BASH" "$ROOT/uninstall.sh" --purge < /dev/null 2>&1)" && RC=0 || RC=$?
  assert_rc 1; assert_out "pass --yes"
  assert_file "$S3SEAL_CONFIG_DIR/recipient"
  OUT="$(setsid "$TEST_BASH" "$ROOT/uninstall.sh" --purge --yes < /dev/null 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "Purged"
  assert_no_file "$S3SEAL_CONFIG_DIR"
}

test_uninstall_refuses_while_credentials_are_sealed() {
  install_env
  aws_env; seed_credentials
  "$TEST_BASH" "$ROOT/install.sh" >/dev/null 2>&1 || fail "install failed"
  run_out "$HOME/.local/share/s3seal/bin/s3seal" enable aws --yes
  OUT="$("$TEST_BASH" "$ROOT/uninstall.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 1; assert_out "Credentials are still sealed"
  assert_file "$HOME/.local/share/s3seal/bin/s3seal"
}

# --- GPG key setup in the installer -----------------------------------------
keys_run() {  # answers on stdin: runs the installer on a terminal
  command -v python3 >/dev/null 2>&1 || return 1
  install_env
  unset S3SEAL_YES S3SEAL_GPG_RECIPIENT
  OUT="$(python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh")"
}

test_installer_creates_a_key_pair() {
  command -v python3 >/dev/null 2>&1 || return 0
  install_env
  unset S3SEAL_YES S3SEAL_GPG_RECIPIENT
  OUT="$(printf 'Install s3seal to\t\nUse an existing GPG key\t\nPassphrase (at least\tpass-phrase-1\nRepeat the passphrase\tpass-phrase-1\n' \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh")"
  assert_out "created the key pair"
  assert_not_out "pass-phrase-1"
  local fpr; fpr="$(cat "$S3SEAL_CONFIG_DIR/recipient")"
  [[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || fail "recipient is not a fingerprint: $fpr"
  [[ "$(cat "$S3SEAL_CONFIG_DIR/generated-key")" == "$fpr" ]] || fail "generated-key marker missing"
  gpg --batch --list-secret-keys "$fpr" >/dev/null 2>&1 || fail "key not in the keyring"
}

test_installer_rerun_keeps_key_and_creates_nothing() {
  command -v python3 >/dev/null 2>&1 || return 0
  install_env
  unset S3SEAL_YES S3SEAL_GPG_RECIPIENT
  printf 'Install s3seal to\t\nUse an existing GPG key\t\nPassphrase (at least\tpass-phrase-1\nRepeat the passphrase\tpass-phrase-1\n' \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh" >/dev/null
  local before after fpr
  fpr="$(cat "$S3SEAL_CONFIG_DIR/recipient")"
  before="$(gpg --batch --with-colons --list-secret-keys | grep -c '^sec')"
  OUT="$(printf 'Install s3seal to\t\nReplace it with a new key pair\t\n' \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh")"
  after="$(gpg --batch --with-colons --list-secret-keys | grep -c '^sec')"
  assert_out "already has its key ($fpr). Keeping it."
  [[ "$before" == "$after" ]] || fail "a key was created or removed on rerun"
  [[ "$(cat "$S3SEAL_CONFIG_DIR/recipient")" == "$fpr" ]] || fail "recipient changed on rerun"
}

test_installer_replace_reencrypts_and_removes_only_our_pair() {
  command -v python3 >/dev/null 2>&1 || return 0
  install_env
  unset S3SEAL_YES S3SEAL_GPG_RECIPIENT
  # An s3seal-created pair without a passphrase, so the test needs no pinentry.
  gpg -q --batch --passphrase '' --quick-gen-key 'old <old@s3seal.invalid>' default default never 2>/dev/null
  local old; old="$(gpg --batch --with-colons --list-secret-keys old@s3seal.invalid | awk -F: '$1=="fpr"{print $10; exit}')"
  mkdir -p "$S3SEAL_CONFIG_DIR"
  printf '%s\n' "$old" > "$S3SEAL_CONFIG_DIR/recipient"
  printf '%s\n' "$old" > "$S3SEAL_CONFIG_DIR/generated-key"
  # Read the old key's IDs now: the installer removes this key later.
  old_ids="$(gpg --batch --with-colons --list-keys "$old" | awk -F: '$1=="pub"||$1=="sub"{print $5}')"
  mkdir -p "$S3SEAL_CONFIG_DIR/aliases"
  printf 'https://AK1:SECRET1@minio.example.com' \
    | gpg -q --batch --yes --armor --encrypt --recipient "$old" --output "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc"
  local other; other="$(gpg --batch --with-colons --list-secret-keys test@s3seal.invalid | awk -F: '$1=="fpr"{print $10; exit}')"

  OUT="$(printf 'Install s3seal to\t\nReplace it with a new key pair\ty\nPassphrase (at least\tpass-phrase-2\nRepeat the passphrase\tpass-phrase-2\n' \
    | python3 "$ROOT/tests/pty_drive.py" "$TEST_BASH" "$ROOT/install.sh")"
  local new; new="$(cat "$S3SEAL_CONFIG_DIR/recipient")"
  [[ "$new" != "$old" ]] || fail "recipient did not change"
  assert_out "stored credentials are now encrypted to $new"
  gpg --batch --list-secret-keys "$old" >/dev/null 2>&1 && fail "old s3seal key still present"
  gpg --batch --list-secret-keys "$other" >/dev/null 2>&1 || fail "an unrelated key was removed"
  # The new key has a passphrase. --list-only shows the recipients without
  # unlocking anything, so no passphrase prompt can appear. Encryption uses a subkey, so compare every key ID.
  local packets rc=0
  packets="$(gpg --batch --list-packets --list-only "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc" 2>&1)" || rc=$?
  (( rc == 0 )) || fail "could not read the packets of prod.url.asc (rc=$rc): $packets"
  local new_ids id
  new_ids="$(gpg --batch --with-colons --list-keys "$new" | awk -F: '$1=="pub"||$1=="sub"{print $5}')"
  local hit_new=0 hit_old=0
  for id in $new_ids; do grep -q "keyid $id" <<<"$packets" && hit_new=1; done
  for id in $old_ids; do grep -q "keyid $id" <<<"$packets" && hit_old=1; done
  (( hit_new )) || fail "stored credential was not re-encrypted to the new key"
  (( hit_old )) && fail "stored credential still names the old key"
  assert_no_file "$S3SEAL_CONFIG_DIR/aliases/prod.url.asc.rekey"
}

test_install_checksums_are_current() {
  local f actual
  for f in libexec/mc libexec/aws libexec/s3seal lib/common.sh lib/ini.sh lib/aws.sh lib/mc.sh; do
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$ROOT/$f" | cut -d' ' -f1)"
    else
      actual="$(shasum -a 256 "$ROOT/$f" | cut -d' ' -f1)"
    fi
    grep -qF "$actual  $f" "$ROOT/install.sh" || fail "install.sh is stale for $f; run scripts/update-checksum.sh"
  done
}

test_install_reports_upgrade_over_older_version() {
  install_env
  "$TEST_BASH" "$ROOT/install.sh" >/dev/null 2>&1 || fail "first install failed"
  set_version "$HOME/.local/share/s3seal/libexec/s3seal" 1.0.0
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "Upgrading s3seal 1.0.0 -> 1.1.0"
  assert_out "installed s3seal 1.1.0"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_out "already installed and up to date"
}

test_install_reports_refresh_of_changed_files() {
  install_env
  "$TEST_BASH" "$ROOT/install.sh" >/dev/null 2>&1 || fail "first install failed"
  echo '# local edit' >> "$HOME/.local/share/s3seal/lib/aws.sh"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "already installed. Refreshing 1 changed file(s)"
  ! grep -q 'local edit' "$HOME/.local/share/s3seal/lib/aws.sh" || fail "changed file not restored"
}

test_upgrade_check_and_latest() {
  install_env
  fake_curl "$ROOT"
  OUT="$("$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  run_entry "$HOME/.local/share/s3seal/bin/s3seal" upgrade --check
  assert_rc 0
  assert_out "installed 1.1.0, available 1.1.0 (mhbahmani/s3seal@master)"
  run_entry "$HOME/.local/share/s3seal/bin/s3seal" upgrade
  assert_rc 0
  assert_out "already the latest version"
}

test_upgrade_replaces_older_install() {
  install_env
  fake_curl "$ROOT"
  OUT="$("$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  set_version "$HOME/.local/share/s3seal/libexec/s3seal" 1.0.0
  run_entry "$HOME/.local/share/s3seal/bin/s3seal" upgrade --check
  assert_out "installed 1.0.0, available 1.1.0"
  run_entry "$HOME/.local/share/s3seal/bin/s3seal" upgrade
  assert_rc 0
  assert_out "Upgrading s3seal 1.0.0 -> 1.1.0"
  run_out "$HOME/.local/share/s3seal/bin/s3seal" --version
  assert_out "s3seal 1.1.0"
}

test_upgrade_refuses_a_checkout() {
  run_entry "$ROOT/libexec/s3seal" upgrade --check
  assert_rc 1
  assert_out "installed copy, not on a git checkout"
}

# ---------------------------------------------------------------------------
for t in $(declare -F | sed -n 's/^declare -f test_//p'); do
  run_test "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
