# StupidMirror

StupidMirror is a native macOS menu bar app for mirroring a USB-connected iPhone.
It discovers the iPhone screen source exposed by macOS through CoreMediaIO and
AVFoundation, opens each device in a standalone floating mirror window, and can
optionally forward basic touch and keyboard actions through a Mac-managed
Appium/WebDriverAgent control agent.

> This project is experimental. It depends on private-feeling system behavior:
> macOS exposes the iPhone screen as an AVFoundation capture source, which means
> the app needs Camera permission even though it is not trying to use a webcam.

## Features

- USB iPhone screen source discovery through CoreMediaIO/AVFoundation.
- Menu bar dashboard with device list, thumbnails, diagnostics, and settings.
- Standalone mirror windows with device-ratio sizing.
- Chinese and English UI copy.
- Optional Appium/XCUITest control support for tap, swipe, text input, clipboard
  paste, Home, and app switcher actions.
- Bundled Mac-side Appium runtime for packaged release builds.
- Three-day trial and one-time activation through a private Supabase license
  service; the purchase QR area is currently an explicit placeholder.
- Local probes for AVFoundation discovery, frame capture, device discovery, and
  WebDriverAgent readiness.

## Requirements

- macOS 15 or newer.
- Xcode or the Swift toolchain with Swift 6 support.
- A USB-connected iPhone that trusts this Mac.
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
