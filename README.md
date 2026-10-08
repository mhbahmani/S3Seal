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

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/mhbahmani/sealedmc/master/install.sh | bash
```

The wrapper installs to `~/.local/bin/mc`.

### The real `mc` must be off your PATH

Because the wrapper takes over the name `mc`, the real binary must not also be
reachable on `PATH` — otherwise whichever directory comes first wins, and you
could silently keep using the unwrapped client.

The installer checks for this. If it finds the real `mc` on your `PATH`, it
prints the exact command to move it and exits without changing anything. The
recommended layout is:

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
ends up in your shell history. Both are URL-encoded before being stored, so
keys containing `/`, `+` or `@` work correctly. The alias is verified against
the server, then encrypted to `~/.config/sealedmc/aliases/prod.url.asc`.

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

### Everything else

Unchanged:

```bash
mc ls prod/bucket
mc cp ./file prod/bucket/
mc mirror prod/bucket dev/bucket
mc admin info prod
```

## Migrating off plaintext

1. Look at what is currently stored in the clear:

   ```bash
   grep -o '"url"[^,]*' ~/.mc/config.json
   ```

2. Re-add each alias through the wrapper with `mc alias set`.

3. Remove the plaintext entries using the **real** binary, which bypasses the
   wrapper:

   ```bash
   ~/.local/libexec/mc alias remove prod
   ```

4. Confirm nothing is left:

   ```bash
   cat ~/.mc/config.json
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
- **`mc alias import` / `export` are not supported.**
- **Non-interactive use is awkward.** cron jobs and CI will block on a
  `pinentry` prompt unless `gpg-agent` already has the key cached. Working
  around that with a passphrase file reintroduces a plaintext secret on disk —
  for automation, prefer short-lived STS credentials (see below).
- **Shell completion for `mc` is lost.**
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
| `SEALEDMC_INSTALL_DIR` | Install location (default `~/.local/bin`) |
| `SEALEDMC_LIBEXEC_DIR` | Where the real binary is expected (default `~/.local/libexec`) |

## Uninstall

```bash
./uninstall.sh            # removes the wrapper, keeps encrypted credentials
./uninstall.sh --purge    # also deletes ~/.config/sealedmc
```

## Files

```
~/.local/bin/mc                            the wrapper
~/.local/libexec/mc                        the real MinIO client
~/.config/sealedmc/recipient              GPG key id to encrypt to
~/.config/sealedmc/mc-path                path to the real binary
~/.config/sealedmc/aliases/<name>.url.asc one encrypted alias per file (0600)
```
