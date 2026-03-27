//
//  OpusOGGDecoder.swift
//  OpusOGG
//

import Combine
import Darwin
import Foundation

@_implementationOnly import opusogg

/// Ogg bytes → Opus packets → PCM (`Int16` interleaved). Output is a shared Combine publisher (`multicast` + `autoconnect`).
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
    private var oggStream = ogg_stream_state()
    private var streamInitialized = false
    private var decoder: OpaquePointer?
    private var channels = 1
    private var decoderSampleRate: Int32 = 48_000
    private var preskipSamplesRemaining = 0

    private enum IdentificationPhase: Int {
        case needOpusHead
        case needOpusTags
        case ready
    }

    private var identificationPhase = IdentificationPhase.needOpusHead

    public init() {
        ogg_sync_init(&oggSync)
    }

    deinit {
        if let decoder {
            opus_decoder_destroy(decoder)
        }
        if streamInitialized {
            ogg_stream_clear(&oggStream)
        }
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

    private func pumpPages() {
        var page = ogg_page()
        while ogg_sync_pageout(&oggSync, &page) == 1 {
            if !streamInitialized {
                let serial = ogg_page_serialno(&page)
                if ogg_stream_init(&oggStream, serial) != 0 {
                    relay.send(completion: .failure(.oggFailed))
                    return
                }
                streamInitialized = true
            }
            if ogg_stream_pagein(&oggStream, &page) != 0 {
                relay.send(completion: .failure(.oggFailed))
                return
            }
            var packet = ogg_packet()
            while ogg_stream_packetout(&oggStream, &packet) == 1 {
                if packet.bytes <= 0 || packet.packet == nil {
                    continue
                }
                let payload = Data(bytes: packet.packet!, count: Int(packet.bytes))
                if let err = handlePacket(payload) {
                    relay.send(completion: .failure(err))
                    return
                }
            }
        }
    }

    private func handlePacket(_ payload: Data) -> OpusOGGError? {
        if payload.count >= 8 {
            let prefix = payload.prefix(8)
            if prefix == Self.opusHeadMagic {
                guard identificationPhase == .needOpusHead else {
                    return .invalidPacket
                }
                let err = configureFromHead(payload)
                if err == nil {
                    identificationPhase = .needOpusTags
                }
                return err
            }
            if prefix == Self.opusTagsMagic {
                guard identificationPhase == .needOpusTags else {
                    return .invalidPacket
                }
                identificationPhase = .ready
                return nil
            }
        }

        switch identificationPhase {
        case .needOpusHead, .needOpusTags:
            return .missingIdentificationHeaders
        case .ready:
            return decodeAudioPacket(payload)
        }
    }

    private func configureFromHead(_ data: Data) -> OpusOGGError? {
        guard data.count >= 19, data[8] == 1 else {
            return .invalidPacket
        }
        let ch = Int(data[9])
        guard ch == 1 || ch == 2 else {
            return .invalidConfiguration("unsupported channel count")
        }
        channels = ch
        let preskip = UInt16(data[10]) | (UInt16(data[11]) << 8)
        preskipSamplesRemaining = Int(preskip) * channels

        if let existing = decoder {
            opus_decoder_destroy(existing)
            decoder = nil
        }
        decoderSampleRate = 48_000
        var err: Int32 = 0
        let dec = opus_decoder_create(decoderSampleRate, Int32(channels), &err)
        guard err == OPUS_OK, let dec else {
            return .opusFailed(err)
        }
        decoder = dec
        return nil
    }

    private func decodeAudioPacket(_ packet: Data) -> OpusOGGError? {
        guard let decoder else {
            return .missingIdentificationHeaders
        }
        let maxFrame = 5760
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

        if preskipSamplesRemaining > 0 {
            let skip = min(preskipSamplesRemaining, slice.count)
            slice = slice.dropFirst(skip)
            preskipSamplesRemaining -= skip
        }

        guard !slice.isEmpty else {
            return nil
        }
        let out = slice.withUnsafeBufferPointer { Data(buffer: $0) }
        relay.send(OpusOGGDecodedPCM(data: out, channels: channels, sampleRate: decoderSampleRate))
        return nil
    }
}
