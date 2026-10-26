# Changelog

## 0.7.0 - 2026-10-27

- Watch and operate the phone from Claude Code. The new `open_viewer` tool
  starts capture and returns a link to a live viewer page on this Mac; in the
  Claude desktop app's Code tab it opens in the Browser pane. The page reuses
  the Codex panel: live local WebRTC video with a PNG fallback, device
  picker, refresh and manual control. Annotation is hidden there because no
  chat receives it.
- The viewer link carries a single-use ticket that expires after 10 minutes,
  in the URL fragment so it is never sent in a request or Referer. The page
  trades it for a tab session that can call only the four panel tools; the
  MCP bearer token never reaches the page. Host and Origin are checked, and
  rotating the token or stopping the server ends every open viewer.
- Fix `list_devices`, `refresh_devices` and `list_apps` in Claude Code, which
  rejected their results because the device or app list was returned as a
  bare array. Structured results now wrap the list as `devices` or `apps`;
  the text result is unchanged.
- Tell Claude Code to call `show_screen` before reading the screen. It starts
  background capture without opening a Mac window, so `observe_screen` has a
  frame. Screen errors now name `show_screen` alongside `start_mirror`, and the
  tool's description no longer reads as Codex-only.
- `observe_screen` right after `show_screen` waits up to a few seconds for the
  first frame instead of failing while capture starts.
- Fast OCR no longer garbles Chinese. Apple Vision's fast mode reads Latin
  scripts only, so a request that includes Chinese or another script is read
  in accurate mode.
- Keep the installed Claude Code plugin current: connecting again updates
  Claude Code's cached copy, and after an app update StupidMirror refreshes
  the plugin by itself when it was already installed.

## 0.6.1 - 2026-10-26

- Add one-click **Connect Claude Code** in **Settings → MCP Automation**,
  beside Codex. It registers the user-scope `stupidmirror` MCP server and
  installs a StupidMirror plugin with setup and device-use skills written for
  Claude Code; parts already in place are skipped. It works in the terminal
  and in the Claude desktop app's Code tab.
- The Claude Code MCP entry runs the app's signed helper over stdio, so no
  token is written to Claude Code's configuration and port or token changes
  need no reconnection. An older `stupidmirror` HTTP entry for this app's
  endpoint is replaced; an unrelated entry with that name is kept.
- The plugin is read in place from the installed app, so app updates refresh
  it. Clicking again after moving the app points Claude Code at the new copy.
- Redesign the AI client setup as side-by-side Codex and Claude Code cards,
  each with its status, one install action and a starter prompt to copy.

## 0.6.0 - 2026-10-26

- Prefer system HID touch on supported iOS 27+ iPhones over USB or Wi-Fi and
  on compatible iOS Simulators. Presses, movement and releases are sent as
  they happen, with held long presses and native screen-edge gestures. An
  **HID** badge identifies the active live-touch connection.
- Forward native Mac trackpad scroll, magnification and rotation when the
  device's gesture service is available, including mouse-wheel and momentum
  events. Default touchscreen mode uses a held left mouse button for long
  press; right click is no longer mapped to a separate long-press action.
- Keep WDA compatibility when HID cannot connect, and prepare WDA on demand
  for text, buttons, app and accessibility actions. Programmatic pinch and
  rotate calls with an explicit center still use WDA to preserve that center.
  A gesture interrupted after input starts is never replayed on a fallback.
- Share touch ownership and ordered delivery across the native mirror, MCP
  coordinate actions and Codex preview. Reduce extra waits before automation
  gestures and simulator input, and release contacts on cancellation,
  connection loss or display changes.
- Use the signed WDA/XCTest runner's H.264 / SRT video stream for both USB
  and wireless iPhones, decoded with VideoToolbox. Video does not require
  Camera permission and does not acquire the phone's audio output.
  **Setup change:** USB video now also requires the runner; complete
  **Set Up This iPhone**, or run **Prepare Again** once over USB to update an
  existing runner.
