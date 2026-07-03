# Privacy

StupidMirror mirrors a connected iPhone screen locally on macOS.

## Data Processed Locally

The app may process:

- iPhone screen frames exposed by macOS through AVFoundation.
- Device names, product identifiers, OS versions, and UDIDs when available.
- Optional Appium/WebDriverAgent control events such as taps, swipes, and typed
  text.
- Local thumbnails used in the dashboard.

## Network Behavior

StupidMirror does not intentionally upload screen frames, thumbnails, device
metadata, or control events to a remote service.

Optional control support talks to the configured Appium server URL. The default
is `http://127.0.0.1:4723`.

## Permissions

macOS exposes USB iPhone screen sources through AVFoundation capture APIs, so the
app needs Camera permission. This permission is used to read the iPhone screen
source, not to capture a Mac webcam.

## User Responsibility

Mirrored screens can contain sensitive information. Be careful when sharing
screenshots, probe output, recordings, or logs.
