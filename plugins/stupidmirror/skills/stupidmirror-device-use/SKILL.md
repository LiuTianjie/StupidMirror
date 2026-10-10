---
name: stupidmirror-device-use
description: Observe and operate real iPhone or Android devices using StupidMirror tools, including reading screens, app navigation, taps, swipes, text entry and real-device UI checks. Use when the user asks to operate a connected phone; connection setup uses stupidmirror-setup.
---

# Operate a device through StupidMirror

Use the StupidMirror MCP tools. Start with `list_devices`; select the intended device and consistently pass `device_id` when multiple devices exist. Call `show_screen` to display the live device inside Codex, then `connect_control` if actions are needed. The app captures in the background. Do not call `start_mirror` unless the user explicitly wants a separate Mac mirror window.

- For routine navigation, use `tap_text` with all candidate labels in `queries`. Use `find_any_element` when the target should be inspected before tapping. These perform one local OCR pass, then at most one native hierarchy lookup. Do not query every synonym separately.
- To read a screen, call `observe_screen(include_image=false, include_ocr=true, include_accessibility=false)` first. OCR runs locally on the live frame and returns text with coordinates; sending a full screenshot adds cost without improving ordinary text reading. Request accessibility only when OCR lacks the required semantics or the text is ambiguous; do not fetch both on every read.
- Request `include_image=true` for unlabeled icons, maps, canvas content, visual layout checks, or unresolved ambiguity. Inspect that fresh image before using normalized coordinates in `[0, 1]`. Do not automatically take another screenshot after every action; verify the specific resulting text/state with OCR or `wait_for`.
- When the target is already known, call `tap_text` directly with candidate labels instead of reading, finding and tapping in separate calls. Preserve accuracy by inspecting ambiguous matches and reobserving after navigation; never trade fresh target evidence for fewer calls.
- Reuse a fresh observation's `element_id` with its `observation_id` for `tap_element`. Reobserve after navigation instead of using stale geometry.
- Once a field is focused, call `replace_text` to overwrite, `clear_text` to empty, or `type_text` to append. Do not fetch an accessibility tree between focus and input: an iOS snapshot can disturb focus. Verify the resulting text before submission.
- Use `wait_for` for a bounded expected state, or `assert_screen` for a specific check. Observe relevant results after actions; receiving a successful click response alone does not prove the destination screen appeared.
- `highlight_elements` and `highlight_clickable_elements` annotate a separately opened Mac mirror without tapping the phone; these native overlays are not currently drawn in the embedded preview.

If an action loses its connection or times out, it may already have executed. Read the current state before deciding what to do next; do not blindly repeat clicks, text entry or submission. Use diagnostics for persistent failures and reuse the app's device connection.

Only carry out the user's requested actions. Drafting text does not authorize sending it, making a purchase or publishing content. Leave authentication secrets and biometric prompts to the user.

When the user sends a screenshot annotation, use its device ID and note. The attached image and numbered regions describe a frozen frame; observe the live device again before an action, and confirm the intended target still matches. Do not blindly replay the stored coordinates. Preview uses WebRTC independently of AI tool calls. `screen_signal`, `screen_frame` and `screen_action` are app-only transport/UI tools.