- Bound capture, encoding, transmission and decoding buffers to limit memory
  growth and accumulated video delay. Recover from a new keyframe after an
  overloaded or interrupted stream instead of replaying a growing backlog.
  Improve tunnel startup and reconnect handling during USB re-enumeration.
- Keep iPhone audio on the phone by default. **Play Device Audio on Mac**
  opens a separate USB audio input, requiring Camera and Microphone
  permission; switching back releases that input. Wireless audio stays on
  the phone. **Known limitation:** changing USB audio playback can
  re-enumerate the phone's USB network interface and briefly interrupt
  mirroring while the tunnel reconnects; this switch is not seamless.
- Add iPhone Duo simulator posture controls for Closed, Partially Open and
  Open. Change the actual hinge, select the active inner or outer display,
  and keep capture, orientation and touch coordinates aligned with the
  confirmed simulator state. Expose posture through `set_device_posture`
  and device status results.
- Show device bezels and a folding 3D Duo model in both the native mirror and
  Codex panel, using resources from the selected local Xcode installation
  when available. Follow hinge changes without replacing the preview view.
- Refine the device panel and mirror windows: compact status and posture
  controls, native menus, minimization and reopening, transparent device
  outlines, and resizing that preserves the device proportions and the
  user's chosen size through rotation. Discovery refreshes retain menu and
  keyboard state.
- Disable device input on static or stopped dashboard previews and while a
  simulator posture is changing; resume input on the live display with its
  current geometry.
- Codex plugin: send live pointer input and supported browser wheel input
  over the local WebRTC data channel into the shared touch backend. Cancel
  input on disconnect, stale geometry or congestion, and keep frame delivery
  bounded. Browser events lack some native macOS phase and acceleration
  information, so wheel behavior can differ from the native mirror.
- Refresh the setup guides and publish the complete changelog history on the
  website from this file as the shared source.

## 0.5.1 - 2026-10-23

- Recordings run to the moment `stop_recording` is called. When the screen
  stayed still at the end (an Android device only sends frames when its
  screen changes), the last frame was not held, so browsers and other
  players ended the video early.
- `install_app` reports a missing file or the wrong package type for the
  device as `invalid_argument` instead of `control_failed`.

## 0.5.0 - 2026-10-23

- iOS Simulators: a booted simulator now appears as a device. StupidMirror
  builds its screen agent for the simulator once (no signing, Xcode
  required), mirrors it at up to 60 fps and controls it like an iPhone. All
  of the simulator agent's ports listen on this Mac only.
- Android emulators are recognised, listed under their AVD name and marked
  Simulator instead of USB.
- Simulators and emulators count toward the simultaneous device limit like
  real devices. They are not mirrored automatically, so a simulator running
  your own UI tests is left alone until you open it.
- New MCP tools for agents:
  - `list_apps`, `install_app` (.app / .ipa / .apk), `uninstall_app` and
    `open_url` (web links and app deep links) on iPhones, iOS Simulators and
    Android. They use the platform's own tools and need no control session,
    except `open_url` on an iPhone.
  - `start_recording` / `stop_recording` save the live mirror as an H.264
    `.mp4` in `~/Movies/StupidMirror`, up to 10 minutes.
- `list_devices` and the other device results include `transport`
  (`usb`, `wireless` or `simulator`).
- Fix control reconnecting by itself a few seconds after an agent called
  `disconnect_control`.
- Fix the iPhone screen agent spinning on its Wi-Fi video connection: it
  read control messages into a buffer smaller than SRT accepts, so it
  busy-looped and never received key-frame requests, which slowed recovery
  from lost video packets. Run **Prepare Again** in iPhone Setup once over
  USB to install the fixed agent.

## 0.4.1 - 2026-10-22

- New app icon, and a matching template icon in the menu bar that follows
  light and dark menu bars.
- The device status lines read "镜像 进行中" / "控制 已就绪" (Mirror Live /
  Control Ready) instead of repeating the noun.
- Redesigned website with new screenshots of the 0.4 interface.

## 0.4.0 - 2026-10-22

