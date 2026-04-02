//
//  OpusOGGDecoder.swift
//  OpusOGG
//

import Combine
import Darwin
import Foundation

@_implementationOnly import opusogg

/// Ogg bytes → Opus packets → PCM (`Int16` interleaved). Output is a shared Combine publisher (`multicast` + `autoconnect`).
///
/// Supports **multiple logical Opus streams** in one physical Ogg (each stream has its own serial); pages are demuxed by serial per libogg rules.
public final class OpusOGGDecoder: @unchecked Sendable {

    private let relay = PassthroughSubject<OpusOGGDecodedPCM, OpusOGGError>()
    private lazy var multicastPublisher: AnyPublisher<OpusOGGDecodedPCM, OpusOGGError> = {
        relay
            .multicast { PassthroughSubject<OpusOGGDecodedPCM, OpusOGGError>() }
            .autoconnect()
            .eraseToAnyPublisher()
    }()

    public var publisher: AnyPublisher<OpusOGGDecodedPCM, OpusOGGError> { multicastPublisher }

    private let queue = DispatchQueue(label: "com.isxq.OpusOGG.decoder")
    private var oggSync = ogg_sync_state()
    /// One demuxer + decoder state per logical stream serial (RFC 7845 / chained Ogg).
    private var logicalStreams: [Int32: LogicalStreamContext] = [:]

    public init() {
        ogg_sync_init(&oggSync)
    }

    deinit {
        logicalStreams.removeAll()
        ogg_sync_clear(&oggSync)
    }

    /// Append raw Ogg container bytes (e.g. from a file or network). Decoded PCM is emitted on `publisher`.
    /// Runs synchronously on an internal queue so callers can feed data and then call ``finish()`` without races.
    public func appendOggBytes(_ data: Data) {
        queue.sync { [weak self] in
            guard let self else { return }
            guard !data.isEmpty else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let buffer = ogg_sync_buffer(&self.oggSync, data.count)
                if let buffer {
                    memcpy(buffer, base, data.count)
                    _ = ogg_sync_wrote(&self.oggSync, data.count)
                }
            }
            self.pumpPages()
        }
    }

    /// Signals that no more input will arrive. Completes the publisher.
    public func finish() {
        queue.sync { [weak self] in
            self?.relay.send(completion: .finished)
        }
    }

    // MARK: - Private

    private static let opusHeadMagic = Data([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]) // "OpusHead"
    private static let opusTagsMagic = Data([0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]) // "OpusTags"

    private enum IdentificationPhase: Int {
        case needOpusHead
        case needOpusTags
        case ready
    }

    private final class LogicalStreamContext {
        var oggStream = ogg_stream_state()
        var decoder: OpaquePointer?
        var channels = 1
        var decoderSampleRate: Int32 = 48_000
        var preskipSamplesRemaining = 0
        var identificationPhase = IdentificationPhase.needOpusHead

        deinit {
            if let decoder {
                opus_decoder_destroy(decoder)
            }
            ogg_stream_clear(&oggStream)
        }
    }

    private func pumpPages() {
        var page = ogg_page()
        while ogg_sync_pageout(&oggSync, &page) == 1 {
            let serial = Int32(ogg_page_serialno(&page))
            if logicalStreams[serial] == nil {
                let ctx = LogicalStreamContext()
                if ogg_stream_init(&ctx.oggStream, serial) != 0 {
                    relay.send(completion: .failure(.oggFailed))
                    return
                }
                logicalStreams[serial] = ctx
            }
            guard let ctx = logicalStreams[serial] else {
                continue
            }
            if ogg_stream_pagein(&ctx.oggStream, &page) != 0 {
                relay.send(completion: .failure(.oggFailed))
                return
            }
            var packet = ogg_packet()
            while ogg_stream_packetout(&ctx.oggStream, &packet) == 1 {
                if packet.bytes <= 0 || packet.packet == nil {
                    continue
                }
                let payload = Data(bytes: packet.packet!, count: Int(packet.bytes))
                if let err = handlePacket(payload, context: ctx) {
                    relay.send(completion: .failure(err))
                    return
                }
            }
        }
    }

    private func handlePacket(_ payload: Data, context: LogicalStreamContext) -> OpusOGGError? {
        if payload.count >= 8 {
            let prefix = payload.prefix(8)
            if prefix == Self.opusHeadMagic {
                guard context.identificationPhase == .needOpusHead else {
                    return .invalidPacket
                }
                let err = configureFromHead(payload, context: context)
                if err == nil {
                    context.identificationPhase = .needOpusTags
                }
                return err
            }
            if prefix == Self.opusTagsMagic {
                guard context.identificationPhase == .needOpusTags else {
                    return .invalidPacket
                }
                context.identificationPhase = .ready
                return nil
            }
        }

        switch context.identificationPhase {
        case .needOpusHead, .needOpusTags:
            return .missingIdentificationHeaders
        case .ready:
            return decodeAudioPacket(payload, context: context)
        }
    }

    private func configureFromHead(_ data: Data, context: LogicalStreamContext) -> OpusOGGError? {
        guard data.count >= 19, data[8] == 1 else {
            return .invalidPacket
        }
        let ch = Int(data[9])
        guard ch == 1 || ch == 2 else {
            return .invalidConfiguration("unsupported channel count")
        }
        context.channels = ch
        let preskip = UInt16(data[10]) | (UInt16(data[11]) << 8)
        context.preskipSamplesRemaining = Int(preskip) * ch

        if let existing = context.decoder {
            opus_decoder_destroy(existing)
            context.decoder = nil
        }
        context.decoderSampleRate = 48_000
        var err: Int32 = 0
        let dec = opus_decoder_create(context.decoderSampleRate, Int32(ch), &err)
        guard err == OPUS_OK, let dec else {
            return .opusFailed(err)
        }
        context.decoder = dec
        return nil
    }

    private func decodeAudioPacket(_ packet: Data, context: LogicalStreamContext) -> OpusOGGError? {
        guard let decoder = context.decoder else {
            return .missingIdentificationHeaders
        }
        let maxFrame = 5760
        let channels = context.channels
        var pcm = [Int16](repeating: 0, count: maxFrame * channels)
        let decoded: Int32 = packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return Int32(OPUS_BAD_ARG) }
            return opus_decode(decoder, base, Int32(packet.count), &pcm, Int32(maxFrame), 0)
        }
        guard decoded > 0 else {
            return .opusFailed(decoded)
        }
        let totalSamples = Int(decoded) * channels
        var slice = pcm.prefix(totalSamples)

        if context.preskipSamplesRemaining > 0 {
            let skip = min(context.preskipSamplesRemaining, slice.count)
            slice = slice.dropFirst(skip)
            context.preskipSamplesRemaining -= skip
        }

        guard !slice.isEmpty else {
            return nil
        }
        let out = slice.withUnsafeBufferPointer { Data(buffer: $0) }
        relay.send(OpusOGGDecodedPCM(data: out, channels: channels, sampleRate: context.decoderSampleRate))
        return nil
    }
}
