#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:?Usage: scripts/vendor-appium-runtime.sh <destination>}"
cache_dir="${APPIUM_RUNTIME_CACHE:-${repo_root}/.build/appium-runtime}"
appium_version="${APPIUM_VERSION:-3.5.2}"
xcuitest_driver_name="${APPIUM_XCUITEST_DRIVER_NAME:-xcuitest}"
xcuitest_driver_version="${APPIUM_XCUITEST_DRIVER_VERSION:-12.3.0}"
remote_xpc_version="${APPIUM_IOS_REMOTEXPC_VERSION:-5.13.2}"

node_bin="${NODE_BINARY:-$(command -v node || true)}"
npm_bin="${NPM_BINARY:-$(command -v npm || true)}"

if [ -z "$node_bin" ] || [ ! -x "$node_bin" ]; then
  echo "Node.js is required to vendor the Appium runtime." >&2
  exit 1
fi

if [ -z "$npm_bin" ] || [ ! -x "$npm_bin" ]; then
  echo "npm is required to vendor the Appium runtime." >&2
  exit 1
fi

runtime_stamp="${cache_dir}/.stupidmirror-runtime"
node_version="$("$node_bin" --version)"
wanted_stamp="appium=${appium_version}
node=${node_version}
driver=${xcuitest_driver_name}@${xcuitest_driver_version}
remotexpc=${remote_xpc_version}
layout=7"

assert_runtime_versions() {
  local driver_package="${cache_dir}/home/node_modules/appium-xcuitest-driver/package.json"
  local remote_xpc_package="${cache_dir}/home/node_modules/appium-ios-remotexpc/package.json"
  local actual_driver_version
  local actual_remote_xpc_version

  if [ ! -f "$driver_package" ] || [ ! -f "$remote_xpc_package" ]; then
    echo "Bundled Appium runtime is missing the pinned XCUITest or RemoteXPC package." >&2
    exit 1
  fi

  actual_driver_version="$("$node_bin" -p "require(process.argv[1]).version" "$driver_package")"
  actual_remote_xpc_version="$("$node_bin" -p "require(process.argv[1]).version" "$remote_xpc_package")"
  if [ "$actual_driver_version" != "$xcuitest_driver_version" ]; then
    echo "XCUITest driver version mismatch: expected ${xcuitest_driver_version}, got ${actual_driver_version}." >&2
    exit 1
  fi
  if [ "$actual_remote_xpc_version" != "$remote_xpc_version" ]; then
    echo "RemoteXPC version mismatch: expected ${remote_xpc_version}, got ${actual_remote_xpc_version}." >&2
    exit 1
  fi

  (
    cd "${cache_dir}/home"
    APPIUM_HOME="${cache_dir}/home" "$node_bin" --input-type=module -e \
      'await import("appium-ios-remotexpc")'
  )
}

prune_runtime() {
  if [ "${APPIUM_RUNTIME_PRUNE:-true}" != "true" ]; then
    return
  fi

  echo "Pruning Appium runtime..."
  find "$cache_dir" -type d \( \
    -name .cache -o \
    -name .github -o \
    -name .nyc_output -o \
    -name __tests__ -o \
    -name coverage -o \
    -name example -o \
    -name examples -o \
    -name man -o \
    -name test -o \
    -name tests \
  \) -prune -exec rm -rf {} +
  find "$cache_dir" -type f \( \
    -name '*.map' -o \
    -name '*.markdown' -o \
    -name '*.md' -o \
    -name '*.d.ts' -o \
    -name '*.d.ts.map' -o \
    -name '*.tsbuildinfo' \
  \) -delete

  # The bundled app runs Appium's compiled JavaScript. The TypeScript compiler
  # package is pulled in by Appium tooling but is not needed by the packaged
  # runtime path.
  find "$cache_dir" -path '*/node_modules/typescript' -type d -prune -exec rm -rf {} +

  # Keep only the macOS arm64 sharp binary family needed on Apple Silicon.
  find "$cache_dir" -type d \( \
    -path '*/node_modules/@img/sharp-wasm32' -o \
    -path '*/node_modules/@img/sharp-linux-*' -o \
    -path '*/node_modules/@img/sharp-libvips-linux-*' -o \
    -path '*/node_modules/@img/sharp-darwin-x64' -o \
    -path '*/node_modules/@img/sharp-libvips-darwin-x64' \
  \) -prune -exec rm -rf {} +

  find "$cache_dir" -type l -exec sh -c '
    for path do
      target=$(readlink "$path")
      dir=$(dirname "$path")
      if [ ! -e "$dir/$target" ] && [ ! -e "$target" ]; then
        rm -f "$path"
      fi
    done
  ' sh {} +
}

