---
name: stupidmirror-setup
description: Set up or repair StupidMirror in Claude Code and its real iPhone or Android connection. Use for installation, missing stupidmirror tools, device discovery or connection errors; ordinary phone tasks use stupidmirror-device-use.
---

# StupidMirror setup

StupidMirror is a local macOS app. Claude Code reaches it through the user-scope MCP server `stupidmirror`, which runs the app's signed helper (`StupidMirror.app/Contents/Helpers/StupidMirrorMCPBridge --app <app>`). The helper opens the app and connects to its authenticated loopback MCP service. Phone agents, signing, USB/Wi-Fi sessions and mirroring belong to that app.

1. If StupidMirror tools are available, call `list_devices` and `get_diagnostics` before changing configuration. Reuse healthy device sessions.
2. The normal installation path is **StupidMirror → Settings → MCP Automation → Connect Claude Code**. It registers the MCP server and installs this plugin; a new Claude Code session then loads both. If the helper is missing, install a newer StupidMirror build in Applications.
3. In the app, Settings → MCP must be enabled. The helper reads the app's port and Bearer token itself; never print or copy `~/Library/Application Support/StupidMirror/MCP/connection.json` into chat, the repository or any config. Do not disable authentication or open the listener to the network.
4. If tools remain missing in a new session, check `claude mcp list` for `stupidmirror`. An older manual HTTP entry with a copied token stops working after the token rotates; clicking Connect Claude Code again replaces only StupidMirror's own entries. Preserve unrelated MCP configuration.
5. With several devices, select the user's intended device and pass its `device_id`. Call `show_screen` to start background capture (no window opens) before reading the screen, and `connect_control` only when actions or native hierarchy are needed. Claude Code has no embedded preview; when the user asks to watch or operate the phone, call `open_viewer` and open it in the Claude desktop Browser pane yourself as stupidmirror-device-use describes (a clickable link elsewhere), or open the native mirror with `start_mirror` if they want a separate Mac window. A frame needs capture, not a control session.

For initial iPhone setup, use StupidMirror's iPhone setup guide with the user's own Xcode team and bundle identifier. Apple account login, device trust, Developer Mode and unlocking may need the user. Existing paired devices should not be rebuilt just to recover a connection. Do not start a second WDA/Appium stack alongside StupidMirror. Android requires USB debugging and the phone's authorization prompt.

Verify tool availability separately from device readiness: `list_devices` proves Claude Code can reach the app; `observe_screen` proves an actual frame is available; a user-authorized reversible action followed by observation proves control. If no device is attached, report that boundary without claiming a successful phone test.
