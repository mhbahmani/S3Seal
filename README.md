# s3seal

`s3seal` keeps S3 credentials for the command-line clients you already use
(`mc` and `aws`) encrypted with GPG, instead of in plaintext files such as
`~/.mc/config.json` and `~/.aws/credentials`.

You keep typing `mc` and `aws`. The only new command is `s3seal`, and you use
it to turn sealing on or off for a tool and to check its state.

- Keys are encrypted to one of your GPG keys and never written to disk unencrypted.
- Keys are decrypted only when a command needs them.
- Keys never appear in command-line arguments, shell history or environment
  variables of the AWS CLI.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mhbahmani/s3seal/master/install.sh | bash
```

The installer copies s3seal to `~/.local/share/s3seal` and links `mc` and
`s3seal` into `~/.local/bin`. It verifies every downloaded file against a
checksum embedded in `install.sh`. Nothing about `aws` changes until you run
`s3seal enable aws`.

Requirements: `bash`, `gpg`, and the MinIO client (`mc`) if you use it. The
installer finds the real `mc` binary and refuses to continue while it is on
`PATH`, because the wrapper takes over the name. Move it to
`~/.local/libexec/mc` as the installer suggests.

Set your GPG recipient once:

```bash
echo 'you@example.com' > ~/.config/s3seal/recipient
```

or set `S3SEAL_GPG_RECIPIENT`.

## AWS CLI

```bash
s3seal enable aws      # seal every profile with static keys in ~/.aws/credentials
aws configure          # from now on, keys are stored encrypted
aws --profile prod s3 ls
s3seal status
s3seal disable aws     # restore plaintext keys (asks for confirmation)
```

How it works:

- Each sealed profile's keys are stored in `~/.config/s3seal/aws/PROFILE.secret.asc`.
- The profile's section in `~/.aws/config` gets a `credential_process` line.
  The AWS CLI and every AWS SDK call `s3seal credential-process` when they need
  the keys, so nothing is decrypted until a command uses that profile.
- `~/.local/bin/aws` is a shim. It handles `aws configure` (interactive, and
  `set`/`get` of the key fields) and `aws configure import`. Every other command
  runs the real AWS CLI unchanged.
- Other settings (`region`, `output`) are still written by the real CLI to
  `~/.aws/config`.

Not sealed: profiles with temporary session tokens (they expire on their own),
SSO profiles, and profiles whose keys are written by other tools that bypass
`aws configure`. `s3seal status` lists any plaintext profiles it finds.

## mc

`mc` works as before, through the wrapper:

```bash
mc alias set prod https://minio.example.com   # prompts for keys, stored encrypted
mc ls prod/bucket
mc alias list
mc alias remove prod
mc alias migrate                              # encrypt aliases from ~/.mc/config.json
```

Keys are stored verbatim, because `mc` does not percent-decode `MC_HOST_`
values. A `:` in either key is rejected, because mc would misread it.
`mc alias migrate` skips aliases it cannot express and says why. Aliases can
be migrated only by name (`mc alias migrate prod`).

Moving `mc` onto the same store as `aws` (`s3seal enable mc`) is the next step.

## Limitations

- Alias and profile names must be valid shell identifiers (`my_minio`, not
  `my-minio`) for `mc`. AWS profile names may contain `-` and `.`.
- `mc --api`, `--path`, and `mc config host` are not supported.
- Non-interactive use blocks on a GPG passphrase prompt unless `gpg-agent`
  already has the key cached. For automation, prefer short-lived credentials.
- While a process runs, `mc`'s credentials are visible in `/proc/<pid>/environ`
  to the same user and to root.
- Another tool can still run the real binaries directly, bypassing the shims.

## Commands

```
s3seal enable aws
s3seal disable aws [--yes]
s3seal status
s3seal credential-process aws PROFILE   # called by the AWS CLI, not by users
```

## Environment variables

| Variable | Purpose |
| --- | --- |
| `S3SEAL_GPG_RECIPIENT` | GPG key id or email to encrypt to |
| `S3SEAL_CONFIG_DIR` | Store location (default `~/.config/s3seal`) |
| `S3SEAL_INSTALL_DIR` | Where the `mc`, `aws` and `s3seal` links go (default `~/.local/bin`) |
| `S3SEAL_SHARE_DIR` | Installed copy (default `~/.local/share/s3seal`) |
| `MC_BIN` | Absolute path to the real `mc` binary |
| `S3SEAL_NO_VERIFY` | Skip the connection check during `mc alias set` |
| `S3SEAL_LIST_ENDPOINTS` | Show endpoints in `mc alias list` (decrypts every alias) |
| `S3SEAL_DEBUG` | Always show gpg's diagnostics |
| `S3SEAL_REPO`, `S3SEAL_REF` | Install from another repository or ref (only the default ref is checksum-verified) |

## Uninstall

```bash
./uninstall.sh                 # keeps encrypted credentials
./uninstall.sh --purge         # also deletes ~/.config/s3seal, after confirmation
```

Run `s3seal disable aws` first if AWS profiles are sealed; the uninstaller
refuses otherwise, so that the AWS CLI is never left pointing at a missing tool.

## Development

```bash
tests/run.sh                        # needs bash and gpg; python3 for the prompt tests
TEST_BASH=/bin/bash tests/run.sh    # run the scripts under another bash
uvx --from shellcheck-py shellcheck mc aws s3seal install.sh uninstall.sh scripts/update-checksum.sh tests/run.sh lib/*.sh
scripts/update-checksum.sh          # after changing any installed file
```

The installed layout is `mc`, `aws` and `s3seal` entry points plus `lib/`
(`common.sh`, `ini.sh`, `aws.sh`). Each entry finds `lib/` through its symlink.

## License

MIT, see [LICENSE](LICENSE).
