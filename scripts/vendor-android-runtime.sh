#!/usr/bin/env bash
set -euo pipefail

destination="${1:?Usage: scripts/vendor-android-runtime.sh <destination>}"
scrcpy_version="${SCRCPY_SERVER_VERSION:-4.1}"
official_sha256="deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae"
scrcpy_sha256="${SCRCPY_SERVER_SHA256:-$official_sha256}"
scrcpy_url="${SCRCPY_SERVER_URL:-https://github.com/Genymobile/scrcpy/releases/download/v${scrcpy_version}/scrcpy-server-v${scrcpy_version}}"

if [ "$scrcpy_version" != "4.1" ] && [ -z "${SCRCPY_SERVER_SHA256:-}" ]; then
  echo "Set SCRCPY_SERVER_SHA256 when overriding SCRCPY_SERVER_VERSION." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
download_path="${work_dir}/scrcpy-server"

echo "Downloading scrcpy server ${scrcpy_version}..."
curl --fail --location --silent --show-error "$scrcpy_url" --output "$download_path"
actual_sha256="$(shasum -a 256 "$download_path" | awk '{print $1}')"
if [ "$actual_sha256" != "$scrcpy_sha256" ]; then
  echo "scrcpy server checksum mismatch: expected ${scrcpy_sha256}, got ${actual_sha256}." >&2
  exit 1
fi

rm -rf "$destination"
mkdir -p "$destination"
install -m 0644 "$download_path" "${destination}/scrcpy-server"
printf '%s\n' "$scrcpy_version" > "${destination}/scrcpy-server.version"
printf '%s\n' "$actual_sha256" > "${destination}/scrcpy-server.sha256"
echo "Vendored Android mirror runtime: ${destination}"