- Redesign every window: the dashboard, device panel, settings, MCP, iPhone
  setup, activation, diagnostics and the mirror window share one neutral
  system of panels, wells, pill buttons and state marks, with colour kept for
  state (live, working, failed, control). The dashboard's top strip replaces
  the toolbar, and the selected device shows its mirror and control state as
  two status lines above the screen.
- Support light and dark appearance. The app follows the system by default;
  Settings → Interface and the menu bar can pin Light or Dark. Every text
  colour is tested for 4.5:1 contrast on every surface in both.
- iPhone control: add a `/stupidmirror/touch` route to the bundled
  WebDriverAgent that synthesizes taps, double taps, long presses, swipes and
  drags directly through the test daemon, skipping WebDriverAgent's
  per-call foreground-app lookup and coordinate resolution. Runners prepared
  by an earlier version keep working through the stock endpoints; run
  **Prepare Again** in iPhone Setup once over USB to install the route.
- A quick flick now keeps its real start point, direction and speed instead of
  always becoming the same full-screen page swipe.
- The mouse wheel scrolls the phone (each notch was previously below the
  minimum distance and dropped), and nearby notches are sent as one scroll.
- Trackpad scrolls are sent once when the fingers lift; macOS momentum is no
  longer replayed as a second, late scroll.
- Rapid taps are all delivered in order instead of replacing each other while
  the phone is busy, and scrolls queued behind a slow gesture add up instead
  of keeping only the last chunk.
- Swipes and drags that run past the edge of the picture are pinned to the
  screen edge instead of being discarded.
- After release, a tap ripple or the gesture's trail fades out on the mirror,
  so a gesture is acknowledged before the phone answers.
- Diagnostics shows each device's median and slowest gesture round-trip time
  over the last 20 gestures.
- Codex plugin: an annotation send waits up to ten minutes for a busy Codex to
  accept it instead of the SDK's one-minute default, and an unbound widget
  conversation explains how to reopen the panel.

## 0.3.9 - 2026-10-21

- Fix USB iPhone control dropping about 15 seconds after the mirror window is
  closed, and when a mirror is opened while control is already running.
  Starting or idling USB screen capture switches the iPhone between USB
  Configuration 7 and 6, which re-enumerates it and resets every usbmuxd
  connection, including the `smtunnel` control tunnel. While control is
  wanted for a cabled iPhone, StupidMirror now keeps its screen-capture
  stream running in the background (with audio returned to the phone
  speaker), so opening or closing the mirror never changes the USB
  configuration. The stream is released when control stops.
- Wait for the held USB capture stream to deliver its first frame before
  opening the USB control tunnel, so the tunnel is built after the
  Configuration 7 switch instead of being torn down by it.
- Gallery thumbnails and AI screen observations use frames from the held
  stream instead of falling back to a WebDriverAgent screenshot.

## 0.3.8 - 2026-10-21

- Fix USB iPhone mirroring freezing or dropping after brief USB re-enumerations
  or Configuration 6/7 switches (`CMIOGraphStart for setRunning (err=-67520)`).
  Stopping or retargeting a USB session now tears down the old `CMIOGraph`,
  replaces the `AVCaptureSession`, and resolves the newly published
  `AVCaptureDevice` instance even when its `uniqueID` is unchanged.
- Observe `AVCaptureSession.runtimeErrorNotification` and add a USB first-frame
  watchdog so a wedged capture graph automatically tears down and recovers.
- Avoid starting one-shot USB `ThumbnailCapture` sessions while device control,
  an `smtunnel` sidecar, iPhone setup, or the `--mcp-background` daemon is
  active, preventing `iOSScreenCaptureAssistant` idle timers from resetting the
  USB bus and dropping active tunnels.
- Retry iOS control tunnel startup across transient USB re-enumeration windows
  and automatically resume desired control sessions when a device reconnects.

## 0.3.7 - 2026-10-20

- Fix a wireless mirror window that could keep waiting for video while control
  and the preview already worked. Wireless start-up now follows the mirror
  itself instead of a device ID that can change mid-start, and a waiting mirror
  with nothing in flight asks for a fresh video endpoint again.
