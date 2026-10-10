#!/bin/bash
# Installs the local plugin; builds/releases and device signing are separate.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
codex_cli="${CODEX_BINARY:-}"
if [ -z "$codex_cli" ]; then
  for candidate in "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex" \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "$HOME/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex" \
    "$HOME/Applications/Codex.app/Contents/Resources/codex" \
    "$(command -v codex || true)" /opt/homebrew/bin/codex /usr/local/bin/codex "$HOME/.local/bin/codex"; do
    if [ -x "$candidate" ] && "$candidate" plugin add --help >/dev/null 2>&1; then
      codex_cli="$candidate"
      break
    fi
  done
fi
if [ -z "$codex_cli" ] || [ ! -x "$codex_cli" ]; then
  echo "Install or update the Codex / ChatGPT desktop app, then click Connect Codex again. A Codex CLI with plugin support also works." >&2
  exit 1
fi
app_path="${STUPIDMIRROR_APP:-/Applications/StupidMirror.app}"
if [ -z "${STUPIDMIRROR_APP:-}" ] && [ ! -d "$app_path" ] && [ -d "$HOME/Applications/StupidMirror.app" ]; then
  app_path="$HOME/Applications/StupidMirror.app"
fi
if [ ! -x "$app_path/Contents/Helpers/StupidMirrorMCPBridge" ]; then
  echo "Install the StupidMirror app with its Codex helper first: bash scripts/build-app.sh, then copy dist/StupidMirror.app into Applications." >&2
  exit 1
fi
marketplace_root="$app_path/Contents/Resources/CodexPlugin"
if [ ! -f "$marketplace_root/.agents/plugins/marketplace.json" ]; then
  marketplace_root="$repo_root"
fi
umask 077
state_dir="$HOME/Library/Application Support/StupidMirror/Codex"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
work_dir="$(mktemp -d "$state_dir/install.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
printf '%s\n' "$app_path" > "$work_dir/app-path"
mv "$work_dir/app-path" "$state_dir/app-path"

# A generated HTTP entry takes precedence over the plugin. Migrate only the
# entry for this app's current endpoint, retaining a private recovery copy.
has_previous=false
if "$codex_cli" mcp get stupidmirror --json > "$work_dir/previous.json" 2>/dev/null; then
  previous_type="$(/usr/bin/plutil -extract transport.type raw -o - "$work_dir/previous.json" 2>/dev/null || true)"
  previous_plugin_root="$(/usr/bin/plutil -extract transport.env.PLUGIN_ROOT raw -o - "$work_dir/previous.json" 2>/dev/null || true)"
  previous_script="$(/usr/bin/plutil -extract transport.args.0 raw -o - "$work_dir/previous.json" 2>/dev/null || true)"
  previous_url="$(/usr/bin/plutil -extract transport.url raw -o - "$work_dir/previous.json" 2>/dev/null || true)"
  connection_file="$HOME/Library/Application Support/StupidMirror/MCP/connection.json"
  current_url="$(/usr/bin/plutil -extract endpoint raw -o - "$connection_file" 2>/dev/null || true)"
  if [ "$previous_type" = stdio ] && [ -n "$previous_plugin_root" ] \
    && [[ "$previous_plugin_root" == */stupidmirror-local/stupidmirror/* ]] \
    && [ "$previous_script" = "$previous_plugin_root/scripts/start.sh" ]; then
    # Newer Codex versions also return plugin-provided servers from `mcp get`.
    # This is our existing install, not a manual entry that needs migration.
    :
  elif [ -n "$current_url" ] && [ "$previous_url" = "$current_url" ]; then
    has_previous=true
  else
    echo "An existing stupidmirror MCP entry points to a different connection. Review that entry in Codex settings before installing; it has not been changed." >&2
    exit 1
  fi
fi
"$codex_cli" plugin marketplace add "$marketplace_root" --json
"$codex_cli" plugin add stupidmirror@stupidmirror-local --json
if [ "$has_previous" = true ]; then
  cp "$work_dir/previous.json" "$state_dir/previous-mcp.json"
  "$codex_cli" mcp remove stupidmirror
fi
printf '%s\n' "$app_path" > "$state_dir/installed-app-path"
echo "Installed StupidMirror. Reconnect or open a new Codex chat, then ask: 用 StupidMirror 在 Codex 中显示我的手机屏幕。"
