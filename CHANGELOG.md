# Changelog

## Unreleased

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
