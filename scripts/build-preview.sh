#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$repo_root/.build/smpreview"
mkdir -p "$output"
for arch in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go -C "$repo_root/tools/smpreview" build -trimpath -ldflags '-s -w' -o "$output/smpreview-$arch" .
done
lipo -create -output "$output/smpreview" "$output/smpreview-arm64" "$output/smpreview-amd64"
rm "$output/smpreview-arm64" "$output/smpreview-amd64"
if [ -n "${1:-}" ]; then cp "$output/smpreview" "$1"; fi
