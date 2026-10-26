---
name: stupidmirror-device-use
description: Observe and operate real iPhone or Android devices using StupidMirror tools, including reading screens, app navigation, taps, swipes, text entry and real-device UI checks. Use when the user asks to operate a connected phone; connection setup uses stupidmirror-setup.
---

# Operate a device through StupidMirror

Use the StupidMirror MCP tools (`mcp__stupidmirror__*`). Start with `list_devices`; select the intended device and consistently pass `device_id` when multiple devices exist (the call fails otherwise).

Before the first `observe_screen`, call `show_screen` with that `device_id`. It starts capture in the background without opening any window; without it `observe_screen` has no frame and reports "No live mirror frame is available". Claude Code shows no embedded panel, so ignore the preview fields in its result. Call `connect_control` only before actions or a native hierarchy read.

If the user wants to watch or operate the phone themselves, call `open_viewer` (with `device_id` when several devices exist). It returns `url`, a live viewer page on their Mac with the same video, device picker, refresh and manual control as the Codex panel, and `browser_pane` with a `launch_name` and an `origin`.

In the Claude desktop app, open the viewer in its Browser pane yourself so the user never leaves Claude:
1. In the project's `.claude/launch.json`, make sure a configuration named `browser_pane.launch_name` exists with `"url"` set to `browser_pane.origin` and no command. Create the file as `{"version": "0.0.1", "configurations": [...]}` if it is missing; otherwise add or update only that entry and leave every other configuration as it is. Mention the change in one line the first time.
2. Call the Browser tool `preview_start` with that name. It opens a "Waiting for a StupidMirror viewer link" page.
3. Navigate the pane to the full `url` with `preview_eval` (`location.assign(<url>)`); the page then reads its ticket. Show the pane with `show_pane` (`preview`) when available.

If the Browser tools are missing or fail (the terminal CLI, or another host), give `url` as a clickable Markdown link instead. Each link opens one viewer and expires after 10 minutes; call `open_viewer` again rather than reusing one. Never put the link in files or commits; `.claude/launch.json` holds only the origin. Do not open the viewer unasked. The viewer cannot send annotations into the chat; ask the user to describe what they see instead.

If the user asks for a separate Mac window instead, call `start_mirror` to open the native mirror, where your taps and swipe paths are also drawn.

- When the intended target is known, call `tap_text` directly with candidate labels in `queries`; avoid a separate read/find/tap chain. Use `find_any_element` when you need to inspect or disambiguate a target before tapping. These share one local OCR pass and at most one native hierarchy fallback; do not query synonyms separately.
- `observe_screen` defaults to an image plus compact OCR, without a native hierarchy. Keep the image for visual tasks or when the needed information is unclear; for clearly text-only reads, explicitly set `include_image=false`. `observe_screen`, `find_element` and `find_any_element` default to `response_format="compact"`. Keep that format for routine work; do not request full output and then filter it in model context.
- Compact elements retain `id`, text and `source`; `center: [x, y]` is a rounded normalized hint for distinguishing repeated labels. Native elements also retain type and available state flags/values. Use the element `id` and observation `id` (or search `observationID`) as `element_id` and `observation_id` for `tap_element`: it uses the stored full-precision geometry. Reobserve after navigation; do not reuse stale ids or treat OCR text as proof of clickability or toggle state.
- To verify an expected text, use `assert_screen` or a bounded `wait_for` instead of reading the whole screen. A successful tap alone does not prove the destination appeared.
- Request `include_accessibility=true, include_ocr=false` for native switch values, selection, enabled state or semantics absent from OCR. Do not fetch a native tree on every read. Use `response_format="full"` only when raw bounds, confidence precision or parent/child hierarchy are needed for diagnostics; it does not itself enable images or accessibility.
- Keep `include_image=true` (the default) for unlabeled icons, images, maps, canvas content, layout checks or unresolved ambiguity. Inspect the fresh image before coordinate input. If only the image is needed, also pass `include_ocr=false`. Do not take a screenshot automatically after every action.
- Once a field is focused, call `replace_text` to overwrite, `clear_text` to empty, or `type_text` to append. Do not fetch an accessibility tree between focus and input: an iOS snapshot can disturb focus. Verify the resulting text before submission.
- `highlight_elements` and `highlight_clickable_elements` annotate the Mac mirror window without tapping the phone; they need a mirror opened with `start_mirror`.

If an action loses its connection or times out, it may already have executed. Read the current state before deciding what to do next; do not blindly repeat clicks, text entry or submission. Use diagnostics for persistent failures and reuse the app's device connection.

Only carry out the user's requested actions. Drafting text does not authorize sending it, making a purchase or publishing content. Leave authentication secrets and biometric prompts to the user.

`screen_signal`, `screen_frame` and `screen_action` are transport tools for embedded panels in other hosts; do not call them.
