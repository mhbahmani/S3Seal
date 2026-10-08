#!/usr/bin/env bash
#
# Test suite for sealedmc. Needs only bash and gpg; python3 is used for the
# interactive-prompt test when available.
#
#   tests/run.sh                    run everything
#   tests/run.sh migrate            run tests whose name contains "migrate"
#   TEST_BASH=/bin/bash tests/run.sh   run the scripts under another bash
#
# Each test gets a throwaway HOME, GNUPGHOME and a fake mc binary that
# records its arguments and MC_HOST_* environment.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/mc"
TEST_BASH="${TEST_BASH:-bash}"
FILTER="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sealedmc-test.XXXXXX")"
trap 'gpgconf --homedir "$WORK/gnupg" --kill all >/dev/null 2>&1; rm -rf "$WORK"' EXIT

PASS=0 FAIL=0 FAILED=()

# --- one GPG key for the whole run ------------------------------------------
export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'sealedmc test <test@sealedmc.invalid>' \
  default default never >/dev/null 2>&1 || { echo "cannot create a GPG test key" >&2; exit 1; }

# --- fake MinIO client ------------------------------------------------------
FAKE_MC="$WORK/fake-mc"
cat > "$FAKE_MC" <<'EOF'
#!/usr/bin/env bash
# Records every call to $FAKE_MC_LOG. "alias list --json" and "alias remove"
# operate on the JSON lines in $FAKE_MC_CONFIG.
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
  *" ls sealedmcprobe/ "*) exit "${FAKE_MC_LS_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$FAKE_MC"

MIDNIGHT="$WORK/midnight-mc"
printf '#!/bin/sh\necho "GNU Midnight Commander 4.8.30"\n' > "$MIDNIGHT"
chmod +x "$MIDNIGHT"

# --- harness ----------------------------------------------------------------
setup() {
  T="$WORK/t.$1"
  mkdir -p "$T/home"
  export HOME="$T/home"
  export SEALEDMC_CONFIG_DIR="$HOME/.config/sealedmc"
  export SEALEDMC_GPG_RECIPIENT="test@sealedmc.invalid"
  export SEALEDMC_NO_VERIFY=1
  export MC_BIN="$FAKE_MC"
  export FAKE_MC_LOG="$T/mc.log"
  export FAKE_MC_CONFIG="$T/config.jsonl"
  : > "$FAKE_MC_LOG"; : > "$FAKE_MC_CONFIG"
  unset SEALEDMC_LIST_ENDPOINTS SEALEDMC_ACTIVE COMP_LINE FAKE_MC_LS_RC
  for v in $(env | sed -n 's/^\(MC_HOST_[^=]*\)=.*/\1/p'); do unset "$v"; done
}

# Run the wrapper; output in $OUT, exit code in $RC. stdin is /dev/null and
# setsid (where available) removes the controlling terminal.
run_mc() {
  local nosid=()
  command -v setsid >/dev/null 2>&1 && nosid=(setsid)
  OUT="$(${nosid[@]+"${nosid[@]}"} "$TEST_BASH" "$WRAPPER" "$@" < /dev/null 2>&1)" && RC=0 || RC=$?
}

fail() { printf '    %s\n' "$*"; return 1; }
assert_rc()        { [[ "$RC" == "$1" ]] || fail "expected exit $1, got $RC; output: $OUT"; }
assert_out()       { [[ "$OUT" == *"$1"* ]] || fail "output lacks '$1': $OUT"; }
assert_not_out()   { [[ "$OUT" != *"$1"* ]] || fail "output unexpectedly has '$1': $OUT"; }
assert_log()       { grep -qF -- "$1" "$FAKE_MC_LOG" || fail "mc log lacks '$1': $(cat "$FAKE_MC_LOG")"; }
assert_not_log()   { ! grep -qF -- "$1" "$FAKE_MC_LOG" || fail "mc log unexpectedly has '$1'"; }
assert_file()      { [[ -e "$1" ]] || fail "missing file $1"; }
assert_no_file()   { [[ ! -e "$1" ]] || fail "unexpected file $1"; }

