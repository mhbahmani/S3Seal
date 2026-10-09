# shellcheck shell=bash
# GPG keys for s3seal: create the key pair s3seal uses, and replace it while
# re-encrypting every stored credential first. Only the pair s3seal created is
# ever removed. Needs common.sh.

# Fingerprint of the key pair s3seal created, if any.
key_mark_file() { printf '%s/generated-key' "$CONFIG_DIR"; }

# Fingerprints of all secret keys in the keyring, one per line.
key_fingerprints() {
  gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | sort
}

# Prints the fingerprint of the key set as the recipient, if it is in the keyring.
key_current() {
  local fpr
  fpr="$(head -n1 "$CONFIG_DIR/recipient" 2>/dev/null || true)"
  [[ -n "$fpr" ]] || return 1
  gpg --batch --list-secret-keys "$fpr" >/dev/null 2>&1 || return 1
  printf '%s' "$fpr"
}

# Creates a key pair with the user ID USER-ID, protected by PASSPHRASE, without the
# passphrase appearing in any command line. Prints the new fingerprint.
key_create() {  # USER-ID PASSPHRASE
  local before after fpr
  before="$(key_fingerprints)"
  run_gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
    --quick-gen-key "$1" default default never 3<<<"$2" >/dev/null \
    || die "could not create the GPG key"
  after="$(key_fingerprints)"
  fpr="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n1)"
  [[ -n "$fpr" ]] || die "the GPG key was created but could not be found"
  printf '%s' "$fpr"
}

# Makes FPR the recipient, and remembers it as created by s3seal.
key_use() {  # FPR CREATED(yes|no)
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$1" > "$CONFIG_DIR/recipient"
  if [[ "$2" == yes ]]; then
    printf '%s\n' "$1" > "$(key_mark_file)"
  fi
}

# Re-encrypts every stored credential to NEW, then makes NEW the recipient and
# removes the old pair if s3seal created it. Nothing changes until every file has
# been re-encrypted, so a failure leaves the store as it was.
key_rekey() {  # NEW
  local new="$1" old ours f plain tmp failed=0 files=()
  old="$(key_current || true)"
  ours="$(head -n1 "$(key_mark_file)" 2>/dev/null || true)"
  for f in "$CONFIG_DIR"/aws/*.secret.asc "$CONFIG_DIR"/aliases/*.url.asc; do
    [[ -e "$f" ]] && files+=("$f")
  done

  for f in ${files[@]+"${files[@]}"}; do
    tmp="$f.rekey"
    plain="$(run_gpg --quiet --batch --decrypt "$f")" || { failed=1; break; }
    printf '%s' "$plain" | run_gpg --quiet --batch --yes --armor --encrypt \
      --recipient "$new" --output "$tmp" || { failed=1; break; }
  done
  if (( failed )); then
    rm -f -- "$CONFIG_DIR"/aws/*.rekey "$CONFIG_DIR"/aliases/*.rekey
    die "could not re-encrypt $f with the current key; nothing was changed. Your credentials are still usable with the old key."
  fi

  for f in ${files[@]+"${files[@]}"}; do
    mv -f "$f.rekey" "$f"
  done
  key_use "$new" yes

  if [[ -n "$old" && "$old" != "$new" && "$ours" == "$old" ]]; then
    run_gpg --batch --yes --delete-secret-and-public-key "$old" \
      || warn "re-encrypted, but the old key $old could not be removed"
  fi
  printf '%s' "$new"
}