- Check for app updates with Sparkle, like the LinkShell desktop app: a daily
  background check, **Check for Updates…** in the menu bar and Settings, and
  Sparkle's update window with release notes. Updates are verified with an
  EdDSA signature and the app's Developer ID signature before installing.
  This release is the first with the updater; 0.3.6 and earlier update manually.
- Add **Open at login** in Settings > Startup & Updates (off by default). A
  login launch stays in the menu bar.
- Show the Dock icon while the dashboard or a mirror window is open, and bring
  the dashboard back when the app is opened again from Spotlight, Finder or the
  Dock while it runs in the menu bar.

## 0.3.6 - 2026-10-19

- Discover wireless iPhones through usbmuxd, the same path the `smtunnel`
  sidecar connects over, instead of `devicectl`, whose CoreDevice tunnel state
  never reflected the app's own tunnel. A phone on the same Wi-Fi now shows as
  connected before mirroring starts, so auto-start, Start All and MCP tools
  that select a device (`start_mirror`, `connect_control`, `show_screen`, …)
  work without first starting it by hand. Wireless devices no longer need
  `.coredevice.local` hostnames, which also removes a crash path when they
  were missing.
- Keep a live wireless session when one discovery poll misses the phone; the
  tunnel ending remains the signal that it is really gone. A failed start no
  longer marks a reachable phone unavailable.
- Plugging in USB while a wireless mirror or control session is in use keeps
  that session on Wi-Fi instead of restarting it over the cable.
- Give a busy runner a second, longer `/status` check before replacing its
  tunnel, so a slow answer no longer drops video and control together.
- Report the developer disk image correctly on iOS 17+ (personalized cryptex
  image); the setup guide no longer flags it missing on working phones. Bound
  the identity read in `smtunnel list --details` so a stale Wi-Fi entry cannot
  stall discovery.

## 0.3.5 - 2026-10-12

- Default screen observation to an image plus compact local OCR. Keep actionable
  element IDs, native state and normalized center hints without verbose geometry.
- Return compact text-search matches by default, with `response_format="full"`
  available for the original observation/search metadata and hierarchy.
- Bundle Codex plugin 0.2.4 with the updated device skill.
- Guide the device skill toward direct text taps and targeted checks; disable
  images only for clearly text-only reads, keeping visual evidence by default.

## 0.3.4 - 2026-10-11

- Move existing annotation boxes by dragging inside them instead of creating
  nested selections. Resize from any edge or corner, with image bounds enforced.
- Add selection deletion and undo for creation, movement, resizing and deletion.
- Keep the compact annotation composer below the image at every window width;
  grow multiline notes to a bounded height without covering the preview.
- Send only the marked screenshot and note, without redundant device, timestamp
  or coordinate metadata. Support Command-Enter and Control-Enter to send, while
  plain Enter inserts a newline and IME composition cannot trigger submission.
- Bundle Codex plugin 0.2.3 and extend interaction and message regression coverage.

## 0.3.3 - 2026-10-10

- Restore activation by SM- code without signing in: enable code entry, purchase
  links and submission, and use installation activation for signed-out users.
- Put code activation first and keep account sign-in and binding in an optional
  section. Preserve redemption and restore for existing account users.
- Remove the client-side mandatory account-claim deadline from Mac receipts.
  Include a separate server migration to keep installation activation available
  after the historical account-migration grace period.
- Cover signed-out activation, cached receipt restoration and signed-in redemption
  with regression tests.

## 0.3.2 - 2026-10-10

- Distinguish a rejected annotation message from an unconfirmed delivery.
  Preserve the frozen image, regions and note, and explain how to reopen the
  panel when Codex reports that the chat composer is unavailable.
- Keep delivery timeouts uncertain and never automatically replay an annotation.
- Add regression coverage for consecutive sends, a second-send composer
  rejection and a lost acknowledgement. Bundle Codex plugin 0.2.2.