stored() { gpg --quiet --batch --decrypt "$SEALEDMC_CONFIG_DIR/aliases/$1.url.asc" 2>/dev/null; }
store() { run_mc alias set "$1" "$2" "$3" "$4"; [[ "$RC" == 0 ]] || fail "store $1 failed: $OUT"; }

run_test() {
  local name="$1"
  [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
  # Not in an "if" or "||": bash ignores set -e there, even in a subshell.
  local rc
  ( setup "$name"; set -e; "test_$name" ); rc=$?
  if (( rc == 0 )); then
    PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$name"); printf 'FAIL %s\n' "$name"
  fi
}

# --- wrapper: storing and using aliases -------------------------------------
test_set_stores_encrypted_and_exports() {
  store prod https://minio.example.com AKIA0001 'secret/with+special@chars'
  assert_out "Stored alias prod -> https://minio.example.com (encrypted)"
  local f="$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
  assert_file "$f"
  [[ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" == 600 ]] || fail "store file is not 0600"
  ! grep -q 'secret' "$f" || fail "secret appears in the store file"
  run_mc ls prod/bucket
  assert_rc 0
  # Keys are passed verbatim: mc does not percent-decode MC_HOST_ values.
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
  run_mc alias set my-minio https://minio.example.com AK SECRET123
  assert_rc 1; assert_out "cannot be used"
  run_mc alias set prod https://minio.example.com/path AK SECRET123
  assert_rc 1; assert_out "bare endpoint"
  run_mc alias set prod https://user:pw@minio.example.com AK SECRET123
  assert_rc 1; assert_out "bare endpoint"
}

test_set_checks_recipient_before_prompting() {
  unset SEALEDMC_GPG_RECIPIENT
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
  OUT="$(python3 - "$TEST_BASH" "$WRAPPER" <<'EOF'
import os, pty, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], [sys.argv[1], sys.argv[2], "alias", "set", "prod", "https://minio.example.com"])
buf = b""
def until(s):
    global buf
    while s not in buf:
        buf += os.read(fd, 1024)
until(b"Access key: "); os.write(fd, b"AKPROMPT\n")
until(b"Secret key: "); os.write(fd, b"SKPROMPT/+x\n")
try:
    while True:
        chunk = os.read(fd, 1024)
        if not chunk: break
        buf += chunk
except OSError:
    pass
os.waitpid(pid, 0)
sys.stdout.write(buf.decode())
EOF
)"
  assert_out "Stored alias prod"
  assert_not_out "SKPROMPT"   # the secret is read without echo
  [[ "$(stored prod)" == "https://AKPROMPT:SKPROMPT/+x@minio.example.com" ]] || fail "stored: $(stored prod)"
}

test_set_verifies_connection() {
  unset SEALEDMC_NO_VERIFY
  store prod https://minio.example.com AK1 SECRET123
  assert_out "Verified connection"
  assert_log "ENV: MC_HOST_sealedmcprobe=https://AK1:SECRET123@minio.example.com"
  export FAKE_MC_LS_RC=1
  store dev https://minio.example.com AK1 SECRET123
  assert_out "could not list buckets"
  assert_file "$SEALEDMC_CONFIG_DIR/aliases/dev.url.asc"
}

test_global_flag_before_alias_is_intercepted() {
  unset SEALEDMC_NO_VERIFY
  run_mc --insecure alias set prod https://minio.example.com AK1 SECRET123
  assert_rc 0
  assert_out "Stored alias prod"
  assert_not_log "[alias] [set]"
  assert_log "ARGS: [--insecure] [ls] [sealedmcprobe/]"
  run_mc --config-dir /tmp/x alias list
  assert_rc 0; assert_out "prod"
  # The only mc call is the plaintext check, which keeps the global flags.
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

# --- wrapper: using aliases -------------------------------------------------
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
  echo garbage > "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
  run_mc ls prod/
  assert_rc 1
  assert_out "GPG decryption failed for alias 'prod'"
  assert_not_log "ARGS: [ls]"
}

