#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configuration="${CONFIGURATION:-release}"
# Swift 6.3+ defaults to Swift Build; the current macOS linker integration can
# stamp the deployment target as the SDK version, opting AppKit into old UI.
# Keep the established build engine and validate the linked SDK below.
build_system="${SWIFT_BUILD_SYSTEM:-native}"
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
bundle_android_runtime="${BUNDLE_ANDROID_RUNTIME:-true}"
bundle_smtunnel="${BUNDLE_SMTUNNEL:-true}"
default_appium_url="${DEFAULT_APPIUM_URL:-http://127.0.0.1:4723}"
default_control_bundle_id="${DEFAULT_CONTROL_BUNDLE_ID:-}"
default_xcode_org_id="${DEFAULT_XCODE_ORG_ID:-${STUPIDMIRROR_XCODE_ORG_ID:-}}"
default_xcode_signing_id="${DEFAULT_XCODE_SIGNING_ID:-${STUPIDMIRROR_XCODE_SIGNING_ID:-Apple Development}}"
default_wda_bundle_id="${DEFAULT_WDA_BUNDLE_ID:-${STUPIDMIRROR_WDA_BUNDLE_ID:-}}"
official_license_endpoint="https://mkbeusztkzffnzjdwmqk.supabase.co/functions/v1/stupidmirror-license"
official_license_publishable_key="sb_publishable_GVf42S8a5aU4NHxMSFmTNA_LB6i6vlz"
license_endpoint="${LICENSE_ENDPOINT:-${STUPIDMIRROR_LICENSE_ENDPOINT:-$official_license_endpoint}}"
license_publishable_key="${LICENSE_PUBLISHABLE_KEY:-${STUPIDMIRROR_LICENSE_PUBLISHABLE_KEY:-$official_license_publishable_key}}"
# Sparkle updates. Only a Developer ID build can replace a signed install, so
# ad hoc and development builds carry no feed and their updater stays inert.
official_update_feed_url="https://liutianjie.github.io/StupidMirror/updates/appcast.xml"
official_update_public_ed_key="Yj8/B8nrGotIJEAEp4TjsvVNNFTRAwzF0CQR4t0qkwk="
update_feed_url="${UPDATE_FEED_URL:-$official_update_feed_url}"
update_public_ed_key="${UPDATE_PUBLIC_ED_KEY:-$official_update_public_ed_key}"
if [[ "$sign_identity" == "Developer ID Application: "* ]]; then
  enable_updates="${ENABLE_UPDATES:-true}"
else
  enable_updates="${ENABLE_UPDATES:-false}"
fi
app_path="dist/${app_name}.app"
build_work_dir="$(mktemp -d)"
build_app_path="${build_work_dir}/${app_name}.app"
trap 'rm -rf -- "$build_work_dir"' EXIT
contents_path="${app_path}/Contents"
macos_path="${contents_path}/MacOS"
icon_path="${ICON_PATH:-Assets/AppIcon.icns}"

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

license_endpoint_xml="$(xml_escape "$license_endpoint")"
license_publishable_key_xml="$(xml_escape "$license_publishable_key")"

echo "Building ${product_name} (${configuration})..."
swift build --build-system "$build_system" -c "$configuration" --product "$product_name"
swift build --build-system "$build_system" -c "$configuration" --product StupidMirrorMCPBridge

bin_path="$(swift build --build-system "$build_system" -c "$configuration" --show-bin-path)/${product_name}"
if [ ! -x "$bin_path" ]; then
  echo "Built binary not found: $bin_path" >&2
  exit 1
fi
linked_sdk="$(xcrun vtool -show-build "$bin_path" | awk '$1 == "sdk" { print $2; exit }')"
selected_sdk="$(xcrun --sdk macosx --show-sdk-version)"
if [ "${linked_sdk%%.*}" != "${selected_sdk%%.*}" ]; then
  echo "Linked SDK ${linked_sdk:-unknown} does not match selected SDK $selected_sdk; refusing a build with changed AppKit compatibility styling." >&2
  exit 1
fi

rm -rf "$app_path" "$build_app_path"
contents_path="${build_app_path}/Contents"
macos_path="${contents_path}/MacOS"
mkdir -p "$macos_path"
cp "$bin_path" "${macos_path}/${app_name}"
mkdir -p "${contents_path}/Helpers"
cp "$(dirname "$bin_path")/StupidMirrorMCPBridge" "${contents_path}/Helpers/StupidMirrorMCPBridge"
bash scripts/build-preview.sh "${contents_path}/Helpers/StupidMirrorPreview"
plugin_resources="${contents_path}/Resources/CodexPlugin"
mkdir -p "${plugin_resources}/.agents/plugins" "${plugin_resources}/plugins" "${plugin_resources}/scripts"
cp .agents/plugins/marketplace.json "${plugin_resources}/.agents/plugins/marketplace.json"
mkdir -p "${plugin_resources}/plugins/stupidmirror"
/usr/bin/rsync -a --exclude=node_modules --exclude=.DS_Store plugins/stupidmirror/ "${plugin_resources}/plugins/stupidmirror/"
cp scripts/install-codex-plugin.sh "${plugin_resources}/scripts/install-codex-plugin.sh"
if [ -f "$icon_path" ]; then
  mkdir -p "${contents_path}/Resources"
  cp "$icon_path" "${contents_path}/Resources/AppIcon.icns"