- Verify the installed 0.3.1 app / 0.2.1 plugin in a fresh Codex chat: the live
  iPhone panel opened, two consecutive annotated image messages arrived, and
  authorized native navigation and text input worked. This does not establish
  that an older chat with a detached composer has been repaired.

## 0.3.1 - 2026-10-10

- Fix Codex initialization failing with JSON-RPC `-32603` when the client sends
  object-valued experimental capabilities. Apply the compatibility fix to both
  the bundled stdio helper and the authenticated Streamable HTTP endpoint.
- Serialize complete MCP stdio messages under backpressure so concurrent image
  responses cannot corrupt preview metadata or WebRTC signaling.
- Keep supported hosts on local WebRTC, report signaling/first-frame errors,
  bound automatic reconnects, and add a visible retry action with a short timeout.
- Prefer local OCR for text reading in the device skill and MCP guidance; fetch
  accessibility or images only when their additional evidence is needed.
- Name the embedded phone panel **StupidMirror** instead of the tool action
  **Show Screen**, and align the widget and resource display names.
- Clarify that users can reconnect the plugin or start a new chat after updating;
  restarting Codex does not repair a malformed-capability decoding failure.
- Add regression coverage for raw MCP initialization, tool discovery, capability
  preservation and HTTP authentication.

## 0.3.0 - 2026-10-10

- Bundle a Codex plugin with one-click installation from MCP Automation settings.
  Codex can launch StupidMirror in the background and display the phone inside
  its MCP Apps panel without opening a separate native mirror window.
- Stream native-resolution H.264 video over encrypted, loopback-only WebRTC;
  use PNG snapshots when the host cannot establish video. Add device selection,
  pause/resume, refresh, Home, and screenshot controls.
- Add explicit manual control mode for taps and drags in the embedded preview,
  alongside the existing AI observation and device-control tools.
- Freeze a frame, draw numbered regions, add a note, and send the annotated
  image with device/time/coordinate context to Codex. Annotation mode never
  sends pointer gestures to the phone; delivery depends on host capabilities.
- Keep connection credentials in a private local file, reconnect after port or
  token changes, and clean up inactive video sessions.
- Preserve modern macOS styling by pinning the native Swift build system and
  checking the linked SDK when packaging.
- Update bilingual setup, privacy, architecture, contributor, release and website
  documentation. Extend CI to cover the plugin widget and WebRTC sidecar.


## 0.2.31 - 2026-10-03

- A launch that stalls because the iPhone is waiting for its passcode to
  allow automation (the first session after a restart) now says so while it
  waits and when it gives up, instead of failing as a generic timeout.
- When a phone's tunnel ends (Wi-Fi lost, cable pulled, runner gone), video
  and control reconnect right away through a fresh tunnel instead of freezing
  on a dead port. A replaced tunnel is stopped before the new one starts, so
  one phone never carries two.
- iPhone gestures are about twice as fast: WebDriverAgent no longer snapshots
  the whole app before every tap (measured over USB on an iPhone 15 Pro,
  iOS 27: tap ~900 → ~400 ms). Element lookups still see the full tree.
- Swipes and scrolls lift at the speed they were made with, so lists keep
  their momentum; a double click is one double tap (not three taps); pinch
  and rotate centre on the pointer; control follows rotation immediately.
- A single slow request no longer relaunches the agent, and a lagging device
  drops stale taps and swipes but never typed text or key presses.
- The iPhone setup guide shows why a check failed, can stop a running
  preparation, keeps running it when closed, never shows one phone's state
  for another, and explains how to turn on Developer Mode.
- Release builds verify the bundled `smtunnel` sidecar (present, signed by
  the release team, universal, runs).
- Update the MCP Swift SDK to 0.12.1, which builds with Xcode 26.6.
- Remove unused copy, the old control-setup entry point, and other dead code.

