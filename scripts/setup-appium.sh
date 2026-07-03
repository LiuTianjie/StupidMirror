#!/usr/bin/env bash
set -euo pipefail

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required. Install Node.js first." >&2
  exit 1
fi

if ! command -v appium >/dev/null 2>&1; then
  echo "Installing Appium globally..."
  npm install -g appium
else
  echo "Appium already installed: $(command -v appium)"
fi

if ! appium driver list --installed 2>/dev/null | grep -q 'xcuitest'; then
  echo "Installing Appium XCUITest driver..."
  appium driver install xcuitest
else
  echo "Appium XCUITest driver is already installed."
fi

bash "$(dirname "$0")/patch-wda-for-control.sh"

cat <<'MSG'

Host setup is done.

Still required for real iPhone control:
  1. Enable iPhone Settings -> Privacy & Security -> Developer Mode.
  2. Enable iPhone Settings -> Developer -> Enable UI Automation.
  3. Sign WebDriverAgentRunner with your Apple team:
       appium driver run xcuitest open-wda
  4. Start Appium:
       make run-appium

MSG
