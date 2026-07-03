#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:?Usage: scripts/vendor-appium-runtime.sh <destination>}"
cache_dir="${APPIUM_RUNTIME_CACHE:-${repo_root}/.build/appium-runtime}"
appium_version="${APPIUM_VERSION:-3.5.2}"
xcuitest_driver="${APPIUM_XCUITEST_DRIVER:-xcuitest}"

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
driver=${xcuitest_driver}
layout=3"

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
  APPIUM_HOME="${cache_dir}/home" "${cache_dir}/bin/node" "${cache_dir}/node_modules/appium/build/lib/main.js" driver install "$xcuitest_driver"
  nested_appium="${cache_dir}/home/node_modules/appium-xcuitest-driver/node_modules/appium"
  if [ -L "$nested_appium" ]; then
    rm "$nested_appium"
    cp -R "${cache_dir}/node_modules/appium" "$nested_appium"
  fi
  APPIUM_HOME="${cache_dir}/home" bash "${repo_root}/scripts/patch-wda-for-control.sh"
  find "$cache_dir" -type d -name .cache -prune -exec rm -rf {} +

  printf '%s' "$wanted_stamp" > "$runtime_stamp"
else
  echo "Using cached Appium runtime: ${cache_dir}"
fi

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
find "$cache_dir" -type d -name .cache -prune -exec rm -rf {} +

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
