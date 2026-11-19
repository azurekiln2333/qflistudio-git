# Upstream sources

`versions.json` pins every upstream package. `tool/fetch_sources.py` downloads each
package into `native/build/downloads/`, verifies the SHA-256, then unpacks it into
`native/build/src/<directory>/`.

Nothing under `native/build/` is committed.

## Packages

| Upstream | Version | Download | License |
|---|---|---|---|
| libgit2 | 1.9.7 | GitHub tag archive `v1.9.7` | GPL-2.0-only with linking exception |
| Mbed TLS | 3.6.8 (3.6 LTS) | GitHub release `mbedtls-3.6.8` asset | Apache-2.0 |
| Mozilla CA bundle | 2026-11-05 | `https://curl.se/ca/cacert-2026-11-05.pem` | MPL-2.0 |

libgit2 is used as a static library linked into `libqfli_git.so` and
`qfli_git.framework`. The libgit2 linking exception allows that combination
with this project's GPL-3.0-or-later license. The full license texts sit in
`third_party/licenses/` (`libgit2.txt`, `mbedtls.txt`, `cacert.txt`), and CI
copies them into every artifact.

The CA bundle is copied to `assets/cacert.pem` and shipped inside the Flutter
plugin, so Android and OpenHarmony do not read the system trust store.

## Patches

There are no patches. All three packages build from the unmodified release
archive.

## Updating a version

1. Change the version, URL, archive name and directory in `versions.json`.
2. Download the new archive and compute its SHA-256.
3. Write the new SHA-256 into `versions.json`.
4. Run `python tool/fetch_sources.py --update-assets`.
5. Rebuild with `tool/build_native.sh` and rerun the smoke test.

For the CA bundle, take the dated file from `https://curl.se/ca/`. Do not use
`cacert.pem` itself as the download URL, because that file changes without
changing the URL.
