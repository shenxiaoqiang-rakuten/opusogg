//
//  OpusOGGRoundTripTests.swift
//  OpusOGGTests
//

import Combine
import XCTest
import OpusOGG

final class OpusOGGRoundTripTests: XCTestCase {

    /// Uses a non-trivial tone so Opus emits a packet every frame (DTX/silence can omit packets and would skew sample counts).
    func testToneRoundTripSampleCountMatchesInputMinusPreskip() throws {
        let sampleRate: Int32 = 48_000
        let samplesPerFrame = 960
        let frameCount = 10
        let preskip = 3840

        let encoder = try OpusOGGEncoder(
            parameters: OpusOGGEncoderParameters(
                sampleRate: sampleRate,
                channels: 1,
                samplesPerFrame: samplesPerFrame
            )
        )

        var ogg = Data()
        let encodeDone = expectation(description: "encode complete")
        var encodeSub: AnyCancellable?
        encodeSub = encoder.publisher.sink(
            receiveCompletion: { _ in encodeDone.fulfill() },
            receiveValue: { ogg.append($0.data) }
        )

        var pcmIn = Data()
        for f in 0 ..< frameCount {
            pcmIn.append(makeToneFrame(samplesPerFrame: samplesPerFrame, sampleRate: Int(sampleRate), frameIndex: f))
        }
        encoder.appendPCM(pcmIn)
        encoder.finish()

        wait(for: [encodeDone], timeout: 10)
        encodeSub?.cancel()

        XCTAssertFalse(ogg.isEmpty)
        XCTAssertEqual(ogg.prefix(4), Data([0x4F, 0x67, 0x67, 0x53]), "Ogg capture should start with OggS magic")

        let decoder = OpusOGGDecoder()
        var pcmOut = Data()
        let decodeDone = expectation(description: "decode complete")
        var decodeSub: AnyCancellable?
        decodeSub = decoder.publisher.sink(
            receiveCompletion: { _ in decodeDone.fulfill() },
            receiveValue: { pcmOut.append($0.data) }
        )
        decoder.appendOggBytes(ogg)
        decoder.finish()
        wait(for: [decodeDone], timeout: 10)
        decodeSub?.cancel()

        let decodedSamples = pcmOut.count / MemoryLayout<Int16>.size
        let expectedSamples = frameCount * samplesPerFrame - preskip
        XCTAssertEqual(decodedSamples, expectedSamples)
    }

    func testInvalidChannelCountThrows() {
        XCTAssertThrowsError(
            try OpusOGGEncoder(
                parameters: OpusOGGEncoderParameters(
                    sampleRate: 48_000,
                    channels: 3,
                    samplesPerFrame: 960
                )
            )
        ) { error in
            guard case OpusOGGError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration, got \(error)")
                return
            }
        }
    }

    func testDecodeWithoutOpusIdentificationCompletesWithoutPCM() {
        let decoder = OpusOGGDecoder()
        var values = 0
        let done = expectation(description: "decode finished")
        let sub = decoder.publisher.sink(
            receiveCompletion: { _ in done.fulfill() },
            receiveValue: { _ in values += 1 }
        )
        decoder.appendOggBytes(Data(repeating: 0xAB, count: 32))
        decoder.finish()
        wait(for: [done], timeout: 2)
        sub.cancel()
        XCTAssertEqual(values, 0, "Random bytes should not yield a valid Opus audio packet")
    }
}

private func makeToneFrame(samplesPerFrame: Int, sampleRate: Int, frameIndex: Int) -> Data {
    let frequency = 440.0
    let twoPi = 2.0 * Double.pi
    var data = Data(count: samplesPerFrame * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: Int16.self).baseAddress!
        for i in 0 ..< samplesPerFrame {
            let t = Double(i + frameIndex * samplesPerFrame) / Double(sampleRate)
            let s = Int32(sin(twoPi * frequency * t) * 10_000.0)
            dst[i] = Int16(clamping: s)
        }
    }
    return data
}
