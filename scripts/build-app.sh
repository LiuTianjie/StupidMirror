#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configuration="${CONFIGURATION:-release}"
app_name="${APP_NAME:-StupidMirror}"
product_name="${PRODUCT_NAME:-StupidMirrorApp}"
official_bundle_id="com.gaojiua.StupidMirror"
bundle_id="${BUNDLE_ID:-$official_bundle_id}"
version_file="${VERSION_FILE:-VERSION}"
version="${VERSION:-$(tr -d '[:space:]' < "$version_file" 2>/dev/null || printf '0.1.0')}"
build_number="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
sign_identity="${SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
entitlements="${ENTITLEMENTS:-StupidMirror.entitlements}"
node_entitlements="${NODE_ENTITLEMENTS:-NodeRuntime.entitlements}"
skip_codesign="${SKIP_CODESIGN:-false}"
bundle_appium="${BUNDLE_APPIUM:-true}"
default_appium_url="${DEFAULT_APPIUM_URL:-http://127.0.0.1:4723}"
default_control_bundle_id="${DEFAULT_CONTROL_BUNDLE_ID:-com.apple.Preferences}"
default_xcode_org_id="${DEFAULT_XCODE_ORG_ID:-${STUPIDMIRROR_XCODE_ORG_ID:-}}"
default_xcode_signing_id="${DEFAULT_XCODE_SIGNING_ID:-${STUPIDMIRROR_XCODE_SIGNING_ID:-Apple Development}}"
default_wda_bundle_id="${DEFAULT_WDA_BUNDLE_ID:-${STUPIDMIRROR_WDA_BUNDLE_ID:-}}"
default_use_prebuilt_wda="${DEFAULT_USE_PREBUILT_WDA:-false}"
app_path="dist/${app_name}.app"
build_app_path="${TMPDIR:-/tmp}/${app_name}.app"
contents_path="${app_path}/Contents"
macos_path="${contents_path}/MacOS"
icon_path="${ICON_PATH:-Assets/AppIcon.icns}"

echo "Building ${product_name} (${configuration})..."
swift build -c "$configuration" --product "$product_name"

bin_path="$(swift build -c "$configuration" --show-bin-path)/${product_name}"
if [ ! -x "$bin_path" ]; then
  echo "Built binary not found: $bin_path" >&2
  exit 1
fi

rm -rf "$app_path" "$build_app_path"
contents_path="${build_app_path}/Contents"
macos_path="${contents_path}/MacOS"
mkdir -p "$macos_path"
cp "$bin_path" "${macos_path}/${app_name}"
if [ -f "$icon_path" ]; then
  mkdir -p "${contents_path}/Resources"
  cp "$icon_path" "${contents_path}/Resources/AppIcon.icns"
fi
if [ "$bundle_appium" = "true" ]; then
  mkdir -p "${contents_path}/Resources"
  bash scripts/vendor-appium-runtime.sh "${contents_path}/Resources/Appium"
fi

cat > "${contents_path}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${app_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${build_number}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>StupidMirror uses camera access to receive the video track of an iPhone connected over USB. It does not capture the Mac camera.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>StupidMirror uses microphone access to receive the optional audio track of an iPhone connected over USB.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>StupidMirrorDefaultAppiumServerURL</key>
  <string>${default_appium_url}</string>
  <key>StupidMirrorDefaultControlBundleID</key>
  <string>${default_control_bundle_id}</string>
  <key>StupidMirrorDefaultXcodeOrgID</key>
  <string>${default_xcode_org_id}</string>
  <key>StupidMirrorDefaultXcodeSigningID</key>
  <string>${default_xcode_signing_id}</string>
  <key>StupidMirrorDefaultWDABundleID</key>
  <string>${default_wda_bundle_id}</string>
  <key>StupidMirrorDefaultUsePrebuiltWDA</key>
  <${default_use_prebuilt_wda}/>
</dict>
</plist>
PLIST

resources_path="${contents_path}/Resources"
mkdir -p "${resources_path}/en.lproj" "${resources_path}/zh-Hans.lproj"
cat > "${resources_path}/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "StupidMirror uses camera access to receive the video track of an iPhone connected over USB. It does not capture the Mac camera.";
"NSMicrophoneUsageDescription" = "StupidMirror uses microphone access to receive the optional audio track of an iPhone connected over USB.";
STRINGS
cat > "${resources_path}/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "StupidMirror 使用相机权限接收通过 USB 连接的 iPhone 视频画面，不会采集 Mac 摄像头。";
"NSMicrophoneUsageDescription" = "StupidMirror 使用麦克风权限接收通过 USB 连接的 iPhone 可选音轨。";
STRINGS

