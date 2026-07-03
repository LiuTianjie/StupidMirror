#!/usr/bin/env bash
set -euo pipefail

host="${APPIUM_HOST:-127.0.0.1}"
port="${APPIUM_PORT:-4723}"
appium_binary="${APPIUM_BINARY:-$(command -v appium || true)}"

if [ -z "$appium_binary" ] || [ ! -x "$appium_binary" ]; then
  echo "Appium is not installed. Run: make setup-appium" >&2
  exit 1
fi

bash "$(dirname "$0")/patch-wda-for-control.sh"
export STUPIDMIRROR_SKIP_WDA_ICON_EMBED="${STUPIDMIRROR_SKIP_WDA_ICON_EMBED:-1}"

echo "Starting Appium at http://${host}:${port}"
exec "$appium_binary" --address "$host" --port "$port"
