//
//  OpusOGGEncoder.swift
//  OpusOGG
//

import Combine
import Foundation

@_implementationOnly import opusogg

/// PCM (Int16) → Opus → Ogg pages. Output is a shared Combine publisher (`multicast` + `autoconnect`).
public final class OpusOGGEncoder: @unchecked Sendable {
    private struct PendingAudioPacket {
        let data: Data
        let granulePosition: ogg_int64_t
    }

    private let relay = PassthroughSubject<OpusOGGEncodedPage, OpusOGGError>()
    private lazy var multicastPublisher: AnyPublisher<OpusOGGEncodedPage, OpusOGGError> = {
        relay
            .multicast { PassthroughSubject<OpusOGGEncodedPage, OpusOGGError>() }
            .autoconnect()
            .eraseToAnyPublisher()
    }()

    /// Shared publisher for Ogg page output.
    public var publisher: AnyPublisher<OpusOGGEncodedPage, OpusOGGError> { multicastPublisher }

    private let queue = DispatchQueue(label: "com.isxq.OpusOGG.encoder")
    private var encoder: OpaquePointer?
    private var oggStream = ogg_stream_state()
    private var pcmBuffer = Data()
    private var granulePosition: ogg_int64_t = 0
    private var nextPacketNumber: ogg_int64_t = 0
    private var finished = false
    private var pendingAudioPacket: PendingAudioPacket?

    private let parameters: OpusOGGEncoderParameters
    private let bytesPerFrame: Int

    /// Identification Ogg pages are produced in `init` before any subscriber exists; `PassthroughSubject` drops values with no subscribers.
    /// Buffer until the first encode/finish path emits pages so headers always precede audio in the file.
    private var identificationPagesBuffered: [Data] = []

    public init(parameters: OpusOGGEncoderParameters) throws {
        self.parameters = parameters
        guard parameters.channels == 1 || parameters.channels == 2 else {
            throw OpusOGGError.invalidConfiguration("channels must be 1 or 2")
        }
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(parameters.sampleRate) else {
            throw OpusOGGError.invalidConfiguration("unsupported sample rate")
        }
        bytesPerFrame = parameters.samplesPerFrame * parameters.channels * MemoryLayout<Int16>.size

        var err: Int32 = 0
        let enc = opus_encoder_create(parameters.sampleRate, Int32(parameters.channels), parameters.application, &err)
        guard err == OPUS_OK, let enc else {
            throw OpusOGGError.opusFailed(err)
        }
        encoder = enc

        let brErr = opusogg_encoder_set_bitrate(enc, parameters.bitrate)
        if brErr != OPUS_OK {
            opus_encoder_destroy(enc)
            encoder = nil
            throw OpusOGGError.opusFailed(brErr)
        }

        let serial = Int32.random(in: 1 ... Int32.max)
        if ogg_stream_init(&oggStream, serial) != 0 {
            opus_encoder_destroy(enc)
            encoder = nil
            throw OpusOGGError.oggFailed
        }

        try queue.sync {
            try writeIdentificationHeaders()
        }
    }

    private func flushIdentificationPagesToRelayIfNeeded() {
        guard !identificationPagesBuffered.isEmpty else { return }
        for page in identificationPagesBuffered {
            relay.send(.init(data: page))
        }
        identificationPagesBuffered.removeAll(keepingCapacity: false)
    }

    deinit {
        if let encoder {
            opus_encoder_destroy(encoder)
        }
        ogg_stream_clear(&oggStream)
    }

    /// Append interleaved Int16 PCM; emits zero or more `OpusOGGEncodedPage` values on `publisher`.
    /// Runs synchronously on an internal queue so the last ``appendPCM(_:)`` completes before ``finish()``.
    public func appendPCM(_ pcm: Data) {
        queue.sync { [weak self] in
            guard let self, !self.finished else { return }
            self.pcmBuffer.append(pcm)
            self.encodeAvailableFrames()
        }
    }

    /// Pad the last frame with silence, mark EOS, and flush Ogg state. After this, `appendPCM` is ignored.
    public func finish() {
        queue.sync { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            do {
                try self.padAndEncodeTail()
                try self.flushRemainingPages(endOfStream: true)
                self.relay.send(completion: .finished)
            } catch let error as OpusOGGError {
                self.relay.send(completion: .failure(error))
            } catch {
                self.relay.send(completion: .failure(.invalidConfiguration(String(describing: error))))
            }
        }
    }

    // MARK: - Private

    private func writeIdentificationHeaders() throws {
        let head = makeOpusHeadPacket(
            channels: UInt8(parameters.channels),
            preskip: 3840,
            inputSampleRate: UInt32(parameters.sampleRate)
        )
        try submitPacket(Data(head), packetNumber: nextPacketNumber, granulepos: 0, beginOfStream: true, endOfStream: false)
        nextPacketNumber += 1

        let tags = makeOpusTagsPacket(vendor: "OpusOGG")
        try submitPacket(Data(tags), packetNumber: nextPacketNumber, granulepos: 0, beginOfStream: false, endOfStream: false)
        nextPacketNumber += 1

        drainPages(flush: true, bufferOnly: true)
    }

    private func encodeAvailableFrames() {
        while pcmBuffer.count >= bytesPerFrame {
            let frame = pcmBuffer.prefix(bytesPerFrame)
            pcmBuffer.removeSubrange(0 ..< bytesPerFrame)
            do {
                try encodeOneFrame(Data(frame))
            } catch let error as OpusOGGError {
                relay.send(completion: .failure(error))
                return
            } catch {
                relay.send(completion: .failure(.invalidConfiguration(String(describing: error))))
                return
            }
        }
    }