if [ ! -f "$runtime_stamp" ] || [ "$(cat "$runtime_stamp")" != "$wanted_stamp" ]; then
  echo "Vendoring Appium ${appium_version} runtime into ${cache_dir}..."
  rm -rf "$cache_dir"
  mkdir -p "${cache_dir}/bin" "${cache_dir}/home"
  cp "$node_bin" "${cache_dir}/bin/node"

  cat > "${cache_dir}/package.json" <<JSON
{
  "private": true,
  "name": "stupidmirror-appium-runtime",
  "version": "0.0.0",
  "dependencies": {
    "appium": "${appium_version}"
  }
}
JSON

  "$npm_bin" --prefix "$cache_dir" install --omit=dev --no-audit --no-fund
  APPIUM_HOME="${cache_dir}/home" "${cache_dir}/bin/node" "${cache_dir}/node_modules/appium/build/lib/main.js" \
    driver install "${xcuitest_driver_name}@${xcuitest_driver_version}"
  "$npm_bin" --prefix "${cache_dir}/home" install --save-dev --save-exact \
    "appium-ios-remotexpc@${remote_xpc_version}" --no-audit --no-fund
  nested_appium="${cache_dir}/home/node_modules/appium-xcuitest-driver/node_modules/appium"
  if [ -L "$nested_appium" ]; then
    rm "$nested_appium"
    cp -R "${cache_dir}/node_modules/appium" "$nested_appium"
  fi
  APPIUM_HOME="${cache_dir}/home" bash "${repo_root}/scripts/patch-wda-for-control.sh"
  assert_runtime_versions
  prune_runtime

  printf '%s' "$wanted_stamp" > "$runtime_stamp"
else
  echo "Using cached Appium runtime: ${cache_dir}"
fi

assert_runtime_versions

mkdir -p "${cache_dir}/bin"
cat > "${cache_dir}/bin/appium" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_root="${HOME}/Library/Application Support/StupidMirror"
source_home="${runtime_dir}/home"
runtime_stamp="${runtime_dir}/.stupidmirror-runtime"
default_home="${support_root}/AppiumHome"

if [ -z "${APPIUM_HOME:-}" ]; then
  mkdir -p "$support_root"
  if [ ! -d "$default_home" ] || ! cmp -s "$runtime_stamp" "${default_home}/.stupidmirror-runtime" 2>/dev/null; then
    rm -rf "$default_home"
    mkdir -p "$default_home"
    if command -v ditto >/dev/null 2>&1; then
      ditto --norsrc "$source_home" "$default_home"
    else
      cp -R "${source_home}/." "$default_home"
    fi
    cp "$runtime_stamp" "${default_home}/.stupidmirror-runtime"
  fi
  export APPIUM_HOME="$default_home"
fi
export PATH="${runtime_dir}/bin:${PATH}"
export STUPIDMIRROR_SKIP_WDA_ICON_EMBED="${STUPIDMIRROR_SKIP_WDA_ICON_EMBED:-1}"

exec "${runtime_dir}/bin/node" "${runtime_dir}/node_modules/appium/build/lib/main.js" "$@"
SH
chmod +x "${cache_dir}/bin/appium" "${cache_dir}/bin/node"
prune_runtime

rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
if command -v ditto >/dev/null 2>&1; then
  ditto --norsrc "$cache_dir" "$destination"
else
  cp -R "$cache_dir" "$destination"
fi

absolute_symlink="$(find "$destination" -type l -exec sh -c 'for p; do target=$(readlink "$p"); case "$target" in /*) printf "%s\n" "$p"; exit 0;; esac; done' sh {} + | head -1)"
if [ -n "$absolute_symlink" ]; then
  echo "Bundled Appium runtime contains an absolute symlink: ${absolute_symlink}" >&2
  exit 1
fi

echo "Vendored Appium runtime: ${destination}"
