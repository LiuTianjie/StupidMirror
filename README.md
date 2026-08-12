# StupidMirror

StupidMirror is a native macOS menu bar app for mirroring an iPhone over USB or,
after one USB setup, the same local network. USB video uses the iPhone screen
source exposed by macOS through CoreMediaIO and AVFoundation. Wireless video
reuses an Xcode-signed WebDriverAgent build: VideoToolbox encodes its
full-resolution screen frames as H.264 on the iPhone, SRT transports complete
access units over the LAN, and the Mac decodes them with VideoToolbox.

> This project is experimental. It depends on private-feeling system behavior:
> macOS exposes the iPhone screen as an AVFoundation capture source, which means
> the app needs Camera permission even though it is not trying to use a webcam.

## Features

- USB iPhone screen source discovery through CoreMediaIO/AVFoundation.
- Optional wireless discovery through Apple's `devicectl`, with no custom or
  private device transport implementation.
- High-quality wireless H.264 mirroring over the local network, without a
  ReplayKit Broadcast Extension or companion iPhone app.
- Menu bar dashboard with device list, thumbnails, diagnostics, and settings.
- Standalone mirror windows with device-ratio sizing.
- Chinese and English UI copy.
- Optional Appium/XCUITest control support for tap, swipe, text input, clipboard
  paste, Home, and app switcher actions.
- Bundled Mac-side Appium runtime for packaged release builds.
- Free one-device mirroring with one-time activation for simultaneous
  multi-device mirroring and iPhone control. Activation uses a private Supabase
  license service; the purchase QR area is currently an explicit placeholder.
- Local probes for AVFoundation discovery, frame capture, device discovery, and
  WebDriverAgent readiness.

## Requirements

- macOS 15 or newer.
- Xcode or the Swift toolchain with Swift 6 support.
- An iPhone that trusts this Mac. USB is required for initial wireless setup.
- Camera permission for the packaged app or the terminal process running
  `swift run`.
- Optional Microphone permission if iPhone audio should play through the Mac.
- Optional control support: iPhone trust, Developer Mode/UI Automation, and a
  WebDriverAgentRunner that the Mac app can install or start through its bundled
  Node/Appium/XCUITest runtime.

## Quick Start

Run from source:

```sh
make run
```

Build without launching:

```sh
make build
```

Create a local `.app` bundle:

```sh
make app
open dist/StupidMirror.app
```

The packaged app runs as a menu bar utility and does not stay in the Dock.

Build and upload a local GitHub Release artifact:

```sh
gh auth login
make release-local
```

This reads `VERSION`, creates `dist/releases/StupidMirror-vX.Y.Z-macos.zip`, and
uploads it to the matching GitHub Release. If the release already exists, the
artifact is replaced.

Bump the version and release in one step:

```sh
make release-local BUMP=patch
make release-local BUMP=minor
make release-local BUMP=major
make release-local BUMP=0.2.0
```

With `BUMP`, the script updates `VERSION`, commits the release, creates an
annotated tag, pushes the branch and tag, then uploads the zip.

For a locally signed and notarized release:

```sh
xcrun notarytool store-credentials stupidmirror-notary

SIGN_IDENTITY="Developer ID Application: Gaojiua Technology (Beijing) Co., Ltd. (L95PYLFT86)" \
VERSION="0.1.0" \
BUILD_NUMBER="1" \
NOTARY_PROFILE="stupidmirror-notary" \
make release-local
```

Distributed releases have a fixed identity: bundle ID `com.gaojiua.StupidMirror` and
Apple Team `L95PYLFT86`. The release script rejects identity drift before upload
so macOS does not treat an update as a different app and ask for permissions
again.

Release builds are signed with `StupidMirror.entitlements` by default. Camera
and audio-input entitlements are required. The bundled Node runtime is signed
separately with the JIT entitlements in `NodeRuntime.entitlements`; the release
script verifies all nested Mach-O code without relying on `codesign --deep`.

Release uploads require `NOTARY_PROFILE`. After notarization, the script staples
the ticket and validates the app with `codesign`, `stapler`, Gatekeeper, and
`syspolicy_check`. `ALLOW_UNNOTARIZED=true` is only for private test artifacts.

## Permissions

StupidMirror checks Camera and Microphone status without prompting at launch.
macOS permission prompts are requested only after you click the corresponding
in-app button, and an in-flight request disables that button so it cannot be
requested twice concurrently.

Camera access is required because macOS exposes USB iPhone screen sources
through AVFoundation camera capture APIs. Microphone access is optional and is
used only for the iPhone audio track. If Microphone access is declined, video
mirroring remains available and new mirror sessions do not attach audio.

