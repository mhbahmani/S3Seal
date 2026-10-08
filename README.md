# s3seal

`s3seal` keeps S3 credentials for `mc` and `aws` encrypted with GPG, instead of
plaintext in `~/.mc/config.json` and `~/.aws/credentials`.

You keep using `mc` and `aws` as usual. `s3seal` only turns sealing on or off
for each tool and shows what is sealed.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mhbahmani/s3seal/master/install.sh | bash
```

Requirements: `bash`, `gpg`, and the MinIO client `mc` if you use it. The
installer finds the real `mc` binary and asks you to move it out of `PATH`
first, because the `mc` wrapper takes its name.

Set your GPG recipient once:

```bash
echo 'you@example.com' > ~/.config/s3seal/recipient
```

Running the installer again is safe. It reports what it found.

## mc

```bash
mc alias set prod https://minio.example.com   # asks for keys, stores them encrypted
mc ls prod/bucket
mc alias list
mc alias remove prod
mc alias migrate                              # encrypts aliases from ~/.mc/config.json
```

`mc alias migrate` moves each plaintext alias into the encrypted store and
removes its plaintext copy. It skips aliases it cannot store and says why.

## AWS CLI

```bash
s3seal enable aws      # seal every profile with static keys
aws configure          # new keys are stored encrypted
aws --profile prod s3 ls
s3seal status          # shows sealed and plaintext profiles
s3seal disable aws     # restore plaintext keys, after confirmation
```

Sealed keys are stored in `~/.config/s3seal/aws/`. Each sealed profile in
`~/.aws/config` uses `credential_process`, so the AWS CLI and SDKs fetch the
keys when they need them. `aws configure` is handled by `s3seal`. Other
commands run the real CLI unchanged.

Profiles with temporary session tokens and SSO profiles are not sealed.

## Upgrade and uninstall

```bash
s3seal upgrade --check   # show installed and available versions
s3seal upgrade           # install the latest release
s3seal --version

./uninstall.sh           # remove commands, keep encrypted credentials
./uninstall.sh --purge   # also delete encrypted credentials, after confirmation
```

`s3seal upgrade` downloads the installer from the repository the copy came
from, and the installer checks every file against its checksums. It does not
work on a git checkout.

Uninstall refuses while AWS profiles are sealed. Run `s3seal disable aws` first.

## Settings

| Variable | Purpose |
| --- | --- |
| `S3SEAL_GPG_RECIPIENT` | GPG key id or email to encrypt to |
| `S3SEAL_CONFIG_DIR` | Store location (default `~/.config/s3seal`) |
| `S3SEAL_INSTALL_DIR` | Where the `mc`, `aws` and `s3seal` links go (default `~/.local/bin`) |
| `MC_BIN` | Path to the real `mc` binary |
| `S3SEAL_LIST_ENDPOINTS` | Show endpoints in `mc alias list` (decrypts every alias) |
| `S3SEAL_DEBUG` | Always show gpg's diagnostics |

## Limitations

- `mc` alias names must be shell identifiers, such as `my_minio`. AWS profile
  names may contain `-` and `.`.
- `mc` keys cannot contain `:`, because `mc` reads them from one URL string.
- `mc --api`, `--path` and `mc config host` are not supported.
- Non-interactive use asks for the GPG passphrase unless `gpg-agent` has it
  cached.
- While a command runs, its credentials are visible in `/proc/<pid>/environ` to
  the same user and to root.
- Tools can still call the real binaries by path and bypass `s3seal`.

## License

MIT. See [LICENSE](LICENSE).
