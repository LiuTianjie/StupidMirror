#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

part="${1:-${BUMP:-patch}}"
version_file="${VERSION_FILE:-VERSION}"

if [ ! -f "$version_file" ]; then
  echo "Version file not found: $version_file" >&2
  exit 1
fi

current="$(tr -d '[:space:]' < "$version_file")"
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Unsupported version format in $version_file: $current" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$part" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
  [0-9]*.[0-9]*.[0-9]*)
    new_version="$part"
    ;;
  *)
    echo "Usage: scripts/bump-version.sh [major|minor|patch|x.y.z]" >&2
    exit 2
    ;;
esac

new_version="${new_version:-${major}.${minor}.${patch}}"
printf '%s\n' "$new_version" > "$version_file"
echo "$new_version"
