#!/usr/bin/env bash
# Builds the smtunnel sidecar (tools/smtunnel) as a universal macOS binary.
#
# Usage: scripts/build-smtunnel.sh [destination directory]
#   Without a destination the binary lands in .build/smtunnel/smtunnel, which
#   is where a `swift run` development build looks for it. With a destination
#   (the app bundle's Resources/smtunnel) the binary is copied there as well.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${repo_root}/tools/smtunnel"
cache_dir="${SMTUNNEL_CACHE:-${repo_root}/.build/smtunnel}"
destination="${1:-}"

go_bin="${GO_BINARY:-$(command -v go || true)}"
if [ -z "$go_bin" ] || [ ! -x "$go_bin" ]; then
  echo "Go is required to build the smtunnel sidecar (brew install go)." >&2
  exit 1
fi

version="$(LC_ALL=C grep -m1 -E '^## [0-9]' "${repo_root}/CHANGELOG.md" | awk '{print $2}' || true)"
version="${SMTUNNEL_VERSION:-${version:-dev}}"

mkdir -p "$cache_dir"
ldflags="-s -w -X main.version=${version}"

build_arch() {
  local arch="$1"
  (
    cd "$source_dir"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" "$go_bin" build -trimpath -ldflags "$ldflags" \
      -o "${cache_dir}/smtunnel-${arch}" .
  )
}

build_arch arm64
build_arch amd64
lipo -create -output "${cache_dir}/smtunnel" "${cache_dir}/smtunnel-arm64" "${cache_dir}/smtunnel-amd64"
rm -f "${cache_dir}/smtunnel-arm64" "${cache_dir}/smtunnel-amd64"
chmod 755 "${cache_dir}/smtunnel"

if [ -n "$destination" ]; then
  mkdir -p "$destination"
  cp "${cache_dir}/smtunnel" "${destination}/smtunnel"
  chmod 755 "${destination}/smtunnel"
fi

echo "smtunnel ${version} -> ${cache_dir}/smtunnel"
