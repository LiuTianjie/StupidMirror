# Security Policy

## Supported Versions

StupidMirror is experimental. Security fixes should target the main branch unless
the project later publishes versioned releases.

## Reporting a Vulnerability

Please do not open a public issue for vulnerabilities that expose private screen
content, device identifiers, local credentials, or control-session data.

Open a private security advisory on GitHub if available, or contact the project
maintainer through the repository owner profile.

## Privacy Model

StupidMirror is intended to run locally:

- Mirrored screen frames are rendered locally.
- Device metadata is used locally for matching and display.
- Optional control support sends commands only to the configured Appium server
  URL, which defaults to localhost.

Please treat screenshots, logs, and probe output as potentially sensitive. They
may include device names, UDIDs, app content, or local environment details.
