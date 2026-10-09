# Changelog

## Unreleased

### Added

- `mc alias export ALIAS` prints an alias as JSON, secret key included, as mc does.
- `mc alias import ALIAS [FILE]` reads that JSON from a file or stdin, validates it,
  and stores it encrypted. An existing alias with the same name is replaced.
- Other `mc alias` subcommands pass through to the real `mc`.
- Alias names may contain `-` and `.`, as in mc.

### Changed

- The installer installs the newest release by default, and `--dev` installs `master`.
  It names the version it installs.
- `s3seal enable` no longer repeats the PATH note for each client. The installer
  prints one note at the end, with the `export PATH` line for your shell.
- `mc alias list` shows each sealed alias's host, and the columns line up.
- The plaintext-credentials notice is a short block with a suggested command.

## 1.2.0

### Added

- `s3seal enable|disable mc` work like `aws`: each asks before moving credentials,
  and `s3seal migrate <client> [--to plain]` does the migration later.
- `s3seal enable aws`, `disable aws` and `status`. AWS profiles keep their keys
  encrypted and are fetched through `credential_process`.
- An `aws` shim handles `aws configure` (interactive, and set/get of key fields)
  and `aws configure import`. Other commands run the real CLI.
- An interactive installer: it asks which clients to protect, where to install,
  creates or reuses the encryption key, and moves official clients out of `PATH`
  only with your consent.
- The encryption key lives in its own GPG home (`~/.config/s3seal/gnupg`), with
  a passphrase cache of 5 minutes.
- `s3seal upgrade [--check] [--force]`, which upgrades an installed copy.
- Aliases with dashes in their names, and skipped aliases reported as warnings.

### Changed

- Everything installs into one folder (default `~/.local/share/s3seal`): program
  files in `libexec/`, and enabled commands linked into `bin/`.
- Running the installer again reports whether s3seal is fresh, up to date,
  refreshed, or upgraded.
- The project is named s3seal (formerly sealedmc). The store is `~/.config/s3seal`,
  and environment variables use `S3SEAL_`.

## 1.1.0

### Fixed

- Access and secret keys are stored verbatim. mc does not percent-decode `MC_HOST_`
  values, so 1.0.0's URL encoding broke keys containing `/`, `+` or `@`. **If you
  stored such an alias with 1.0.0, run `mc alias set` for it again.**
- `mc --insecure alias set ...` (any global flag before `alias`) is handled by the
  wrapper instead of being passed to mc, which wrote the keys in plaintext.
- A failed decryption aborts instead of running mc with an empty alias.
- Aliases after `--` (for example `mc rm -- prod/bucket/x`) are decrypted.
- Midnight Commander is no longer mistaken for the MinIO client.
- `mc alias remove` validates the alias name.

### Added

- `mc alias migrate` moves aliases out of mc's plaintext config.
- `mc alias list` warns when mc's config still holds plaintext credentials.
- Shell completion pointed at the wrapper never decrypts anything.
- Support for the client installed as `mcli`.
- The installer verifies the downloaded wrapper's SHA-256.
- `uninstall.sh --purge` asks for confirmation (`--yes` to skip).
- GPG diagnostics are shown when encryption or decryption fails; `S3SEAL_DEBUG=1`
  always shows them.
- Test suite, shellcheck and CI on Linux and macOS.

## 1.0.0

- Initial release.
