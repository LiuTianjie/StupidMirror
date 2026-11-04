#!/bin/bash
# Makes the live phone the first thing a Claude desktop session shows, the way
# Codex opens its panel: the first StupidMirror call of a session, other than
# open_viewer, is turned back once with instructions to open the Browser pane.
# Terminal sessions are left alone. Never fails a tool call on its own errors.
set -u
mode="${1:-}"
input="$(cat 2>/dev/null || true)"

case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  claude-desktop*) ;;
  *) exit 0 ;;
esac

field() {
  if [ -x /usr/bin/jq ]; then
    printf '%s' "$input" | /usr/bin/jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
  fi
}

session="$(field session_id | tr -cd 'A-Za-z0-9_-')"
[ -n "$session" ] || exit 0
state="${TMPDIR:-/tmp}/stupidmirror-claude-viewer"
mkdir -p "$state" 2>/dev/null || exit 0
find "$state" -type f -mtime +2 -delete 2>/dev/null

if [ "$mode" = "post" ]; then
  : > "$state/$session.opened" 2>/dev/null
  exit 0
fi

tool="$(field tool_name)"
case "$tool" in
  mcp__stupidmirror__open_viewer) exit 0 ;;
  # The viewer page's own transport, never called by the model.
  mcp__stupidmirror__screen_frame|mcp__stupidmirror__screen_action|mcp__stupidmirror__screen_signal) exit 0 ;;
esac
# Once per session: after one reminder the session decides for itself.
[ -e "$state/$session.opened" ] || [ -e "$state/$session.reminded" ] && exit 0
: > "$state/$session.reminded" 2>/dev/null || exit 0

reason="Open the live phone first. Call mcp__stupidmirror__open_viewer now, with no device_id: it picks the device you are working with and follows you when you switch, so never ask the user to choose one. Then open it in the Browser pane without asking: write its browser_pane.launch_configuration into .claude/launch.json under browser_pane.launch_name, call preview_start with that name, then preview_eval location.assign(<url>), and show_pane preview. If a Browser tool fails, give the url as a link once. Then retry this call."
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
