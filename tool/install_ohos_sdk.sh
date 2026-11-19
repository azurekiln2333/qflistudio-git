#!/usr/bin/env bash
# Download, verify and unpack the OpenHarmony SDK for Linux hosts.
#
# Usage: tool/install_ohos_sdk.sh --url <https url> --sha256 <hex> --destination <new dir>
#
# The official public archive bundles one ZIP per host and component. This script
# extracts only the Linux native package and verifies its toolchain layout.
set -euo pipefail

url=''
sha256=''
destination=''

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'install_ohos_sdk: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) url="${2:-}"; shift 2 ;;
    --sha256) sha256="${2:-}"; shift 2 ;;
    --destination) destination="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$url" ]] || fail 'missing --url'
[[ -n "$sha256" ]] || fail 'missing --sha256'
[[ -n "$destination" ]] || fail 'missing --destination'
[[ "$sha256" =~ ^[0-9a-fA-F]{64}$ ]] || fail 'SHA-256 must contain 64 hexadecimal characters'
[[ "$url" == https://* ]] || fail 'download URL must use HTTPS'
[[ ! -e "$destination" ]] || fail 'destination must be new'

command -v curl >/dev/null || fail 'curl is required'
command -v tar >/dev/null || fail 'tar is required'
command -v unzip >/dev/null || fail 'unzip is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'

mkdir -p "$destination"
archive="$destination/sdk-download.tar.gz"
curl --fail --location --retry 3 --retry-delay 5 --output "$archive" "$url" \
  || fail 'SDK download failed'

expected=$(printf '%s' "$sha256" | tr '[:upper:]' '[:lower:]')
actual=$(sha256sum "$archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || fail "archive SHA-256 mismatch: $actual"

listing="$destination/sdk-listing.txt"
tar -tf "$archive" >"$listing" || fail 'cannot list SDK archive'

# The public archive holds separate ZIP packages per host and component.
mapfile -t packages < <(grep -Ei '^(.*/)?(linux[^/]*native|native[^/]*linux)[^/]*\.zip$' "$listing" || true)
((${#packages[@]} <= 1)) || fail 'archive contains multiple Linux native packages'

extract="$destination/extracted"
mkdir -p "$extract"
if ((${#packages[@]} == 1)); then
  tar -xf "$archive" -C "$extract" "${packages[0]}" || fail 'cannot extract Linux native package'
  package="$extract/${packages[0]}"
  unzip -q -o "$package" -d "$destination/native-package" || fail 'cannot unzip Linux native package'
else
  # Also accept a checksum-pinned archive of the native SDK directory itself.
  tar -xf "$archive" -C "$extract" || fail 'cannot extract SDK archive'
  cp -a "$extract/." "$destination/native-package"
fi

mapfile -t compilers < <(find "$destination/native-package" -type f -path '*/native/llvm/bin/clang' -print)
((${#compilers[@]} == 1)) || fail 'SDK must contain exactly one native/llvm/bin/clang'
sdk=$(dirname "$(dirname "$(dirname "$(dirname "${compilers[0]}")")")")

for relative in native/sysroot native/llvm/bin/llvm-strip native/llvm/bin/llvm-readelf native/llvm/bin/llvm-nm; do
  [[ -e "$sdk/$relative" ]] || fail "missing SDK component: $relative"
done

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'OHOS_SDK_HOME=%s\n' "$sdk" >>"$GITHUB_ENV"
fi
printf 'OHOS SDK ready: %s\n' "$sdk"