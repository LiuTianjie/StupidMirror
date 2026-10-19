#!/usr/bin/env bash
# Downloads Sparkle's release tools (generate_keys, sign_update) once and
# prints their directory. Pinned to the framework version in Package.swift.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="2.10.0"
sha256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
root="${SPARKLE_TOOLS_DIR:-${repo_root}/.build/sparkle-tools}"
directory="${root}/${version}"

if [ ! -x "${directory}/bin/sign_update" ]; then
  mkdir -p "$root"
  archive="${root}/Sparkle-${version}.tar.xz"
  curl -fsSL -o "$archive" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [ "$actual" != "$sha256" ]; then
    echo "Sparkle ${version} tools checksum mismatch: ${actual}" >&2
    rm -f "$archive"
    exit 1
  fi
  rm -rf "$directory"
  mkdir -p "$directory"
  tar -xf "$archive" -C "$directory"
fi
printf '%s\n' "$directory"
