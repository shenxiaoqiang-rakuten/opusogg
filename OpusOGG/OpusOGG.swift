//
//  OpusOGG.swift
//  OpusOGG
//

import Foundation

/// Opus-in-Ogg (RFC 7845) for iOS: **encode** interleaved Int16 PCM to Ogg pages and **decode** back to PCM.
///
/// ### Public API surface
/// - All streaming I/O is exposed only through **Combine** publishers on ``OpusOGGEncoder`` and ``OpusOGGDecoder``
///   (`multicast` + `autoconnect`). There is no `AsyncStream`.
///
/// ### Typical encode flow
/// 1. Create ``OpusOGGEncoder`` with ``OpusOGGEncoderParameters`` (sample rate, channels 1–2, samples per frame).
/// 2. Subscribe to ``OpusOGGEncoder/publisher`` before or while feeding PCM (identification pages are buffered until the first encode so they are not dropped).
/// 3. Push PCM with ``OpusOGGEncoder/appendPCM(_:)``; call ``OpusOGGEncoder/finish()`` to flush EOS and complete the publisher.
///
/// ### Typical decode flow
/// 1. Create ``OpusOGGDecoder`` and subscribe to ``OpusOGGDecoder/publisher``.
/// 2. Feed file or network bytes with ``OpusOGGDecoder/appendOggBytes(_:)``; call ``OpusOGGDecoder/finish()`` when done.
///
/// ### Documentation
/// See `Documentation/OpusOGG.md` in the repository for threading, preskip, and xcframework notes.
