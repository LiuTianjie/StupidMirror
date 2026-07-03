#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configuration="${CONFIGURATION:-release}"
app_name="${APP_NAME:-StupidMirror}"
product_name="${PRODUCT_NAME:-StupidMirrorApp}"
bundle_id="${BUNDLE_ID:-dev.stupidmirror.app}"
version_file="${VERSION_FILE:-VERSION}"
version="${VERSION:-$(tr -d '[:space:]' < "$version_file" 2>/dev/null || printf '0.1.0')}"
build_number="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
sign_identity="${SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
entitlements="${ENTITLEMENTS:-}"
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
  <string>StupidMirror uses AVFoundation camera capture APIs to read the USB iPhone screen source exposed by macOS.</string>
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

if [ "$skip_codesign" != "true" ] && command -v codesign >/dev/null 2>&1; then
  strip_and_sign() {
    if command -v xattr >/dev/null 2>&1; then
      find "$build_app_path" -xattr -print0 | xargs -0 xattr -c 2>/dev/null || true
    fi
    sign_args=(--force --deep --sign "$sign_identity")
    if [ "$sign_identity" != "-" ]; then
      sign_args+=(--timestamp --options runtime)
    fi
    if [ -n "$entitlements" ]; then
      sign_args+=(--entitlements "$entitlements")
    fi
    codesign "${sign_args[@]}" "$build_app_path"
    codesign --verify --deep --strict --verbose=2 "$build_app_path" >/dev/null
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

echo "Wrote ${app_path}"