assert_nonempty_plist_value() {
  local plist="$1"
  local key="$2"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    echo "Required Info.plist value is missing or empty: ${key}" >&2
    exit 1
  fi
}

assert_true_entitlement() {
  local plist="$1"
  local key="$2"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true)"
  if [ "$value" != "true" ]; then
    echo "Required capture entitlement is missing or false: ${key}" >&2
    exit 1
  fi
}

assert_nonempty_plist_value "${contents_path}/Info.plist" CFBundleIdentifier
assert_nonempty_plist_value "${contents_path}/Info.plist" NSCameraUsageDescription
assert_nonempty_plist_value "${contents_path}/Info.plist" NSMicrophoneUsageDescription

if [ "$skip_codesign" != "true" ] && command -v codesign >/dev/null 2>&1; then
  if [ -z "$entitlements" ] || [ ! -f "$entitlements" ]; then
    echo "Entitlements file not found: ${entitlements:-<empty>}" >&2
    exit 1
  fi
  assert_true_entitlement "$entitlements" com.apple.security.device.camera
  assert_true_entitlement "$entitlements" com.apple.security.device.audio-input
  if [ "$bundle_appium" = "true" ]; then
    if [ ! -f "$node_entitlements" ]; then
      echo "Node runtime entitlements file not found: ${node_entitlements}" >&2
      exit 1
    fi
    assert_true_entitlement "$node_entitlements" com.apple.security.cs.allow-jit
    assert_true_entitlement "$node_entitlements" com.apple.security.cs.allow-unsigned-executable-memory
  fi

  strip_and_sign() {
    if command -v xattr >/dev/null 2>&1; then
      find "$build_app_path" -xattr -print0 | xargs -0 xattr -c 2>/dev/null || true
    fi
    nested_sign_args=(--force --sign "$sign_identity")
    app_sign_args=(--force --sign "$sign_identity")
    if [ "$sign_identity" != "-" ]; then
      nested_sign_args+=(--timestamp --options runtime)
      app_sign_args+=(--timestamp --options runtime)
    fi

    if [ "$bundle_appium" = "true" ]; then
      while IFS= read -r -d '' nested_binary; do
        nested_args=("${nested_sign_args[@]}")
        if [ "$nested_binary" = "${contents_path}/Resources/Appium/bin/node" ]; then
          nested_args+=(--entitlements "$node_entitlements")
        fi
        codesign "${nested_args[@]}" "$nested_binary" || return 1
      done < <(
        find "${contents_path}/Resources/Appium" -type f -print0 \
          | while IFS= read -r -d '' candidate; do
              if file -b "$candidate" | grep -q 'Mach-O'; then
                printf '%s\0' "$candidate"
              fi
            done
      )
    fi

    app_sign_args+=(--entitlements "$entitlements")
    codesign "${app_sign_args[@]}" "$build_app_path" || return 1

    if [ "$bundle_appium" = "true" ]; then
      while IFS= read -r -d '' nested_binary; do
        codesign --verify --strict --verbose=2 "$nested_binary" >/dev/null || return 1
      done < <(
        find "${contents_path}/Resources/Appium" -type f -print0 \
          | while IFS= read -r -d '' candidate; do
              if file -b "$candidate" | grep -q 'Mach-O'; then
                printf '%s\0' "$candidate"
              fi
            done
      )
    fi
    # Verifies the main signature and the bundle's sealed resources without
    # asking codesign to recursively infer how nested code should be signed.
    codesign --verify --strict --verbose=2 "$build_app_path" >/dev/null || return 1
  }
  strip_and_sign || strip_and_sign || strip_and_sign || {
    echo "codesign failed after retries." >&2
    exit 1
  }
fi

mkdir -p dist
if command -v ditto >/dev/null 2>&1; then
  ditto --norsrc "$build_app_path" "$app_path"
else
  cp -R "$build_app_path" "$app_path"
fi

if command -v xattr >/dev/null 2>&1; then
  find "$app_path" -xattr -print0 | xargs -0 xattr -c 2>/dev/null || true
fi

echo "Wrote ${app_path}"
