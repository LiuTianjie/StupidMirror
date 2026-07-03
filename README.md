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
- Local probes for AVFoundation discovery, frame capture, device discovery, and
  WebDriverAgent readiness.

## Requirements

- macOS 15 or newer.
- Xcode or the Swift toolchain with Swift 6 support.
- A USB-connected iPhone that trusts this Mac.
- Camera permission for the packaged app or the terminal process running
  `swift run`.
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

SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BUNDLE_ID="com.example.StupidMirror" \
VERSION="0.1.0" \
BUILD_NUMBER="1" \
NOTARY_PROFILE="stupidmirror-notary" \
make release-local
```

Release builds are signed with `StupidMirror.entitlements` by default. Keep the
camera entitlement enabled; without it, Developer ID + Hardened Runtime builds
cannot register StupidMirror in Privacy & Security -> Camera.

If `NOTARY_PROFILE` is omitted, the script still builds, signs, zips, and uploads
the app, but it skips Apple notarization.

## Permissions

When first launched, macOS may ask whether StupidMirror can access the camera.
Allowing this is required because macOS exposes USB iPhone screen sources through
AVFoundation camera capture APIs.

If permission is denied:

1. Open System Settings.
2. Go to Privacy & Security -> Camera.
3. Enable StupidMirror, or enable the terminal app if running with `make run`.
4. Return to StupidMirror and use the in-app permission recheck button.

## Optional iPhone Control

Packaged Mac builds include a local Appium/XCUITest runtime at
`StupidMirror.app/Contents/Resources/Appium`. Click **Connect** in StupidMirror;
the app checks the local service, starts the bundled runtime if needed, tries to
reuse an already-installed WebDriverAgent first, and installs it only when reuse
is not available.

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

## Documentation

- [MVP architecture](docs/mvp-architecture.md)
- [Research notes](docs/research.md)
- [Security policy](SECURITY.md)
- [Contributing guide](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- [Release process](RELEASING.md)

## License

MIT. See [LICENSE](LICENSE).
