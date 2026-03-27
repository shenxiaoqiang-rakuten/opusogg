//
//  OpusOGGTypes.swift
//  OpusOGG
//

import Foundation

// MARK: - Errors

public enum OpusOGGError: Error, Equatable, Sendable {
    /// Wrapped `OPUS_*` error code from libopus.
    case opusFailed(Int32)
    /// Non-zero return from libogg (`ogg_stream_*`, `ogg_sync_*`, etc.).
    case oggFailed
    case invalidConfiguration(String)
    case invalidPacket
    /// Legacy; prefer ``missingIdentificationHeaders``.
    case streamNotReady
    /// Decoded an audio packet before OpusHead/OpusTags were parsed (container out of order or corrupt).
    case missingIdentificationHeaders
}

// MARK: - Encoder

/// Configuration for ``OpusOGGEncoder``. Sample rate must be one of 8 / 12 / 16 / 24 / 48 kHz; `channels` is 1 or 2.
public struct OpusOGGEncoderParameters: Sendable {
    public var sampleRate: Int32
    public var channels: Int
    /// Samples per channel per encoded frame (e.g. 960 for 20 ms @ 48 kHz).
    public var samplesPerFrame: Int
    /// Target bitrate in bits per second (passed to the encoder).
    public var bitrate: Int32
    /// Opus application mode (e.g. `OPUS_APPLICATION_AUDIO` = 2049).
    public var application: Int32

    public init(
        sampleRate: Int32 = 48_000,
        channels: Int = 1,
        samplesPerFrame: Int = 960,
        bitrate: Int32 = 64_000,
        application: Int32 = 2049 /* OPUS_APPLICATION_AUDIO */
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samplesPerFrame = samplesPerFrame
        self.bitrate = bitrate
        self.application = application
    }
}

/// One complete Ogg page (header + body).
public struct OpusOGGEncodedPage: Equatable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

// MARK: - Decoder

public struct OpusOGGDecodedPCM: Equatable, Sendable {
    /// Interleaved little-endian `Int16` PCM at the decoder sample rate (typically 48 kHz).
    public let data: Data
    public let channels: Int
    public let sampleRate: Int32

    public init(data: Data, channels: Int, sampleRate: Int32) {
        self.data = data
        self.channels = channels
        self.sampleRate = sampleRate
    }
}
