# Privacy

StupidMirror mirrors a connected iPhone screen locally on macOS.

## Data Processed Locally

The app may process:

- iPhone screen frames exposed by macOS through AVFoundation.
- The optional iPhone audio track exposed through the same local capture source.
- Device names, product identifiers, OS versions, and UDIDs when available.
- Optional Appium/WebDriverAgent control events such as taps, swipes, and typed
  text.
- Local thumbnails used in the dashboard.
- A random StupidMirror installation identifier and an activation receipt stored
  in the macOS Keychain. Upgraded installations may retain unused legacy trial
  timestamps. These values are not an iPhone UDID, Mac serial number, or
  advertising identifier.

## Network Behavior

StupidMirror does not intentionally upload screen frames, thumbnails, device
metadata, or control events to a remote service.

Wireless mirroring receives screen frames directly from WebDriverAgent on the
same local network. The preferred stream is hardware-encoded H.264; MJPEG is
used only as a compatibility fallback. Neither path requires ReplayKit or an
iPhone companion app.

Optional control support talks to the configured Appium server URL. The default
is `http://127.0.0.1:4723`.

License activation and periodic validation send the random installation
identifier, activation code (only while activating), activation receipt, and app
version to the configured StupidMirror license endpoint hosted on Supabase.
Screen frames, thumbnails, iPhone metadata, control events, and typed text are
not included in license requests. Activated installations can continue to work
from the locally cached receipt when the license endpoint is temporarily
unavailable.

The license endpoint also applies abuse rate limits using the request's network
address. Before a rate-limit identifier reaches the licensing database, the Edge
Function transforms it with a server-secret HMAC. The licensing tables never
store a plaintext network address; their short-lived rate-limit buckets are
eligible for bounded cleanup after two days. Supabase may separately process
normal request metadata as the hosting provider.

## Permissions

macOS exposes USB iPhone screen sources through AVFoundation capture APIs, so the
app needs Camera permission. This permission is used to read the iPhone screen
source, not to capture a Mac webcam.

Microphone permission is optional and is used only to receive the connected
iPhone's audio track. Declining it does not block video mirroring; StupidMirror
leaves audio disconnected. The app checks permission state at launch but only
asks macOS for Camera or Microphone access after an explicit user action.

## User Responsibility

Mirrored screens can contain sensitive information. Be careful when sharing
screenshots, probe output, recordings, or logs.
