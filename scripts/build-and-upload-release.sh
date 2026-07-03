#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tag="${1:-${TAG:-}}"
version_file="${VERSION_FILE:-VERSION}"
version="${VERSION:-$(tr -d '[:space:]' < "$version_file" 2>/dev/null || printf '0.1.0')}"
tag="${tag:-v${version}}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'MSG'
Usage:
  scripts/build-and-upload-release.sh [tag]

Examples:
  scripts/build-and-upload-release.sh v0.1.0
  make release-local
  make release-local BUMP=patch

Environment:
  BUMP=patch|minor|major|x.y.z
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
  BUNDLE_ID="com.example.StupidMirror"
  VERSION="0.1.0"
  BUILD_NUMBER="1"
  NOTARY_PROFILE="notarytool-keychain-profile"
  RELEASE_NAME="StupidMirror v0.1.0"
  RELEASE_NOTES="Release notes..."
  DRAFT=true
  PRERELEASE=true
  COMMIT_RELEASE=false
  PUSH_RELEASE=false
MSG
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required. Install it first: https://cli.github.com/" >&2
  exit 1
fi

gh auth status >/dev/null
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "No git remote named 'origin' found. Add the GitHub repo remote before uploading releases." >&2
  exit 1
fi

if [ "${ALLOW_DIRTY:-false}" != "true" ] && ! git diff --quiet; then
  echo "Working tree has uncommitted changes. Commit them or set ALLOW_DIRTY=true." >&2
  exit 1
fi

if [ "${ALLOW_DIRTY:-false}" != "true" ] && ! git diff --cached --quiet; then
  echo "Index has staged changes. Commit them or set ALLOW_DIRTY=true." >&2
  exit 1
fi

app_name="StupidMirror"
app_path="dist/${app_name}.app"
artifact_dir="dist/releases"
artifact_name="${app_name}-${tag}-macos.zip"
artifact_path="${artifact_dir}/${artifact_name}"
release_name="${RELEASE_NAME:-${app_name} ${tag}}"
release_notes="${RELEASE_NOTES:-Local macOS build for ${tag}.}"
notary_profile="${NOTARY_PROFILE:-}"
sign_identity="${SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
commit_release="${COMMIT_RELEASE:-true}"
push_release="${PUSH_RELEASE:-true}"

if [ -z "$sign_identity" ]; then
  sign_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: .*([^)]*)\)".*/\1/p' \
      | head -n 1
  )"
fi

if [ -z "$sign_identity" ]; then
  echo "No Developer ID Application certificate found. Set SIGN_IDENTITY explicitly." >&2
  exit 1
fi

if [ -n "${BUMP:-}" ]; then
  version="$(bash scripts/bump-version.sh "$BUMP")"
  tag="v${version}"
  artifact_name="${app_name}-${tag}-macos.zip"
  artifact_path="${artifact_dir}/${artifact_name}"
  release_name="${RELEASE_NAME:-${app_name} ${tag}}"
  release_notes="${RELEASE_NOTES:-Local macOS build for ${tag}.}"
fi

echo "Building app..."
SIGN_IDENTITY="$sign_identity" VERSION="$version" bash scripts/build-app.sh

if [ ! -d "$app_path" ]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

tmp_app="${tmp_dir}/${app_name}.app"
if command -v ditto >/dev/null 2>&1; then
  ditto --norsrc "$app_path" "$tmp_app"
else
  cp -R "$app_path" "$tmp_app"
fi

if command -v xattr >/dev/null 2>&1; then
  find "$tmp_app" -exec xattr -c {} \; 2>/dev/null || true
  xattr -c "$tmp_app" 2>/dev/null || true
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=2 "$tmp_app"
fi

notary_zip="${tmp_dir}/${app_name}-${tag}-notary.zip"
if [ -n "$notary_profile" ]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required for notarization." >&2
    exit 1
  fi
  if [ "${SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}" = "-" ]; then
    echo "NOTARY_PROFILE requires a real Developer ID SIGN_IDENTITY, not ad-hoc signing." >&2
    exit 1
  fi

  echo "Creating notarization upload archive..."
  (
    cd "$tmp_dir"
    ditto -c -k --norsrc --keepParent "${app_name}.app" "$notary_zip"
  )

  echo "Submitting to Apple notarization service..."
  xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$tmp_app"
  xcrun stapler validate "$tmp_app"
else
  echo "NOTARY_PROFILE is not set; skipping Apple notarization."
fi

mkdir -p "$artifact_dir"
rm -f "$artifact_path"
echo "Creating ${artifact_path}..."
if command -v ditto >/dev/null 2>&1; then
  (
    cd "$tmp_dir"
    ditto -c -k --norsrc --keepParent "${app_name}.app" "${repo_root}/${artifact_path}"
  )
else
  (
    cd "$tmp_dir"
    zip -qry "${repo_root}/${artifact_path}" "${app_name}.app"
  )
fi

if [ "$commit_release" = "true" ] && [ -n "${BUMP:-}" ]; then
  git add "$version_file"
  git commit -m "Release ${tag}"
fi

if ! git rev-parse "$tag" >/dev/null 2>&1; then
  git tag -a "$tag" -m "Release ${tag}"
fi

if [ "$push_release" = "true" ]; then
  current_branch="$(git branch --show-current)"
  if [ -n "$current_branch" ]; then
    git push origin "$current_branch"
  fi
  git push origin "$tag"
fi

release_flags=()
if [ "${DRAFT:-false}" = "true" ]; then
  release_flags+=(--draft)
fi
if [ "${PRERELEASE:-false}" = "true" ]; then
  release_flags+=(--prerelease)
fi

if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release ${tag} exists. Uploading artifact with --clobber..."
  gh release upload "$tag" "$artifact_path" --clobber
else
  echo "Creating release ${tag}..."
  gh release create "$tag" "$artifact_path" \
    --title "$release_name" \
    --notes "$release_notes" \
    "${release_flags[@]}"
fi

echo "Uploaded ${artifact_path} to GitHub Release ${tag}."
echo "Version: ${version}"
echo "Signing identity: ${sign_identity}"
