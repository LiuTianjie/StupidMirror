# Changelog

## Unreleased

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
