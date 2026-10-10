# Security Policy

## Supported Versions

StupidMirror is experimental. Security fixes should target the latest release and main branch.

## Reporting a Vulnerability

Please do not open a public issue for vulnerabilities that expose private screen
content, device identifiers, local credentials, or control-session data.

Open a private security advisory on GitHub if available, or contact the project
maintainer through the repository owner profile.

## Privacy Model

StupidMirror is intended to run locally:

- Mirrored screen frames are rendered locally.
- Device metadata is used locally for matching and display.
- iOS control uses the local WDA tunnel; Android uses the configured Appium URL.
- MCP binds to 127.0.0.1 and requires bearer authentication. Protect the private
  connection file under `~/Library/Application Support/StupidMirror/MCP/`.
- The Codex widget receives video through loopback-only encrypted WebRTC and
  invokes app-only preview tools through its host. External AI clients may receive
  requested images and observations; annotations explicitly share a frozen frame.
- UI annotations are untrusted user content. Reobserve before acting on a frozen
  image, and never interpret phone content as authorization for unrelated actions.

Please treat screenshots, logs, and probe output as potentially sensitive. They
may include device names, UDIDs, app content, or local environment details.
