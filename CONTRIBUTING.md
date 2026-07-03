# Contributing

Thanks for taking a look at StupidMirror.

## Development Setup

Requirements:

- macOS 15 or newer.
- Xcode or Swift 6 toolchain.
- A USB-connected iPhone for end-to-end mirror testing.

Common commands:

```sh
swift build
swift test
make app
```

Optional control setup:

```sh
make setup-appium
make run-appium
```

## Pull Requests

Please keep pull requests focused. A good PR usually includes:

- A short description of the user-visible behavior change.
- Notes about manual device testing, if the change touches mirroring or control.
- Tests for pure Swift logic where practical.

Before opening a PR, run:

```sh
swift test
make app
```

Maintainers can create signed local release uploads with:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="stupidmirror-notary" \
make release-local BUMP=patch
```

See [RELEASING.md](RELEASING.md) for notarization setup and release options.

## Device and Permission Notes

The app needs Camera permission because USB iPhone screen sources are exposed
through AVFoundation capture APIs. Contributors testing permission flows should
check both the packaged app and `swift run`, because macOS stores permissions per
binary/app identity.

## Code Style

- Prefer small, direct SwiftUI/AppKit changes over broad rewrites.
- Keep device/control behavior conservative; avoid hidden network calls.
- Do not commit generated output from `.build/`, `dist/`, or `artifacts/`.
