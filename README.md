# Sealed MinIO Client

`sealedmc` is a drop-in wrapper around the [MinIO client](https://min.io/docs/minio/linux/reference/minio-mc.html)
(`mc`) that keeps credentials in per-alias GPG-encrypted files instead of
plaintext in `~/.mc/config.json`.

By default, `mc alias set` writes your access key and secret key to
`~/.mc/config.json` in the clear. Anything that can read your home directory —
a backup, a synced folder, a misbehaving dependency, a stolen laptop with an
unencrypted disk — gets your object storage credentials.

`sealedmc` encrypts each alias to one of your GPG keys and decrypts it into
the environment of a single `mc` process, only when a command actually
references that alias.

- Credentials are never written to disk unencrypted.
- Credentials are never passed in `argv`, so they do not appear in `ps`.
- Credentials are never typed as command arguments, so they do not land in
  shell history.
- Every other `mc` command works exactly as before.

## How it works

`mc` reads an alias from the environment variable `MC_HOST_<alias>`, which
takes precedence over the config file:

```
MC_HOST_prod='https://ACCESSKEY:SECRETKEY@minio.example.com'
```

`sealedmc` installs itself as `mc` on your `PATH`. On every invocation it
scans the arguments, decrypts only the aliases that command mentions, exports
them as `MC_HOST_*`, and then `exec`s the real `mc` binary.

```
mc cp prod/bucket/x dev/bucket/     ->  decrypts "prod" and "dev", exports both,
                                        execs the real mc
```

## Requirements

- `bash` 4+ (or macOS `bash` 3.2)
- `gpg` with a key pair of your own (`gpg --full-generate-key`)
- the real MinIO client binary — `sealedmc` wraps yours, it does not bundle one
  (installed as `mc`, or as `mcli` on some distributions)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/mhbahmani/sealedmc/master/install.sh | bash
```

The wrapper installs to `~/.local/bin/mc`. The installer checks the
downloaded wrapper against the SHA-256 embedded in `install.sh`, and refuses
to install on a mismatch.

### The real `mc` must be off your PATH

Because the wrapper takes over the name `mc`, the real binary must not also be
reachable on `PATH` — otherwise whichever directory comes first wins, and you
could silently keep using the unwrapped client.

The installer checks for this. If it finds the real `mc` on your `PATH`, it
prints the exact command to move it and exits without changing anything. An
`mc` that is not the MinIO client (on many Linux distributions `/usr/bin/mc`
is Midnight Commander) is left alone, with a warning that the wrapper will
shadow it. The recommended layout is:

```
~/.local/bin/mc        <- this wrapper (on PATH)
~/.local/libexec/mc    <- the real MinIO client (off PATH)
```

So a first-time install usually looks like:

```bash
mkdir -p ~/.local/libexec
sudo mv /usr/local/bin/mc ~/.local/libexec/mc
sudo chown "$(id -un)" ~/.local/libexec/mc
```

Then re-run the install command. The installer records the real binary's path
in `~/.config/sealedmc/mc-path`.

### PATH

If `~/.local/bin` is not on your `PATH`, add this to `~/.zshrc` or `~/.bashrc`
and start a new shell:

```bash
export PATH=$PATH:$HOME/.local/bin
```

The installer tells you if this step is needed.

### GPG recipient

Tell `sealedmc` which key to encrypt to, once:

```bash
echo 'you@example.com' > ~/.config/sealedmc/recipient
```

Or set `SEALEDMC_GPG_RECIPIENT` in your environment.

### Verify

```bash
command -v mc            # should print ~/.local/bin/mc
mc --sealedmc-version
```

## Usage

### Store an alias

```bash
mc alias set prod https://minio.example.com
```

You are prompted for the access key and secret key on the terminal, so neither
ends up in your shell history. The alias is verified against the server, then
encrypted to `~/.config/sealedmc/aliases/prod.url.asc`.

Keys are stored verbatim, because `mc` does not percent-decode `MC_HOST_`
values. Characters such as `/`, `+` and `@` work; a `:` in either key does not
(mc would read it as a session token) and is rejected.

Global flags work in any position, e.g. `mc --insecure alias set ...` for a
self-signed endpoint; `--insecure` is applied to the verification step.

Non-interactive form (avoid it — the keys land in your history):

```bash
mc alias set prod https://minio.example.com ACCESSKEY SECRETKEY
```

### List and remove

```bash
mc alias list
mc alias remove prod
```

Set `SEALEDMC_LIST_ENDPOINTS=1` to also show each alias's endpoint (this
decrypts every stored alias, so expect a GPG prompt).

`mc alias list` also warns if `mc`'s own config still holds plaintext
credentials (the public `play` demo alias and mc's placeholder entries are
ignored).

### Everything else

Unchanged:

```bash
mc ls prod/bucket
mc cp ./file prod/bucket/
mc mirror prod/bucket dev/bucket
mc admin info prod
```

### Shell completion

Run `mc --autocompletion` once, as with the plain client. `mc` registers the
real binary as the completer, so completion never sees credentials. If you
point completion at the wrapper instead (`complete -C ~/.local/bin/mc mc`), it
hands straight over to the real `mc` without decrypting anything.

## Migrating off plaintext

```bash
mc alias migrate          # every alias in ~/.mc/config.json
mc alias migrate prod     # or only the ones named
```

Each alias is encrypted into the store and then removed from `mc`'s config.
Aliases that cannot be expressed as `MC_HOST_` are skipped with a reason and
left untouched: names that are not shell identifiers (re-add them under a new
name with `mc alias set`), `--api S3v2` or non-`auto` `--path`, and URLs with a
path. Existing encrypted aliases are never overwritten. The command exits
non-zero if anything was skipped.

Afterwards, tighten permissions on what is left:

```bash
chmod 700 ~/.mc && chmod 600 ~/.mc/config.json
```

`mc` still uses `~/.mc/` for non-credential state such as resumable `mirror`
sessions, so do not delete the directory.

## Limitations

These are consequences of how `mc` reads environment variables, not bugs that
can be worked around in the wrapper.

- **Alias names must be valid shell identifiers.** `MC_HOST_<alias>` has to be
  a legal environment variable name, so `my-minio` and `prod.s3` cannot work.
  Use `my_minio`. The wrapper rejects invalid names at `mc alias set` time
  rather than failing cryptically later.
- **`--api` and `--path` are not supported.** `MC_HOST_` carries a URL and
  nothing else. If you need path-style addressing or a pinned signature
  version, that alias has to stay in `config.json`.
- **`mc alias import` / `export` and the legacy `mc config host` are not
  supported.**
- **Non-interactive use is awkward.** cron jobs and CI will block on a
  `pinentry` prompt unless `gpg-agent` already has the key cached. Working
  around that with a passphrase file reintroduces a plaintext secret on disk —
  for automation, prefer short-lived STS credentials (see below).
- **Remote completion is unavailable.** Completion runs without credentials,
  so bucket and object names on encrypted aliases are not completed.
- **The client can still be run directly.** Anything that invokes the real
  binary by path (or `mcli`, if it is on `PATH`) bypasses the wrapper.
- **The secret is briefly in one process's environment.** While the `mc`
  process runs, its credentials are readable via `/proc/<pid>/environ` by that
  same user and by root. This is strictly better than a file at rest, but it is
  not airtight.

## What this does not solve

The underlying problem is long-lived static keys. If your MinIO deployment has
an identity provider (OIDC or LDAP) or supports `AssumeRole`, short-lived STS
credentials are a better answer: they expire on their own, and nothing durable
ever touches your disk. `sealedmc` is for the common case where static keys
are what you have.

## Environment variables

| Variable | Purpose |
| --- | --- |
| `MC_BIN` | Absolute path to the real `mc` binary (overrides everything else) |
| `SEALEDMC_CONFIG_DIR` | Config and credential store (default `~/.config/sealedmc`) |
| `SEALEDMC_GPG_RECIPIENT` | GPG key id or email to encrypt to |
| `SEALEDMC_NO_VERIFY` | Skip the connection check during `mc alias set` |
| `SEALEDMC_LIST_ENDPOINTS` | Show endpoints in `mc alias list` |
| `SEALEDMC_DEBUG` | Always show gpg's diagnostics (otherwise only on failure) |
| `SEALEDMC_INSTALL_DIR` | Install location (default `~/.local/bin`) |
| `SEALEDMC_LIBEXEC_DIR` | Where the real binary is expected (default `~/.local/libexec`) |
| `SEALEDMC_REPO`, `SEALEDMC_REF` | Install from another repository or ref (default `mhbahmani/sealedmc`, `master`) |
| `SEALEDMC_SHA256` | Expected checksum of the wrapper when installing a non-default ref |

## Uninstall

```bash
./uninstall.sh            # removes the wrapper, keeps encrypted credentials
./uninstall.sh --purge    # also deletes ~/.config/sealedmc, after confirmation
./uninstall.sh --purge --yes   # without asking
```

## Files

```
~/.local/bin/mc                            the wrapper
~/.local/libexec/mc                        the real MinIO client
~/.config/sealedmc/recipient              GPG key id to encrypt to
~/.config/sealedmc/mc-path                path to the real binary
~/.config/sealedmc/aliases/<name>.url.asc one encrypted alias per file (0600)
```

## Development

```bash
tests/run.sh                        # needs bash and gpg; python3 for the prompt test
TEST_BASH=/bin/bash tests/run.sh    # run the scripts under another bash (e.g. 3.2)
shellcheck mc install.sh uninstall.sh scripts/*.sh tests/run.sh
```

After changing `mc`, run `scripts/update-checksum.sh` so that `install.sh`
expects the new wrapper; the test suite fails until you do.

## License

MIT, see [LICENSE](LICENSE).