- Rebuild the iOS wireless path on a bundled Go sidecar (`smtunnel`, built on
  go-ios and gVisor's netstack). It reaches the phone through usbmuxd over the
  local network, opens Apple's CoreDeviceProxy tunnel in an in-process network
  stack (no root, no kernel interface), launches the WebDriverAgent runner
  through testmanagerd like an IDE would, and publishes the runner's control
  and video ports on 127.0.0.1. Nothing in the path depends on the installed
  Xcode version's `xcodebuild`/`devicectl` launchers, which stop a runner
  over Wi-Fi on iOS 27, and nothing crosses iOS's Local Network privacy gate,
  which was dropping the direct LAN connections.
- The one-time USB setup now also installs the runner, test-launches it, and
  turns on the phone's Wi-Fi connections (Xcode's "Connect via network"), so
  later sessions need no tap on the phone and no Local Network prompt.
- The runner's SRT stream listens on IPv4 and IPv6, and failures from the
  device tunnel are reported by cause (phone not on the network, developer
  image unmounted, runner not installed) instead of as a generic launch error.
- iPhone control talks to WebDriverAgent directly over the tunnel instead of
  through a local Appium server: one `DeviceControlSession` state machine, a
  `WDAControlBackend` for iOS and an Appium-backed UiAutomator2 backend for
  Android, a bounded coalescing queue for interactive input, and automatic
  rebuild of a session the device dropped. Wired and wireless iPhones share
  the same agent and the same code path.
- Mirror gestures reproduce what the mouse did: a slow drag replays its
  recorded path and timing, holding still is a long press (right click too),
  a double click is a double tap, trackpad pinch and rotate map to the
  device's pinch and rotate, and back is the system edge swipe. XCTest
  replays a gesture only after the mouse is released, so finger-following
  while the button is held is still not possible; see the README note.
- Replace the separate control and wireless guides with one iPhone setup
  guide that reads the phone's real state (USB, Developer Mode, installed
  agent, Wi-Fi connections) through the sidecar and shows each preparation
  step as it runs.

## 0.2.30 - 2026-09-04

- Account-bound licensing: sign in with Google, GitHub, or email (shared iTool
  Supabase Auth); buy an SM- code at https://wzyp.cn/item/exords and redeem it
  onto `auth.uid()`; one-way claim from legacy Keychain receipts; grace for
  v0.2.x install receipts; reject iTool `IT-` codes; remove Xiaohongshu
  purchase QR; admin reset cannot mint a second seat. iTool Pro stays a
  separate entitlement on the same uid.

## 0.2.29 - 2026-09-02

- Restore USB control on iOS 27. A preinstalled runner started through
  `devicectl` never stays up on that version, so control now falls back to the
  cached `xcodebuild test-without-building` session instead of stopping with
  "Failed to start the preinstalled WebDriverAgent".
- Start wireless mirroring on iOS 27 with that same cached XCTest session,
  and raise the 10-minute default test time allowance so the never-ending
  screen agent is not killed after it is already showing video.

## 0.2.28 - 2026-09-01

- Stop tying the wireless screen agent to a Mac `devicectl --console` session.
  That flag waits for the app to exit and forwards a dropped CoreDevice tunnel
  into a kill of WebDriverAgent — the agent would work for a while, vanish,
  then get relaunched or reinstalled. Launch is now detached; readiness is
  `/status` on the device's own addresses, including the CoreDevice tunnel
  used to learn the LAN IP.
- Reuse an already-installed agent on both USB and Wi-Fi. Control attaches to a
  runner that is already answering, wireless only reinstalls when the app is
  actually missing, and a refused connection or timeout no longer falls through
  to xcodebuild.

## 0.2.27 - 2026-09-01

- Stop concurrent wireless agent launches from terminating each other. Launching
  passed `--terminate-existing`, so mirroring, control, and retries killed each
  other's WebDriverAgent when they targeted the same iPhone. The losing side
  waited for a runner that no longer existed, then reinstalled a runner that was
  never broken — the cause of wireless starts that hung for minutes, reinstalled
  the agent for no reason, and still failed. One launch per device is now shared.
- Report iOS 27's agent launch failure accurately instead of claiming the iPhone
  is locked. On that version a runner started through `devicectl` is stopped by
  XCTest before its HTTP server starts, on an unlocked and reachable device.
