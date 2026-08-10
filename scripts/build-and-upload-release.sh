#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

official_bundle_id="com.gaojiua.StupidMirror"
official_team_id="L95PYLFT86"
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
  SIGN_IDENTITY="Developer ID Application: Gaojiua Technology (Beijing) Co., Ltd. (L95PYLFT86)"
  ENTITLEMENTS="StupidMirror.entitlements"
  VERSION="0.1.0"
  BUILD_NUMBER="1"
  NOTARY_PROFILE="notarytool-keychain-profile"
  ALLOW_UNNOTARIZED=true
  RELEASE_NAME="StupidMirror v0.1.0"
  RELEASE_NOTES="Release notes..."
  DRAFT=true
  PRERELEASE=true
  COMMIT_RELEASE=false
  PUSH_RELEASE=false
MSG
  exit 0
fi

if [ -n "${BUNDLE_ID:-}" ] && [ "$BUNDLE_ID" != "$official_bundle_id" ]; then
  echo "Public releases must use bundle ID ${official_bundle_id}; got ${BUNDLE_ID}." >&2
  exit 1
fi
if [ -n "${TEAM_ID:-}" ] && [ "$TEAM_ID" != "$official_team_id" ]; then
  echo "Public releases must use Apple Team ${official_team_id}; got ${TEAM_ID}." >&2
  exit 1
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

if [ "${ALLOW_DIRTY:-false}" != "true" ] \
  && [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo "Working tree has tracked, staged, or untracked changes. Commit them or set ALLOW_DIRTY=true." >&2
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
      | sed -n "s/.*\"\(Developer ID Application: .*(${official_team_id})\)\".*/\1/p" \
      | head -n 1
  )"
fi

if [ -z "$sign_identity" ]; then
  echo "No Developer ID Application certificate found. Set SIGN_IDENTITY explicitly." >&2
  exit 1
fi

if [[ "$sign_identity" != "Developer ID Application: "* ]] \
  || [[ "$sign_identity" != *"(${official_team_id})" ]]; then
  echo "SIGN_IDENTITY must be a Developer ID Application identity for Apple Team ${official_team_id}." >&2
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

if [ "$tag" != "v${version}" ]; then
  echo "Release tag/version mismatch: tag ${tag} must match app version v${version}." >&2
  exit 1
fi

echo "Building app..."
BUNDLE_ID="$official_bundle_id" SIGN_IDENTITY="$sign_identity" VERSION="$version" bash scripts/build-app.sh

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
  find "$tmp_app" -xattr -print0 | xargs -0 xattr -c 2>/dev/null || true
fi

assert_release_app() {
  local app="$1"
  local info_plist="${app}/Contents/Info.plist"
  local actual_bundle_id
  local actual_team_id
  local value
  local signed_entitlements="${tmp_dir}/signed-entitlements.plist"
  local signed_node_entitlements="${tmp_dir}/signed-node-entitlements.plist"
  local bundled_node="${app}/Contents/Resources/Appium/bin/node"
  local nested_binary
  local nested_team_id
  local nested_count=0

  # Verify the outer signature and sealed resources without relying on
  # codesign's deprecated --deep traversal.
  codesign --verify --strict --verbose=2 "$app"

  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  if [ "$actual_bundle_id" != "$official_bundle_id" ]; then
    echo "Release bundle ID mismatch: expected ${official_bundle_id}, got ${actual_bundle_id:-<empty>}." >&2
    exit 1
  fi

  actual_team_id="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  if [ "$actual_team_id" != "$official_team_id" ]; then
    echo "Release signing team mismatch: expected ${official_team_id}, got ${actual_team_id:-<empty>}." >&2
    exit 1
  fi

  for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
    value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$info_plist" 2>/dev/null || true)"
    if [ -z "$value" ]; then
      echo "Release Info.plist is missing a non-empty ${key}." >&2
      exit 1
    fi
  done

  for locale in en zh-Hans; do
    local strings_file="${app}/Contents/Resources/${locale}.lproj/InfoPlist.strings"
    if [ ! -s "$strings_file" ] || ! plutil -lint "$strings_file" >/dev/null; then
      echo "Release is missing a valid ${locale} InfoPlist.strings file." >&2
      exit 1
    fi
    for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
      if ! plutil -p "$strings_file" | grep -q "\"${key}\""; then
        echo "Release ${locale} InfoPlist.strings is missing ${key}." >&2
        exit 1
      fi
    done
  done

  if ! codesign -d --entitlements :- "$app" > "$signed_entitlements" 2>/dev/null; then
    echo "Could not read signed release entitlements." >&2
    exit 1
  fi
  for key in com.apple.security.device.camera com.apple.security.device.audio-input; do
    value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$signed_entitlements" 2>/dev/null || true)"
    if [ "$value" != "true" ]; then
      echo "Signed release is missing required entitlement ${key}." >&2
      exit 1
    fi
  done

  while IFS= read -r -d '' nested_binary; do
    codesign --verify --strict --verbose=2 "$nested_binary"
    nested_team_id="$(codesign -dv --verbose=4 "$nested_binary" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
    if [ "$nested_team_id" != "$official_team_id" ]; then
      echo "Nested code signing team mismatch for ${nested_binary}: expected ${official_team_id}, got ${nested_team_id:-<empty>}." >&2
      exit 1
    fi
    nested_count=$((nested_count + 1))
  done < <(
    find "${app}/Contents/Resources/Appium" -type f -print0 \
      | while IFS= read -r -d '' candidate; do
          if file -b "$candidate" | grep -q 'Mach-O'; then
            printf '%s\0' "$candidate"
          fi
        done
  )

  if [ "$nested_count" -eq 0 ] || [ ! -x "$bundled_node" ]; then
    echo "Release does not contain a signed bundled Node/Appium runtime." >&2
    exit 1
  fi

  if ! codesign -d --entitlements :- "$bundled_node" > "$signed_node_entitlements" 2>/dev/null; then
    echo "Could not read bundled Node entitlements." >&2
    exit 1
  fi
  for key in com.apple.security.cs.allow-jit com.apple.security.cs.allow-unsigned-executable-memory; do
    value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$signed_node_entitlements" 2>/dev/null || true)"
    if [ "$value" != "true" ]; then
      echo "Bundled Node is missing required runtime entitlement ${key}." >&2
      exit 1
    fi
  done

  "$bundled_node" --no-warnings -e 'const answer = new Function("return 42")(); if (answer !== 42) process.exit(1)'
}

