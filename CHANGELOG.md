# Changelog

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
  `SEALEDMC_DEBUG=1` always shows them.
- Test suite, shellcheck and CI on Linux and macOS.

## 1.0.0

- Initial release.
