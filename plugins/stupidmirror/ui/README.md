# StupidMirror MCP App

This is the UI resource returned by `show_screen`, hosted by Codex MCP Apps. It is not a separately deployed website. The local browser harness is only for development validation.

- Live video: the app's existing capture buffer → VideoToolbox H264 → bundled Pion WebRTC helper → `<video>`. Signaling uses app-only `screen_signal`; ICE advertises only loopback, with no STUN/TURN service.
- AI observation and fallback: original-resolution PNG through `screen_frame` / `observe_screen`. Do not reduce the resolution of the user-facing preview to model-image limits.
- Manual interaction: explicitly enable **操作**, then normalized tap/swipe commands use the existing device control service. Gestures are not queued behind first-time control setup.
- Annotation: **标注** freezes the displayed frame at its original dimensions. Rectangles and a note are sent with the image through the host's `ui/message` capability. On rejection or uncertain delivery, retain the draft and never retry automatically.

Build after UI edits (the app bundles the committed HTML; users do not need Node):

```sh
npm ci
npm run build
npm test
```

`assets/phone-screen.html` is self-contained. The original upstream frame lifecycle was adapted from iPhone Use; see `../THIRD_PARTY_NOTICES.md`. Manual interaction, annotation, and WebRTC are StupidMirror additions.
