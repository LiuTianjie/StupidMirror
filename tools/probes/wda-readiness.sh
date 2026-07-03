#!/usr/bin/env bash
set -u

udid=""

usage() {
  cat <<'USAGE'
Usage: bash tools/probes/wda-readiness.sh [--udid DEVICE_UDID]

Checks whether the host and connected device look ready for WebDriverAgent/Appium.
This script does not install Appium, install WDA, or start long-running services.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --udid)
      udid="${2:-}"
      if [ -z "$udid" ]; then
        echo "--udid requires DEVICE_UDID" >&2
        exit 2
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

have() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n== %s ==\n' "$1"
}

status_line() {
  if have "$1"; then
    printf '[ok]   %s -> %s\n' "$1" "$(command -v "$1")"
  else
    printf '[miss] %s\n' "$1"
  fi
}

section "Required host tools"
for tool in xcodebuild xcrun node npm appium iproxy idevice_id ideviceinfo; do
  status_line "$tool"
done

section "Versions"
have xcodebuild && xcodebuild -version
have node && node --version
have npm && npm --version
have appium && appium --version

section "Device target"
if [ -z "$udid" ] && have idevice_id; then
  udid="$(idevice_id -l 2>/dev/null | sed -n '1p' || true)"
fi

if [ -z "$udid" ]; then
  echo "No UDID provided and no connected device found via idevice_id."
else
  echo "UDID: $udid"
  if have ideviceinfo; then
    for key in DeviceName ProductType ProductVersion DeveloperStatus; do
      value="$(ideviceinfo -u "$udid" -k "$key" 2>/dev/null || true)"
      [ -n "$value" ] && printf '%-18s %s\n' "$key:" "$value"
    done
  fi
fi

section "Xcode visibility"
if have xcrun; then
  xcrun xctrace list devices 2>/dev/null | sed -n '1,120p' || true
else
  echo "xcrun not found"
fi

section "Appium XCUITest driver"
if have appium; then
  appium driver list --installed 2>&1 || true
  wda_project="$HOME/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj"
  if [ -d "$wda_project" ]; then
    echo "WDA project found: $wda_project"
  else
    echo "WDA project not found at default path."
    echo "If the xcuitest driver is installed, try: appium driver run xcuitest open-wda"
  fi
else
  cat <<'MSG'
Appium is not installed.

Typical setup:
  npm install -g appium
  appium driver install xcuitest
  appium driver run xcuitest open-wda
MSG
fi

section "Manual device settings still required"
cat <<'MSG'
On the iPhone:
  1. Trust this Mac when prompted.
  2. Enable Settings -> Privacy & Security -> Developer Mode.
  3. Enable Settings -> Developer -> Enable UI Automation.

For WDA:
  1. Sign WebDriverAgentRunner with a valid Apple team/provisioning profile.
  2. Start Appium or a managed WDA runner.
  3. Use tools/probes/appium-control-smoke.py for a real tap/screenshot smoke test.
MSG