assert_release_app "$tmp_app"

notary_zip="${tmp_dir}/${app_name}-${tag}-notary.zip"
if [ -n "$notary_profile" ]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required for notarization." >&2
    exit 1
  fi
  if [ "$sign_identity" = "-" ]; then
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
  if ! command -v syspolicy_check >/dev/null 2>&1; then
    echo "syspolicy_check is required to validate a public macOS release." >&2
    exit 1
  fi
  syspolicy_check distribution "$tmp_app"
  spctl --assess --type execute --verbose=4 "$tmp_app"
else
  if [ "${ALLOW_UNNOTARIZED:-false}" != "true" ]; then
    cat >&2 <<'MSG'
NOTARY_PROFILE is not set. Refusing to upload an unnotarized public macOS release.

Set up a notarytool profile first:
  APPLE_ID="name@example.com" \
  TEAM_ID="L95PYLFT86" \
  APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  scripts/setup-notary-profile.sh

Then release with:
  NOTARY_PROFILE=stupidmirror-notary make release-local BUMP=patch

For private/local test builds only, set ALLOW_UNNOTARIZED=true.
MSG
    exit 1
  fi
  echo "NOTARY_PROFILE is not set; ALLOW_UNNOTARIZED=true so Apple notarization is skipped."
fi

# Recheck the final app after stapling (or the explicitly allowed private,
# unnotarized path) before creating the uploaded archive.
assert_release_app "$tmp_app"

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

if git rev-parse "$tag" >/dev/null 2>&1; then
  tagged_commit="$(git rev-list -n 1 "$tag")"
  head_commit="$(git rev-parse HEAD)"
  if [ "$tagged_commit" != "$head_commit" ]; then
    echo "Release tag ${tag} points to ${tagged_commit}, not current HEAD ${head_commit}." >&2
    exit 1
  fi
else
  git tag -a "$tag" -m "Release ${tag}"
fi

if [ "$push_release" = "true" ]; then
  current_branch="$(git branch --show-current)"
  if [ -n "$current_branch" ]; then
    git push origin "$current_branch"
  fi
  git push origin "$tag"
fi

release_create_args=(
  gh release create "$tag" "$artifact_path"
  --title "$release_name"
  --notes "$release_notes"
)
if [ "${DRAFT:-false}" = "true" ]; then
  release_create_args+=(--draft)
fi
if [ "${PRERELEASE:-false}" = "true" ]; then
  release_create_args+=(--prerelease)
fi

if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release ${tag} exists. Uploading artifact with --clobber..."
  gh release upload "$tag" "$artifact_path" --clobber
else
  echo "Creating release ${tag}..."
  "${release_create_args[@]}"
fi

echo "Uploaded ${artifact_path} to GitHub Release ${tag}."
echo "Version: ${version}"
echo "Bundle ID: ${official_bundle_id}"
echo "Apple Team: ${official_team_id}"
echo "Signing identity: ${sign_identity}"
