#!/usr/bin/env bash
set -u

serve=0
screenshot_path=""

usage() {
  cat <<'USAGE'
Usage: bash tools/probes/pymobiledevice3-screen-probe.sh [--serve] [--screenshot PATH]

Checks pymobiledevice3 availability and screen-mirror support.

Options:
  --serve            Start `pymobiledevice3 screen-mirror` if available.
  --screenshot PATH Try a DVT screenshot to PATH if pymobiledevice3 supports it.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --serve)
      serve=1
      shift
      ;;
    --screenshot)
      screenshot_path="${2:-}"
      if [ -z "$screenshot_path" ]; then
        echo "--screenshot requires PATH" >&2
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

section "pymobiledevice3"
if ! have pymobiledevice3; then
  cat <<'MSG'
pymobiledevice3 is not installed.

Stable package:
  python3 -m pip install -U pymobiledevice3

Screen mirror fork mentioned in Phase 1 research:
  python3 -m pip install -U "git+https://github.com/renegadelink/pymobiledevice3.git@screen-mirror"
  python3 -m pip install -U aiohttp av
MSG
  exit 2
fi

pymobiledevice3 --version 2>/dev/null || true

section "Connected devices"
pymobiledevice3 usbmux list 2>&1 || true

section "screen-mirror command"
if pymobiledevice3 --help 2>&1 | grep -q 'screen-mirror'; then
  echo "screen-mirror command is available."
  if [ "$serve" -eq 1 ]; then
    echo "Starting screen mirror server. Open the URL printed by pymobiledevice3."
    exec pymobiledevice3 screen-mirror
  else
    echo "To start it: bash tools/probes/pymobiledevice3-screen-probe.sh --serve"
  fi
else
  echo "screen-mirror command not found in this pymobiledevice3 install."
  echo "Install the screen-mirror fork if you want to test that backend."
fi

if [ -n "$screenshot_path" ]; then
  section "DVT screenshot"
  mkdir -p "$(dirname "$screenshot_path")"
  pymobiledevice3 mounter auto-mount 2>&1 || true
  pymobiledevice3 developer dvt screenshot "$screenshot_path"
  echo "Wrote screenshot to $screenshot_path"
fi

