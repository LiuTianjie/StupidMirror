#!/usr/bin/env bash
set -u

section() {
  printf '\n== %s ==\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

print_kv() {
  printf '%-18s %s\n' "$1:" "$2"
}

section "Host"
if have sw_vers; then
  sw_vers
else
  echo "sw_vers not found"
fi

if have xcodebuild; then
  xcodebuild -version
else
  echo "xcodebuild not found"
fi

if have swift; then
  swift --version | sed -n '1,2p'
else
  echo "swift not found"
fi

section "libimobiledevice"
if ! have idevice_id; then
  echo "idevice_id not found. Install with: brew install libimobiledevice"
else
  udids="$(idevice_id -l 2>/dev/null || true)"
  if [ -z "$udids" ]; then
    echo "No devices reported by idevice_id."
  else
    printf '%s\n' "$udids" | while IFS= read -r udid; do
      [ -z "$udid" ] && continue
      echo
      print_kv "UDID" "$udid"
      if have ideviceinfo; then
        for key in DeviceName ProductType ProductVersion UniqueDeviceID; do
          value="$(ideviceinfo -u "$udid" -k "$key" 2>/dev/null || true)"
          [ -n "$value" ] && print_kv "$key" "$value"
        done
      else
        echo "ideviceinfo not found; cannot read device metadata."
      fi
    done
  fi
fi

section "Xcode devices"
if have xcrun; then
  xcrun xctrace list devices 2>/dev/null | sed -n '1,120p' || true
else
  echo "xcrun not found"
fi

section "USB hints"
if have system_profiler; then
  system_profiler SPUSBDataType -detailLevel mini 2>/dev/null \
    | grep -i -C 2 -E 'iphone|ipad|ipod|vendor id|product id|serial' || true
else
  echo "system_profiler not found"
fi