    private func padAndEncodeTail() throws {
        guard !pcmBuffer.isEmpty else {
            return
        }
        pcmBuffer.append(Data(count: bytesPerFrame - pcmBuffer.count))
        defer { pcmBuffer.removeAll(keepingCapacity: true) }
        try encodeOneFrame(pcmBuffer)
    }

    private func encodeOneFrame(_ frame: Data) throws {
        guard let encoder else { throw OpusOGGError.invalidConfiguration("encoder released") }
        var out = [UInt8](repeating: 0, count: 4000)
        let encoded: Int32 = frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return Int32(0) }
            return opus_encode(encoder, base, Int32(parameters.samplesPerFrame), &out, 4000)
        }
        guard encoded >= 0 else {
            throw OpusOGGError.opusFailed(encoded)
        }
        guard encoded > 0 else {
            throw OpusOGGError.invalidPacket
        }
        let packetData = Data(out.prefix(Int(encoded)))
        let nb = packetData.withUnsafeBytes { raw in
            opus_packet_get_nb_samples(
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                encoded,
                parameters.sampleRate
            )
        }
        guard nb > 0 else {
            throw OpusOGGError.invalidPacket
        }
        granulePosition += granulePositionDelta(decodedSamples: nb)
        try queueAudioPacket(packetData, granulepos: granulePosition)
    }

    private func granulePositionDelta(decodedSamples: Int32) -> ogg_int64_t {
        ogg_int64_t(decodedSamples) * 48_000 / ogg_int64_t(parameters.sampleRate)
    }

    private func queueAudioPacket(_ data: Data, granulepos: ogg_int64_t) throws {
        if let pendingAudioPacket {
            try submitPacket(
                pendingAudioPacket.data,
                packetNumber: nextPacketNumber,
                granulepos: pendingAudioPacket.granulePosition,
                beginOfStream: false,
                endOfStream: false
            )
            nextPacketNumber += 1
            drainPages(flush: false, bufferOnly: false)
        }
        pendingAudioPacket = PendingAudioPacket(data: data, granulePosition: granulepos)
    }

    private func flushRemainingPages(endOfStream: Bool) throws {
        if endOfStream, let pendingAudioPacket {
            try submitPacket(
                pendingAudioPacket.data,
                packetNumber: nextPacketNumber,
                granulepos: pendingAudioPacket.granulePosition,
                beginOfStream: false,
                endOfStream: true
            )
            nextPacketNumber += 1
            self.pendingAudioPacket = nil
        }
        drainPages(flush: true, bufferOnly: false)
    }

    private func submitPacket(
        _ data: Data,
        packetNumber: ogg_int64_t,
        granulepos: ogg_int64_t,
        beginOfStream: Bool,
        endOfStream: Bool
    ) throws {
        var op = ogg_packet()
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw OpusOGGError.invalidConfiguration("pcm buffer")
            }
            op.packet = UnsafeMutablePointer(mutating: base)
            op.bytes = data.count
            op.b_o_s = beginOfStream ? 1 : 0
            op.e_o_s = endOfStream ? 1 : 0
            op.granulepos = granulepos
            op.packetno = packetNumber
            if ogg_stream_packetin(&oggStream, &op) != 0 {
                throw OpusOGGError.oggFailed
            }
        }
    }

    private func drainPages(flush: Bool, bufferOnly: Bool) {
        var page = ogg_page()
        while true {
            let got: Int32
            if flush {
                got = ogg_stream_flush(&oggStream, &page)
            } else {
                got = ogg_stream_pageout(&oggStream, &page)
            }
            guard got != 0 else { break }
            let combined = oggPageData(page)
            if bufferOnly {
                identificationPagesBuffered.append(combined)
            } else {
                flushIdentificationPagesToRelayIfNeeded()
                relay.send(.init(data: combined))
            }
        }
    }
}

// MARK: - Ogg helpers

private func oggPageData(_ page: ogg_page) -> Data {
    let hLen = Int(page.header_len)
    let bLen = Int(page.body_len)
    guard let headerPtr = page.header, hLen >= 0 else { return Data() }
    let header = Data(bytes: headerPtr, count: hLen)
    guard let bodyPtr = page.body, bLen >= 0 else { return header }
    return header + Data(bytes: bodyPtr, count: bLen)
}

private func makeOpusHeadPacket(channels: UInt8, preskip: UInt16, inputSampleRate: UInt32) -> [UInt8] {
    var bytes: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]
    bytes.append(1)
    bytes.append(channels)
    bytes.append(UInt8(truncatingIfNeeded: preskip))
    bytes.append(UInt8(truncatingIfNeeded: preskip >> 8))
    var rate = inputSampleRate
    for _ in 0 ..< 4 {
        bytes.append(UInt8(truncatingIfNeeded: rate))
        rate >>= 8
    }
    bytes.append(0)
    bytes.append(0)
    bytes.append(0)
    return bytes
}

private func makeOpusTagsPacket(vendor: String) -> [UInt8] {
    var b = [UInt8]("OpusTags".utf8)
    let vc = UInt32(vendor.utf8.count)
    b.append(UInt8(truncatingIfNeeded: vc))
    b.append(UInt8(truncatingIfNeeded: vc >> 8))
    b.append(UInt8(truncatingIfNeeded: vc >> 16))
    b.append(UInt8(truncatingIfNeeded: vc >> 24))
    b.append(contentsOf: vendor.utf8)
    let userCount = UInt32(0)
    b.append(UInt8(truncatingIfNeeded: userCount))
    b.append(UInt8(truncatingIfNeeded: userCount >> 8))
    b.append(UInt8(truncatingIfNeeded: userCount >> 16))
    b.append(UInt8(truncatingIfNeeded: userCount >> 24))
    return b
}