fi
if [ "$bundle_appium" = "true" ]; then
  mkdir -p "${contents_path}/Resources"
  bash scripts/vendor-appium-runtime.sh "${contents_path}/Resources/Appium"
fi
if [ "$bundle_android_runtime" = "true" ]; then
  mkdir -p "${contents_path}/Resources"
  bash scripts/vendor-android-runtime.sh "${contents_path}/Resources/Android"
fi
if [ "$bundle_smtunnel" = "true" ]; then
  mkdir -p "${contents_path}/Resources"
  bash scripts/build-smtunnel.sh "${contents_path}/Resources/smtunnel"
fi

# The app links Sparkle.framework from Contents/Frameworks (see Package.swift).
sparkle_source="$(find .build/artifacts -maxdepth 6 -type d -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' | head -n 1)"
if [ -z "$sparkle_source" ] || [ ! -d "$sparkle_source" ]; then
  echo "Sparkle.framework not found under .build/artifacts; run swift package resolve." >&2
  exit 1
fi
mkdir -p "${contents_path}/Frameworks"
ditto "$sparkle_source" "${contents_path}/Frameworks/Sparkle.framework"
sparkle_framework="${contents_path}/Frameworks/Sparkle.framework"
mkdir -p "${contents_path}/Resources"
cp Assets/licenses/Sparkle-LICENSE.txt "${contents_path}/Resources/Sparkle-LICENSE.txt"

# Mach-O files nested under Resources that need their own signature.
nested_binaries() {
  local roots=("${contents_path}/Helpers")
  if [ "$bundle_appium" = "true" ]; then
    roots+=("${contents_path}/Resources/Appium")
  fi
  if [ "$bundle_smtunnel" = "true" ]; then
    roots+=("${contents_path}/Resources/smtunnel")
  fi
  if [ "${#roots[@]}" -eq 0 ]; then
    return 0
  fi
  find "${roots[@]}" -type f -print0 \
    | while IFS= read -r -d '' candidate; do
        # Static archives are build inputs (the libsrt slices the screen agent
        # links), not code that runs; a universal one would read as Mach-O.
        [[ "$candidate" == *.a ]] && continue
        if file -b "$candidate" | grep -q 'Mach-O'; then
          printf '%s\0' "$candidate"
        fi
      done
}

update_plist_entries=""
if [ "$enable_updates" = "true" ]; then
  update_plist_entries="  <key>SUFeedURL</key>
  <string>$(xml_escape "$update_feed_url")</string>
  <key>SUPublicEDKey</key>
  <string>$(xml_escape "$update_public_ed_key")</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
"
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
  <string>StupidMirror uses microphone access to receive and play the audio track of an iPhone connected over USB.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>StupidMirror uses the local network to connect to Xcode-paired iPhones when wireless mode is enabled.</string>
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
  <key>StupidMirrorLicenseEndpoint</key>
  <string>${license_endpoint_xml}</string>
  <key>StupidMirrorLicensePublishableKey</key>
  <string>${license_publishable_key_xml}</string>
${update_plist_entries}  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.gaojiua.StupidMirror.auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>stupidmirror</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

resources_path="${contents_path}/Resources"
mkdir -p "${resources_path}/en.lproj" "${resources_path}/zh-Hans.lproj"
cat > "${resources_path}/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "StupidMirror uses camera access to receive the video track of an iPhone connected over USB. It does not capture the Mac camera.";
"NSMicrophoneUsageDescription" = "StupidMirror uses microphone access to receive and play the audio track of an iPhone connected over USB.";
"NSLocalNetworkUsageDescription" = "StupidMirror uses the local network to connect to Xcode-paired iPhones when wireless mode is enabled.";
STRINGS
cat > "${resources_path}/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "StupidMirror 使用相机权限接收通过 USB 连接的 iPhone 视频画面，不会采集 Mac 摄像头。";
"NSMicrophoneUsageDescription" = "StupidMirror 使用麦克风权限接收并播放通过 USB 连接的 iPhone 音轨。";
"NSLocalNetworkUsageDescription" = "启用无线模式后，StupidMirror 会通过本地网络连接已在 Xcode 配对的 iPhone。";
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

    while IFS= read -r -d '' nested_binary; do
      nested_args=("${nested_sign_args[@]}")
      if [ "$nested_binary" = "${contents_path}/Resources/Appium/bin/node" ]; then
        nested_args+=(--entitlements "$node_entitlements")
      fi
      codesign "${nested_args[@]}" "$nested_binary" || return 1
    done < <(nested_binaries)

    # Sparkle from the inside out: its helpers keep their own entitlements.
    for sparkle_part in \
      Versions/B/XPCServices/Downloader.xpc \
      Versions/B/XPCServices/Installer.xpc \
      Versions/B/Updater.app \
      Versions/B/Autoupdate; do
      codesign "${nested_sign_args[@]}" --preserve-metadata=entitlements \
        "${sparkle_framework}/${sparkle_part}" || return 1
    done
    codesign "${nested_sign_args[@]}" "$sparkle_framework" || return 1

    app_sign_args+=(--entitlements "$entitlements")
    codesign "${app_sign_args[@]}" "$build_app_path" || return 1

    while IFS= read -r -d '' nested_binary; do
      codesign --verify --strict --verbose=2 "$nested_binary" >/dev/null || return 1
    done < <(nested_binaries)
    codesign --verify --strict --deep --verbose=2 "$sparkle_framework" >/dev/null || return 1
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
