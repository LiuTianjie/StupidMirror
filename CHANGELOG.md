# Changelog

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

- Add a direct online purchase link below the Xiaohongshu QR code in the
  activation window.
- Add the same activation-code purchase entry to the GitHub Pages landing page
  and refresh its public download link for this release.

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