test_existing_env_alias_wins() {
  store prod https://minio.example.com AK1 SECRET123
  echo garbage > "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
  export MC_HOST_prod="https://ENVKEY:ENVSECRET@other.example.com"
  run_mc ls prod/
  assert_rc 0
  assert_log "ENV: MC_HOST_prod=https://ENVKEY:ENVSECRET@other.example.com"
}

test_completion_never_decrypts() {
  store prod https://minio.example.com AK1 SECRET123
  echo garbage > "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
  export COMP_LINE="mc ls prod/"
  run_mc mc prod/ ls
  assert_rc 0
  assert_not_log "MC_HOST_prod"
}

# --- wrapper: list, remove, migrate -----------------------------------------
test_list_and_endpoints() {
  run_mc alias list
  assert_out "No aliases stored"
  store prod https://minio.example.com AK1 SECRET123
  run_mc alias ls
  assert_rc 0; assert_out "prod"; assert_not_out "minio.example.com"
  export SEALEDMC_LIST_ENDPOINTS=1
  run_mc alias list
  assert_out "https://minio.example.com"; assert_not_out "SECRET123"
}

test_list_warns_about_plaintext() {
  cat > "$FAKE_MC_CONFIG" <<'EOF'
{"status":"success","alias":"play","URL":"https://play.min.io","accessKey":"Q3AM3UQ867SPQQA43P2F","secretKey":"zuf+tfteSlswRu7BJ86wekitnifILbZam1KYY3TG","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"s3","URL":"https://s3.amazonaws.com","accessKey":"YOUR-ACCESS-KEY-HERE","secretKey":"YOUR-SECRET-KEY-HERE","api":"S3v4","path":"dns","src":"/x/config.json"}
{"status":"success","alias":"local","URL":"http://localhost:9000","path":"auto","src":"/x/config.json"}
EOF
  run_mc alias list
  assert_not_out "plaintext credentials"
  echo '{"status":"success","alias":"prod","URL":"https://minio.example.com","accessKey":"AK1","secretKey":"SECRET123","api":"S3v4","path":"auto","src":"/x/config.json"}' >> "$FAKE_MC_CONFIG"
  run_mc alias list
  assert_out "plaintext credentials for: prod"
  assert_out "mc alias migrate"
}

test_remove() {
  store prod https://minio.example.com AK1 SECRET123
  run_mc alias rm prod
  assert_rc 0; assert_out "Removed alias prod"
  assert_no_file "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
  run_mc alias remove prod
  assert_rc 1; assert_out "no stored credentials"
}

test_remove_rejects_path_traversal() {
  mkdir -p "$SEALEDMC_CONFIG_DIR/aliases"
  touch "$SEALEDMC_CONFIG_DIR/victim.url.asc"
  run_mc alias remove ../victim
  assert_rc 1
  assert_file "$SEALEDMC_CONFIG_DIR/victim.url.asc"
}

test_migrate() {
  cat > "$FAKE_MC_CONFIG" <<'EOF'
{"status":"success","alias":"play","URL":"https://play.min.io","accessKey":"Q3AM3UQ867SPQQA43P2F","secretKey":"zuf+tfteSlswRu7BJ86wekitnifILbZam1KYY3TG","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"prod","URL":"https://minio.example.com","accessKey":"AK1","secretKey":"a&b/c+d\"e\\f","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"my-minio","URL":"https://m.example.com","accessKey":"AK2","secretKey":"SECRET456","api":"S3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"legacy","URL":"https://l.example.com","accessKey":"AK3","secretKey":"SECRET789","api":"S3v2","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"envy","URL":"https://e.example.com","accessKey":"AK4","secretKey":"SECRET000","api":"S3v4","src":"env"}
EOF
  run_mc alias migrate
  assert_rc 1   # some aliases were skipped
  assert_out "Migrated alias prod"
  assert_out "skipping 'my-minio'"
  assert_out "skipping 'legacy'"
  assert_out "1 migrated, 2 skipped"
  assert_not_out "envy"
  [[ "$(stored prod)" == 'https://AK1:a&b/c+d"e\f@minio.example.com' ]] || fail "stored: $(stored prod)"
  assert_log "ARGS: [alias] [remove] [prod]"
  ! grep -q '"alias":"prod"' "$FAKE_MC_CONFIG" || fail "prod still in plaintext config"
  grep -q '"alias":"play"' "$FAKE_MC_CONFIG" || fail "play was touched"
}

test_migrate_selected_names() {
  cat > "$FAKE_MC_CONFIG" <<'EOF'
{"status":"success","alias":"prod","URL":"https://p.example.com","accessKey":"AK1","secretKey":"SECRET123","api":"s3v4","path":"auto","src":"/x/config.json"}
{"status":"success","alias":"dev","URL":"https://d.example.com","accessKey":"AK2","secretKey":"SECRET456","api":"S3v4","path":"auto","src":"/x/config.json"}
EOF
  run_mc alias migrate dev
  assert_rc 0
  assert_out "1 migrated, 0 skipped"
  assert_file "$SEALEDMC_CONFIG_DIR/aliases/dev.url.asc"
  assert_no_file "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
}

test_migrate_does_not_overwrite() {
  store prod https://minio.example.com AK1 SECRET123
  echo '{"status":"success","alias":"prod","URL":"https://other.example.com","accessKey":"AKX","secretKey":"SECRETX1","api":"S3v4","path":"auto","src":"/x/config.json"}' > "$FAKE_MC_CONFIG"
  run_mc alias migrate
  assert_rc 1; assert_out "already exists"
  [[ "$(stored prod)" == "https://AK1:SECRET123@minio.example.com" ]] || fail "existing alias overwritten"
}

# --- wrapper: encryption failures and binary discovery ----------------------
test_encrypt_failure_leaves_no_temp_files() {
  export SEALEDMC_GPG_RECIPIENT="nobody@nowhere.invalid"
  run_mc alias set prod https://minio.example.com AK1 SECRET123
  assert_rc 1
  assert_out "GPG encryption failed"
  assert_out "sealedmc: gpg: "   # gpg's own diagnostics are shown
  local left; left="$(find "$SEALEDMC_CONFIG_DIR" -name '*.tmp.*' 2>/dev/null)"
  [[ -z "$left" ]] || fail "temp files left: $left"
}

test_recursion_guard() {
  export SEALEDMC_ACTIVE=1
  run_mc ls
  assert_rc 1; assert_out "recursion detected"
}

test_mc_path_file_and_self_skipping() {
  unset MC_BIN
  mkdir -p "$SEALEDMC_CONFIG_DIR"
  printf '%s\n' "$FAKE_MC" > "$SEALEDMC_CONFIG_DIR/mc-path"
  run_mc --sealedmc-version
  assert_rc 0; assert_out "wrapping $FAKE_MC"
  export MC_BIN="$WRAPPER"   # pointing MC_BIN at the wrapper must not loop
  run_mc --sealedmc-version
  assert_rc 0; assert_out "wrapping $FAKE_MC"
}

test_midnight_commander_is_not_used() {
  unset MC_BIN
  mkdir -p "$HOME/.local/libexec"
  cp "$MIDNIGHT" "$HOME/.local/libexec/mc"
  run_mc --sealedmc-version
  assert_not_out "$HOME/.local/libexec/mc"
  cp "$FAKE_MC" "$HOME/.local/libexec/mc"
  run_mc --sealedmc-version
  assert_rc 0; assert_out "wrapping $HOME/.local/libexec/mc"
}

# --- installer --------------------------------------------------------------
# A PATH with the basics only, plus $T/bin for test doubles.
install_env() {
  mkdir -p "$T/bin"
  export PATH="$T/bin:/usr/bin:/bin"
  export SEALEDMC_INSTALL_DIR="$HOME/.local/bin"
}

test_install_from_checkout() {
  install_env
  cp "$MIDNIGHT" "$T/bin/mc"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0
  assert_out "not the MinIO client (Midnight Commander?)"
  assert_out "found the real MinIO client at $FAKE_MC"
  assert_out "mc alias migrate"
  cmp -s "$ROOT/mc" "$HOME/.local/bin/mc" || fail "wrapper not installed"
  [[ "$(cat "$SEALEDMC_CONFIG_DIR/mc-path")" == "$FAKE_MC" ]] || fail "mc-path not recorded"
}

test_install_refuses_real_mc_on_path() {
  install_env
  cp "$FAKE_MC" "$T/bin/mc"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 1
  assert_out "the real mc binary is still on your PATH"
  assert_no_file "$HOME/.local/bin/mc"
}

test_install_rejects_non_minio_binary() {
  install_env
  export MC_BIN="$MIDNIGHT"
  OUT="$("$TEST_BASH" "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 1
  assert_out "ignoring $MIDNIGHT: not the MinIO client"
  assert_out "dl.min.io/client/mc/release/"
}

# install.sh piped into bash downloads the wrapper; a fake curl serves it.
fake_curl() {
  cat > "$T/bin/curl" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { cp "$1" "\$2"; exit 0; }; shift; done
exit 1
EOF
  chmod +x "$T/bin/curl"
}

test_install_verifies_download_checksum() {
  install_env
  fake_curl "$ROOT/mc"
  OUT="$("$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "verified wrapper checksum"

  sed 's/^VERSION=.*/VERSION="tampered"/' "$ROOT/mc" > "$T/tampered"
  fake_curl "$T/tampered"
  rm -f "$HOME/.local/bin/mc"
  OUT="$("$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 1; assert_out "checksum mismatch"
  assert_no_file "$HOME/.local/bin/mc"

  OUT="$(SEALEDMC_REF=some-branch "$TEST_BASH" < "$ROOT/install.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "no checksum to verify"
}

test_install_checksum_is_current() {
  local embedded actual
  embedded="$(sed -n 's/^WRAPPER_SHA256="\(.*\)"/\1/p' "$ROOT/install.sh")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ROOT/mc" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$ROOT/mc" | cut -d' ' -f1)"
  fi
  [[ "$embedded" == "$actual" ]] || fail "install.sh is stale; run scripts/update-checksum.sh"
}

# --- uninstaller ------------------------------------------------------------
test_uninstall_keeps_credentials_by_default() {
  install_env
  "$TEST_BASH" "$ROOT/install.sh" >/dev/null 2>&1 || fail "install failed"
  store prod https://minio.example.com AK1 SECRET123
  OUT="$("$TEST_BASH" "$ROOT/uninstall.sh" 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "Encrypted credentials kept"
  assert_no_file "$HOME/.local/bin/mc"
  assert_file "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
}

test_uninstall_purge_needs_confirmation() {
  command -v setsid >/dev/null 2>&1 || return 0
  store prod https://minio.example.com AK1 SECRET123
  OUT="$(setsid "$TEST_BASH" "$ROOT/uninstall.sh" --purge < /dev/null 2>&1)" && RC=0 || RC=$?
  assert_rc 1; assert_out "pass --yes"
  assert_file "$SEALEDMC_CONFIG_DIR/aliases/prod.url.asc"
  OUT="$(setsid "$TEST_BASH" "$ROOT/uninstall.sh" --purge --yes < /dev/null 2>&1)" && RC=0 || RC=$?
  assert_rc 0; assert_out "Purged"
  assert_no_file "$SEALEDMC_CONFIG_DIR"
}

# ---------------------------------------------------------------------------
for t in $(declare -F | sed -n 's/^declare -f test_//p'); do
  run_test "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