- Stop reinstalling the agent for failures a reinstall cannot fix, and read the
  device's own explanation before giving up. Together these turn a 64-second
  wrong answer into a 32-second correct one.
- Tell apart an agent that is not running from an iPhone that is refusing the
  connection, and name the Local Network setting when that is the real cause.
- Shorten the readiness waits. A healthy agent answers in seconds, so the old
  45-second budgets only stretched failures that do not improve with time.

## 0.2.26 - 2026-08-31

- Add a direct online purchase link in the
  activation window.
- Add the same activation-code purchase entry to the GitHub Pages landing page
  and refresh its public download link for this release.

## 0.2.25 - 2026-08-28

- Improve wireless iPhone reconnect handling and keep Android control sessions
  alive during idle use.

## 0.2.24 - 2026-08-28

- Add a screenshot button to the standalone mirror window that copies the
  latest mirrored device frame directly to the macOS clipboard.

## 0.2.23 - 2026-08-25

- Discover wired iPhone identifiers through Apple's bundled `devicectl`, so
  USB control no longer requires users to install `libimobiledevice` with
  Homebrew. Keep the legacy tools only as an optional compatibility path.

## 0.2.22 - 2026-08-25

- Keep iPhone control on the USB path when a wired mirror session retains
  metadata from an earlier wireless connection, instead of reporting that the
  device is unavailable over Wi-Fi.

## 0.2.21 - 2026-08-23

- USB iPhone mirroring still moves sound off the phone speaker, the same way
  QuickTime does. Turn on Mac Audio to hear it on this Mac.
- Android keeps the phone speaker when Mac Audio is off. On Android 13+,
  turning it on plays here and also keeps the phone speaker.

## 0.2.20 - 2026-08-22

- USB iPhone mirroring keeps sound on the phone by default. Turning on Mac
  playback now uses the muxed screen audio track instead of the iPhone
  microphone.
- Wireless iPhone sessions are no longer replaced by USB while the cable is
  still plugged in, and a failed device poll no longer leaves an unplugged
  USB session marked connected.

## 0.2.19 - 2026-08-14

- Play USB iPhone audio through the Mac using the matched iPhone audio input,
  without QuickTime.

## 0.2.18 - 2026-08-14

- Fix iPhone USB mirroring so the phone speaker stays active by disabling the
  muxed capture source audio input port.

## 0.2.17 - 2026-08-14

- Replace the license purchase QR placeholder with the Xiaohongshu purchase
  QR code.

## 0.2.13 - 2026-08-12

- Keep the Camera permission action visible while an Android or wireless device
  is connected, so USB iPhone discovery and first-time wireless preparation
  cannot become blocked behind the active-device view.
- Narrow standalone mirror resize hit regions to the outer 6 points, leaving the
  rest of the title bar available for reliable click-and-drag window movement.

## 0.2.12 - 2026-08-12

- Add Android 11+ discovery through ADB with direct H.264 mirroring and optional
  raw device-audio playback through a pinned scrcpy server.
- Add Android control through the bundled Appium UiAutomator2 driver, including
  pointer gestures, text editing, hardware-style keys, semantic UI inspection,
  and app lifecycle actions across the desktop UI and MCP harness.
- Verify pinned UiAutomator2 and scrcpy runtime versions and checksums in release
  packaging, while retaining the existing iOS XCUITest control path.
- Probe cached Appium sessions before MCP reconnects so a restarted server or
  device-side runner self-heals instead of leaving Android control falsely ready.

## 0.2.11 - 2026-08-12

- Make routine Agent navigation read the live mirror first, batch multiple text candidates into one OCR and Accessibility lookup, and avoid repeated slow negative WDA queries.
- Add verified native `clear_text` and `replace_text` actions for the active iOS input without invoking selection menus or guessing delete coordinates.
- Add non-destructive clickable-element and selected-element overlays so every visible target can be reviewed on the Mac before an action is sent.
- Publish a responsive GitHub Pages product site with direct access to the notarized macOS release.
- Replace the MIT license with PolyForm Noncommercial 1.0.0 so personal and noncommercial use remains free while commercial use requires separate written authorization.