Wireless mode does not require Camera permission. Enable it under Settings,
then keep the Mac and iPhone on the same local network. The first setup for each
iPhone must be completed over USB: open the independent Wireless Setup Guide,
which checks the connected device and Apple development account before signing
and caching the screen agent. This does not connect or enable iPhone control.
Later wireless sessions wake the Xcode-paired device with `devicectl`, start the
cached XCUITest runner, and read WDA through the Apple CoreDevice hostname
returned by `devicectl`. The iPhone-side Bonjour permission prompt is therefore
not treated as a required startup gate.
Wireless audio is not currently available.

If permission is denied:

1. Open System Settings.
2. Go to Privacy & Security -> Camera.
3. Enable StupidMirror, or enable the terminal app if running with `make run`.
4. Return to StupidMirror and use the in-app permission recheck button.

To restore optional audio after declining it, enable StupidMirror under Privacy
& Security -> Microphone, return to the app, and recheck the permission.

## Optional iPhone Control

Packaged Mac builds include a local Appium/XCUITest runtime at
`StupidMirror.app/Contents/Resources/Appium`. Click **Connect** in StupidMirror;
the app checks the local service and starts the bundled runtime if needed. A
live control session stays warm briefly when the user disconnects, so an
immediate reconnect does not recreate WebDriverAgent. After an app restart,
StupidMirror reuses this Mac's per-device WDA build cache without compiling it
again; only a genuinely missing cache falls back to launching an installed WDA
or performing the first build and install. Reuse does not require a Team ID.
When a first installation is required, StupidMirror detects valid Apple
Development signing teams from the Mac automatically; manual Team ID entry
remains available under the setup guide and advanced control settings.

Control is explicit: opening a mirror window never installs the control agent by
itself. WebDriverAgentRunner still needs valid signing before real-device
control can work, and the iPhone must trust this Mac with Developer Mode/UI
Automation enabled.

For source development, you can still use the host Appium install:

```sh
make setup-appium
make run-appium
```

## AI Harness through MCP

StupidMirror does not embed an AI model, require a model API key, or upload the
iPhone screen to a model provider. Instead, its localhost MCP server exposes a
device harness that external agents such as Codex or Claude can use with the
user's existing account and privacy settings.

The preferred agent loop is:

1. `list_devices`, then `start_mirror` and `connect_control` as needed.
2. `observe_screen` to receive the newest live mirror frame plus parsed
   hierarchical accessibility elements. Set `include_ocr` when fused local
   text recognition is useful. Neither path triggers another WDA screenshot.
3. `find_element` checks Accessibility first and falls back to Apple Vision OCR
   on the Mac only when needed. `tap_element` refreshes and clicks a native WDA
   element when possible; normalized coordinates remain the visual fallback.
4. `wait_for` and `assert_screen` for deterministic completion checks.

`tap_element` accepts the observation UUID so an agent can reject stale element
identifiers after the screen changes. Element actions and raw control tools are
marked as potentially destructive in MCP metadata because their real-world
effect depends on the visible iPhone UI.

Accessibility elements include source, parent/child identifiers, depth, path,
state, screen-point frame, and normalized frame. OCR elements use
`source: "ocr"` and add a confidence score. OCR runs through
`VNRecognizeTextRequest` locally with `fast` and `accurate` modes; Chinese and
English are the defaults, and agents can pass other Vision language identifiers.
Recognition is on-demand, single-flight, and briefly cached. It reads the
newest retained frame without changing the wireless 45 FPS stream or entering
the capture/encoding hot path.

Actions invoked through the AI harness are visible in StupidMirror: semantic
targets are boxed, taps are marked, swipes show their path and direction, and
non-positional actions display a short `AI` notice. This overlay is rendered by
the Mac UI only. It is not burned into the iPhone frame, sent to the device, or
processed by the video encoder; direct manual mirror interactions are not
labelled as AI actions.

## Probes

Run probes from the repo root:

```sh
make probe-devices
make probe-avfoundation
make probe-avfoundation-frame
make probe-pymobiledevice3
make probe-wda
```

The probes inspect the host and connected devices. `make probe-avfoundation-frame`
writes one local screenshot frame to `artifacts/`, which is ignored by git.

## Development

Useful commands:

```sh
swift build
swift test
make app
```

The app bundle is written to `dist/StupidMirror.app`.

## Privacy

StupidMirror runs locally. The app does not intentionally upload mirrored screen
content, thumbnails, device metadata, or control events to any remote service.
Optional Appium control talks to the configured Appium server URL, which defaults
to `http://127.0.0.1:4723`.

License activation sends only the random installation ID, entered activation
code, app version, and the returned receipt to the Supabase license endpoint.
It never includes mirrored frames, thumbnails, iPhone identifiers, or control
input. See [PRIVACY.md](PRIVACY.md) for details.

## Documentation

- [MVP architecture](docs/mvp-architecture.md)
- [Research notes](docs/research.md)
- [Security policy](SECURITY.md)
- [Contributing guide](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- [Release process](RELEASING.md)
- [License activation and local code generator](LICENSING.md)

## License

MIT. See [LICENSE](LICENSE).
