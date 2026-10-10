# Privacy

StupidMirror mirrors connected iOS and Android devices locally on macOS.

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
- Optional Google, GitHub, or email sign-in through the shared iTool Supabase Auth project. The resulting
  session tokens and the account user id are stored in the macOS Keychain.

## Network Behavior

Capture and OCR stay on the Mac. When you enable MCP, an external AI client can
receive requested screenshots, OCR results, device identifiers, and action results.
In Codex, sending an annotation includes a frozen PNG with the selected regions
drawn on it and your note in the current chat. That client's model provider
and data settings govern the information it receives.

The embedded preview uses H.264 over encrypted WebRTC between the local app and
host panel, with loopback ICE candidates only and no STUN/TURN or cloud relay.
PNG snapshots are the fallback. This video path does not prevent the AI host from
processing images explicitly requested through tools or sent as annotations.

The local MCP bearer token is stored in Keychain and exported while the service
is running to a private connection file (0700 directory, 0600 file). The bundled
stdio bridge reads it locally; the widget and plugin manifests contain no token.

Wireless mirroring receives screen frames directly from WebDriverAgent on the
same local network. The preferred stream is hardware-encoded H.264; MJPEG is
used only as a compatibility fallback. Neither path requires ReplayKit or an
iPhone companion app.

iOS control talks to WebDriverAgent through a local device tunnel. Android
control talks to the configured Appium server URL. The default
is `http://127.0.0.1:4723`.

License activation, redeem, claim, and periodic validation send the random
installation identifier, activation code (only while redeeming), activation
receipt, app version, and — for buy/redeem/claim/account checks — the signed-in
user's Supabase access token to the configured StupidMirror license endpoint
hosted on Supabase. Google and GitHub only receive the OAuth sign-in; email/password stays with Supabase Auth. Screen
frames, thumbnails, iPhone metadata, control events, and typed text are not
included in license requests.

An unclaimed Mac-bound Keychain receipt can keep paid features working for a
limited grandfather period without signing in. After the license is claimed or
redeemed onto an account, the account is the principal; signing out stops paid
features on that Mac until the same account signs in again. Free one-device
mirroring does not require a session. Activated installations can continue to
work from a locally cached account or grandfathered receipt when the license
endpoint is temporarily unavailable.

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

USB iPhone capture may expose an audio track through the same local AVFoundation
source. StupidMirror disables that muxed audio port by default so iOS keeps
playback on the iPhone speaker. It only enables, attaches, and plays the track
on the Mac when the user turns on device audio. macOS requires Microphone
permission for that optional audio track. The app asks for Camera or Microphone
access only after an explicit user action.

## User Responsibility

Mirrored screens can contain sensitive information. Be careful when sharing
screenshots, probe output, recordings, or logs.
