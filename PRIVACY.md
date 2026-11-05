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
- A membership cache in the macOS Keychain after a successful check: the
  account user id, the membership end date and tier, and the server time of the
  check. Signing out deletes it. Macs upgraded from 0.7.x may keep an unused
  legacy installation identifier and activation receipt, which 0.8.0 never reads
  or sends.
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

Membership checks send the signed-in user's Supabase access token and the
product name `stupidmirror` to `https://itool.tech/api/membership/entitlement`,
or, when that route is unavailable, to the iTool Supabase project's
`itool_entitlement` function. The answer contains the membership tier and end
dates. Google and GitHub only receive the OAuth sign-in; email/password stays
with Supabase Auth. Screen frames, thumbnails, device metadata, control events,
and typed text are never part of these requests. Free one-device use sends no
membership request and needs no account.

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
