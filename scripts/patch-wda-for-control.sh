#!/usr/bin/env bash
set -euo pipefail

default_script_path="$HOME/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/Scripts/embed-runner-icon.sh"
if [ -n "${APPIUM_HOME:-}" ]; then
  default_script_path="${APPIUM_HOME}/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/Scripts/embed-runner-icon.sh"
fi
script_path="${APPIUM_WDA_ICON_SCRIPT:-$default_script_path}"

if [ ! -f "$script_path" ]; then
  echo "WDA icon embed script not found. Install the Appium XCUITest driver first." >&2
  exit 0
fi

if grep -q 'STUPIDMIRROR_SKIP_WDA_ICON_EMBED' "$script_path"; then
  echo "WDA icon embed skip guard already installed."
  exit 0
fi

tmp_path="$(mktemp)"
{
  read -r first_line
  printf '%s\n' "$first_line"
  cat <<'GUARD'

if [ "${STUPIDMIRROR_SKIP_WDA_ICON_EMBED:-}" = "1" ]; then
    echo "warning: skipping WDA runner icon embed for StupidMirror control setup"
    exit 0
fi
GUARD
  cat
} < "$script_path" > "$tmp_path"

cat "$tmp_path" > "$script_path"
rm -f "$tmp_path"
chmod +x "$script_path"
echo "Installed WDA icon embed skip guard: $script_path"
