# Changelog

## Unreleased

### Renamed

- The project is now s3seal (was sealedmc). Store path is `~/.config/s3seal`,
  environment variables use `S3SEAL_`. Credentials stored under sealedmc's
  path are not migrated automatically.

### Added

- `s3seal enable aws` / `disable aws` / `status`: AWS profiles keep their keys
  encrypted and are fetched through `credential_process`.
- An `aws` shim handles `aws configure` (interactive and set/get of key
  fields) and `aws configure import`; every other command runs the real CLI.
- `lib/` with shared helpers, a minimal INI editor, and the AWS support.
- Installed files are verified one by one against checksums.

### Changed

- `uninstall.sh` refuses while AWS profiles are sealed.
- The installer no longer touches the AWS CLI; it installs the commands only.

## 1.1.0

### Fixed

- Access and secret keys are now stored verbatim. mc does not percent-decode
  `MC_HOST_` values, so 1.0.0's URL-encoding broke any key containing
  characters such as `/`, `+` or `@`. **If you stored such an alias with
  1.0.0, run `mc alias set` for it again.**
- `mc --insecure alias set ...` (any global flag before `alias`) is now
  handled by the wrapper instead of being forwarded to mc, which wrote the
  keys to `~/.mc/config.json` in plaintext. The legacy `mc config host` is
  blocked for the same reason.
- A failed decryption now aborts instead of running mc with an empty alias.
- Aliases after `--` (e.g. `mc rm -- prod/bucket/x`) are now decrypted.
- Midnight Commander (`/usr/bin/mc` on many distributions) is no longer
  mistaken for the MinIO client.
- `mc alias remove` validates the alias name.

### Added

- `mc alias migrate [NAME...]` moves aliases out of mc's plaintext config.
- `mc alias list` warns when mc's config still holds plaintext credentials.
- Shell completion pointed at the wrapper never decrypts anything.
- Support for the client installed as `mcli`.
- The installer verifies the downloaded wrapper's SHA-256.
- `uninstall.sh --purge` asks for confirmation (`--yes` to skip).
- gpg diagnostics are shown when encryption or decryption fails;
  `S3SEAL_DEBUG=1` always shows them.
- Test suite, shellcheck and CI on Linux and macOS.

## 1.0.0

- Initial release.