## 0.2.9 - 2026-08-11

- Replace the wireless video fallback stack with a complete-access-unit H.264 transport over pinned SRT libraries, including stricter frame reassembly and VideoToolbox decoding.
- Follow Xcode/CoreDevice tunnel endpoints, expose detailed wireless startup progress, and retry only transient Agent launch failures.
- Read available signing teams from the user's live Xcode account configuration, automatically prefer an appropriate team without fixed account IDs, and coalesce concurrent detection requests.
- Allow an unactivated installation to control one mirrored iPhone while continuing to reserve simultaneous multi-device control for activated installations.

## 0.2.8 - 2026-08-11

- Add an independent, localized wireless setup guide that detects USB and signing readiness, prepares the wireless screen agent without enabling control, and then runs active discovery.
- Preserve paired devices across cable disconnects, and allow devices to be removed and rediscovered when connected again.
- Add a full-resolution wireless H.264 path with iPhone-side VideoToolbox encoding, Mac-side VideoToolbox decoding, a 45 FPS target, and automatic MJPEG fallback.
- Keep wireless mirroring independent from control: starting a mirror no longer prepares control, while explicit control actions still launch the Agent when requested.
- Limit unactivated installations only to one mirrored device and disabled control; keep wireless mirroring, diagnostics, settings, device removal, and other non-control features available.
- Improve light-appearance contrast and shorten license validation errors so status messages no longer crowd the layout.

## 0.2.5 - 2026-08-10

- Replace the translucent Agent loading material with an opaque adaptive surface and dimmed phone backdrop so every loading message stays readable over any mirrored content.
- Use light/dark adaptive accent, success, pending, danger, and control colors across status labels, badges, buttons, and MCP errors.
- Add automated contrast regression coverage for both appearances, requiring normal text and all loading-overlay label levels to meet at least a 4.5:1 contrast ratio.

## 0.2.4 - 2026-08-10

- Show an immediate, cancelable Agent loading card with the current startup phase, elapsed time, and realistic reuse or first-install expectations.
- Prefer and clearly communicate reuse of the Agent already installed on the iPhone, only switching the UI to installation when reuse fails.
- Keep loading feedback visible in both the dashboard preview and standalone mirror window, with localized Chinese and English guidance to keep the iPhone unlocked and connected.

## 0.2.3 - 2026-08-10

- Preserve trailing toolbar safe space so the activation badge stroke and shadow are not clipped at the right edge.

## 0.2.2 - 2026-08-10

- Stabilize real-device Agent startup by reusing an installed WebDriverAgent first, keeping a single Appium-owned launch attempt, and preventing timed-out fallback requests from leaving overlapping WDA builds behind.
- Keep Agent startup within the MCP request budget while preserving enough launch headroom for slower physical iPhones.
- Add compact text captions to the toolbar, use a clearer network icon for MCP, and place activation immediately to the right of MCP.

## 0.1.5 - 2026-08-10

- Make Camera and optional Microphone permission requests explicit, deduplicated, and stable across upgrades by pinning the production app identity.
- Bound video-frame, thumbnail, disconnected-device, and metadata-refresh memory/resource usage.
- Serialize capture teardown and wait for Appium sessions and managed subprocesses during app termination.
- Isolate WebDriverAgent ports and DerivedData per device, and prevent stale connection/action tasks from overwriting newer sessions.
- Keep the dashboard usable while resizing with a screen-aware minimum window size and device details that no longer collide with the toolbar.
- Harden release signing for the bundled Node/Appium runtime and require notarization, stapling, and Gatekeeper validation before public upload.

## 0.1.0

- Initial open-source preparation.
- Native macOS menu bar app for USB iPhone mirroring.
- Device dashboard, thumbnails, diagnostics, and settings.
- Standalone mirror windows with optional Appium/WebDriverAgent control.
- Local probes for AVFoundation, device discovery, frame capture, and WDA readiness.
