# OpusOGGContainer

Xcode workspace containing:

- **`OpusOGG`** — Swift framework for **Opus-in-Ogg** (RFC 7845): PCM ↔ Opus ↔ Ogg using **Combine** publishers (`multicast` + `autoconnect`).
- **`OpusOGGContainer`** — Demo app: record → encode → `.ogg` file → decode → play (VoiceAudioKit + `OpusOGG`).
- **`OpusOGGTests`** — Unit tests for round-trip encode/decode and configuration errors.

## Documentation

See **[Documentation/OpusOGG.md](Documentation/OpusOGG.md)** for API usage, threading, preskip, dependencies, tests, and **xcframework packaging** (`.swiftinterface` enabled for broader Xcode compatibility).

## Quick test

```text
xcodebuild test -scheme OpusOGG -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OpusOGGTests
```

Use a simulator name or `id=` that exists on your Mac (`xcrun simctl list devices available`).
