# OpusOGG

Swift framework wrapping **libopus** + **libogg** for **Opus-in-Ogg** (RFC 7845): encode PCM to Ogg pages and decode back to PCM. The public API is **Combine-only** (`multicast` + `autoconnect`); there is no `AsyncStream`.

## Requirements

- iOS 17.6+ (project deployment target)
- **Consumer Xcode**: Prefer **the same or newer** Swift toolchain than the one used to build `OpusOGG.xcframework`. The prebuilt binary ships **`.swiftinterface`** (see `SWIFT_EMIT_MODULE_INTERFACE = YES` on the OpusOGG target) so importers can use the textual module when the `.swiftmodule` blob is too new — but Swift still has **limits**; if an older Xcode errors with “compiled with a different version of Swift”, **rebuild the xcframework with that older Xcode** (or the oldest Xcode your team supports).
- Bundled `libopus` / `libogg` XCFrameworks under `OpusOGG/Frameworks/` (see `Scripts/ogg_opus_xcframeworks.sh`) — used **only to link** the static libraries into `OpusOGG.framework`.

### C interop without a Swift bridging header (recommended for xcframework)

**Swift frameworks that ship as xcframeworks should not use `SWIFT_OBJC_BRIDGING_HEADER`**, or consumers and Xcode’s **bridging header dependency scan** may fail with missing `opus/opus.h` when paths differ from the machine that built the binary.

This repo uses a small **Clang module** instead:

- `OpusOGG/CModules/opusogg/module.modulemap` + `opusogg_umbrella.h` define the **`opusogg`** module (opus + ogg public APIs + `opusogg_encoder_set_bitrate`).
- Vendored headers live under **`OpusOGG/CHeaders`** (`opus/`, `ogg/`).
- The OpusOGG target sets **`OTHER_SWIFT_FLAGS`** to `-fmodule-map-file=...` and `-I$(SRCROOT)/OpusOGG/CHeaders`. Encoder/decoder sources use **`@_implementationOnly import opusogg`** so consumers that only **`import OpusOGG`** do not need those flags (the `opusogg` Clang module stays an implementation detail of the framework).

**C helpers** (`OpusOGGHelpers.c`) only `#include "opus/opus.h"`; **`HEADER_SEARCH_PATHS`** remains `$(SRCROOT)/OpusOGG/CHeaders`.

If you bump libopus/libogg, refresh `OpusOGG/CHeaders` from the same headers inside the rebuilt `libopus.xcframework` / `libogg.xcframework`.

### Consuming the prebuilt `OpusOGG.xcframework` only

Link **`OpusOGG.xcframework`** and use **`import OpusOGG`**. Do **not** add any OpusOGG Swift sources to your app, and **do not** set **`SWIFT_OBJC_BRIDGING_HEADER`** to any OpusOGG header — the framework is built without a bridging header.

## Module overview

| Type | Role |
|------|------|
| `OpusOGGEncoder` | Int16 interleaved PCM → Opus packets → Ogg pages (`OpusOGGEncodedPage`) |
| `OpusOGGDecoder` | Ogg bytes (file or stream) → Opus decode → Int16 interleaved PCM (`OpusOGGDecodedPCM`) |
| `OpusOGGEncoderParameters` | Sample rate, channels (1–2), samples per frame, bitrate, Opus application |
| `OpusOGGError` | Opus/Ogg failures and container errors (`missingIdentificationHeaders`, etc.) |

## Encoder

1. Create `OpusOGGEncoder(parameters:)` (throws if configuration is invalid).
2. **Subscribe** to `publisher` **before** or when you start feeding PCM (identification pages are buffered internally until the first real encode so they are not dropped by `PassthroughSubject`).
3. Call `appendPCM(_:)` with **interleaved Int16** PCM. Data is framed in multiples of `samplesPerFrame × channels × 2` bytes; incomplete tails are held until more data arrives.
4. Call `finish()` once to pad the last frame with silence, mark EOS, flush Ogg, and complete the publisher.

Supported encoder sample rates: **8 / 12 / 16 / 24 / 48 kHz**. Typical voice: **48 kHz**, mono, **960** samples per frame (20 ms).

`OpusHead` uses a fixed **preskip** of 3840 (48 kHz samples) as required for decoder delay; `OpusTags` carries a minimal vendor string.

## Decoder

1. Create `OpusOGGDecoder()`.
2. Subscribe to `publisher`.
3. Call `appendOggBytes(_:)` with chunks of a file or network stream (can be called multiple times).
4. Call `finish()` when input ends; the publisher completes with `.finished`.

The decoder expects **OpusHead** then **OpusTags** before audio packets (RFC order). Output `OpusOGGDecodedPCM` is **little-endian Int16**, interleaved, at **48 kHz** (native Opus decode rate). **Preskip** samples from the header are discarded before emission.

## Combine threading

- `appendPCM`, `appendOggBytes`, and `finish` run work on an internal serial queue and complete synchronously before returning, so you can safely call `finish` immediately after the last `append` on the same thread.
- Values are delivered to subscribers on the **same** internal queue unless you add `receive(on:)`.

## Demo app

`OpusOGGContainer` (in this repo) records via VoiceAudioKit, encodes to `Documents/opus_demo.ogg`, and plays back by decoding with `OpusOGGDecoder` and `DefaultVoicePlayer`.

## Tests

The **OpusOGGTests** target lives next to the framework (`OpusOGGTests/`). Run it with the **OpusOGG** scheme on a **concrete** simulator (Apple’s test runner does not accept `generic/platform=iOS Simulator`):

```text
xcodebuild test -scheme OpusOGG \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:OpusOGGTests
```

Or pick a simulator UUID from `xcrun simctl list devices available`.

**Coverage (high level):** mono 440 Hz tone encode → decode, assert decoded sample count equals `frames × samplesPerFrame − 3840` preskip; invalid channel count throws; random bytes yield no decoded PCM without error.

## Distribution (xcframework)

Prebuilt **`Distribution/OpusOGG.xcframework`** is produced by the **OpusOGGXCFrameworkBuilder** aggregate target or:

```text
CONFIGURATION=Release SRCROOT=$PWD bash Scripts/package_opusogg_xcframework.sh
```

### Swift module interface (older Xcode)

The OpusOGG target uses **`BUILD_LIBRARY_FOR_DISTRIBUTION = YES`** and **`SWIFT_EMIT_MODULE_INTERFACE = YES`**, so each built `OpusOGG.framework` contains **`*.swiftinterface`** next to **`*.swiftmodule`**. The packaging script runs **`xcodebuild -create-xcframework` without `-allow-internal-distribution`**, which is appropriate when those interfaces are present.

If you **disable** `SWIFT_EMIT_MODULE_INTERFACE` again, packaging may require **`-allow-internal-distribution`**, and consumers are more likely to need the **exact same Swift toolchain** that built the binary.

**If a lower Xcode still fails to import the framework:** build the xcframework on the **oldest Xcode version you need to support** (CI job with that Xcode). That remains the most reliable fix for Swift version skew.

After a successful run you should see:

```text
Distribution/OpusOGG.xcframework/
  Info.plist
  ios-arm64/OpusOGG.framework/...
  ios-arm64_x86_64-simulator/OpusOGG.framework/...
```

Each `OpusOGG.framework` must contain the **`OpusOGG`** Mach-O binary and `Modules/`.
