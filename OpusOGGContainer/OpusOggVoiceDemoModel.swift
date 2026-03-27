//
//  OpusOggVoiceDemoModel.swift
//  OpusOGGContainer
//

import AVFoundation
import Combine
import Foundation
import OpusOGG
import VoiceAudioImplementation
import VoiceAudioProtocol

@MainActor
final class OpusOggVoiceDemoModel: ObservableObject {

    @Published private(set) var status: String = "Idle"
    @Published private(set) var lastFilePath: String = ""
    /// Bytes written to disk while recording (incremental Ogg pages).
    @Published private(set) var bytesWritten: Int64 = 0

    private let recorder: DefaultVoiceRecorder
    private let converter: PCMFormatConverterPlugin
    private let player: DefaultVoicePlayer

    /// Recorder → converter only; cleared on stop so mic stops but encoder sink stays until `finish`.
    private var inputCancellables = Set<AnyCancellable>()
    private var encoderOutputCancellable: AnyCancellable?
    private var encoder: OpusOGGEncoder?
    private var fileHandle: FileHandle?
    private var pcmTail = Data()

    private static let sampleRate: Double = 48_000
    private static let channels = 1
    private static let samplesPerFrame = 960
    private static var frameByteCount: Int { samplesPerFrame * MemoryLayout<Int16>.size * channels }

    init() {
        let cfg = VoiceRecorderConfiguration(
            sampleRate: 48_000,
            channelCount: Self.channels,
            enableVoiceProcessing: false
        )
        recorder = DefaultVoiceRecorder(configuration: cfg)
        converter = PCMFormatConverterPlugin(targetSampleRate: 16_000, targetChannelCount: Self.channels)
        player = DefaultVoicePlayer()
    }

    func startRecording() {
        Task {
            await startRecordingAsync()
        }
    }

    private func startRecordingAsync() async {
        guard encoder == nil else { return }
        inputCancellables.removeAll()
        encoderOutputCancellable?.cancel()
        encoderOutputCancellable = nil
        pcmTail.removeAll(keepingCapacity: true)
        bytesWritten = 0

        let url = Self.demoFileURL
        lastFilePath = url.path
        do {
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                status = "Could not create file"
                return
            }
            let enc = try OpusOGGEncoder(
                parameters: OpusOGGEncoderParameters(
                    sampleRate: Int32(16_000),
                    channels: Self.channels,
                    samplesPerFrame: Self.samplesPerFrame
                )
            )
            encoder = enc
            fileHandle = try FileHandle(forWritingTo: url)

            // 每产出一页 Ogg 即 append 到文件（边录边存）；最终落盘在 stop 时 synchronize。
            encoderOutputCancellable = enc.publisher.sink(
                receiveCompletion: { [weak self] completion in
                    Task { @MainActor in
                        if case .failure(let err) = completion {
                            self?.status = "Encode error: \(err)"
                        }
                    }
                },
                receiveValue: { [weak self] page in
                    guard let self else { return }
                    do {
                        try self.fileHandle?.write(contentsOf: page.data)
                        let n = Int64(page.data.count)
                        Task { @MainActor in
                            self.bytesWritten += n
                        }
                    } catch {
                        Task { @MainActor in
                            self.status = "Write failed: \(error.localizedDescription)"
                        }
                    }
                }
            )

            converter.convertedBufferPublisher
                .sink { [weak self] buffer in
                    self?.feedEncoder(withConverted: buffer)
                }
                .store(in: &inputCancellables)

            recorder.pcmBufferPublisher
                .sink { [weak self] buffer in
                    self?.converter.write(buffer)
                }
                .store(in: &inputCancellables)

            try await recorder.start()
            status = "Recording — streaming to \(url.lastPathComponent)"
        } catch {
            encoder = nil
            encoderOutputCancellable?.cancel()
            encoderOutputCancellable = nil
            try? fileHandle?.close()
            fileHandle = nil
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        inputCancellables.removeAll()
        recorder.stop()

        guard let enc = encoder else {
            status = "Idle"
            return
        }
        if !pcmTail.isEmpty {
            enc.appendPCM(pcmTail)
            pcmTail.removeAll(keepingCapacity: true)
        }
        enc.finish()

        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
        } catch {
            status = "Close file failed: \(error.localizedDescription)"
        }
        fileHandle = nil
        encoder = nil
        encoderOutputCancellable?.cancel()
        encoderOutputCancellable = nil

        let name = Self.demoFileURL.lastPathComponent
        status = "Stopped — saved \(bytesWritten) B to \(name)"
    }

    func playRecordedFile() {
        Task {
            await playRecordedFileAsync()
        }
    }

    private func playRecordedFileAsync() async {
        let url = Self.demoFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "No file yet — record first"
            return
        }
        status = "Decoding…"
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            status = "Read failed: \(error.localizedDescription)"
            return
        }

        let decoder = OpusOGGDecoder()
        var pcmChunks: [Data] = []
        var decodedChannels = 1
        var decodedRate = Int32(24_000)
        var decodeFailure: OpusOGGError?
        var subscription: AnyCancellable?
        subscription = decoder.publisher.sink(
            receiveCompletion: { completion in
                if case .failure(let err) = completion {
                    decodeFailure = err
                }
                subscription = nil
            },
            receiveValue: { pcm in
                if !pcm.data.isEmpty {
                    pcmChunks.append(pcm.data)
                    decodedChannels = pcm.channels
                    decodedRate = pcm.sampleRate
                }
            }
        )

        decoder.appendOggBytes(data)
        decoder.finish()

        if let decodeFailure {
            status = "Decode error: \(decodeFailure)"
            return
        }
        let mergedPCM = pcmChunks.reduce(into: Data()) { $0.append($1) }
        guard !mergedPCM.isEmpty,
              let playbackBuffer = Self.pcmBuffer(
                int16Data: mergedPCM,
                channels: decodedChannels,
                sampleRate: decodedRate
              )
        else {
            status = "No PCM decoded"
            return
        }

        player.stop()
        player.write(playbackBuffer)
        do {
            try await player.play()
            status = "Playing decoded audio"
        } catch {
            status = "Playback failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func feedEncoder(withConverted buffer: AVAudioPCMBuffer) {
        guard let enc = encoder else { return }
        guard let chunk = Self.int16PCMData(from: buffer) else { return }
        pcmTail.append(chunk)
        let frameBytes = Self.frameByteCount
        while pcmTail.count >= frameBytes {
            let frame = pcmTail.prefix(frameBytes)
            pcmTail.removeSubrange(0 ..< frameBytes)
            enc.appendPCM(Data(frame))
        }
    }

    private static var demoFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("opus_demo.ogg", isDirectory: false)
    }

    private static func int16PCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let ch = Int(buffer.format.channelCount)
        var data = Data(count: frames * ch * MemoryLayout<Int16>.size)
        if let floatChannelData = buffer.floatChannelData {
            data.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self).baseAddress!
                if ch == 1 {
                    let s0 = floatChannelData[0]
                    for i in 0 ..< frames {
                        let x = max(-1, min(1, Double(s0[i])))
                        dst[i] = Int16(x * Double(Int16.max))
                    }
                } else {
                    for i in 0 ..< frames {
                        var acc = 0.0
                        for c in 0 ..< ch {
                            acc += Double(floatChannelData[c][i])
                        }
                        let x = max(-1, min(1, acc / Double(ch)))
                        dst[i] = Int16(x * Double(Int16.max))
                    }
                }
            }
            return data
        }
        if let int16ChannelData = buffer.int16ChannelData {
            data.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self).baseAddress!
                if ch == 1 {
                    let s0 = int16ChannelData[0]
                    for i in 0 ..< frames {
                        dst[i] = s0[i]
                    }
                } else {
                    for i in 0 ..< frames {
                        var acc = 0
                        for c in 0 ..< ch {
                            acc += Int(int16ChannelData[c][i])
                        }
                        dst[i] = Int16(acc / ch)
                    }
                }
            }
            return data
        }
        return nil
    }

    private static func pcmBuffer(int16Data: Data, channels: Int, sampleRate: Int32) -> AVAudioPCMBuffer? {
        guard channels >= 1, int16Data.count % (MemoryLayout<Int16>.size * channels) == 0 else { return nil }
        let frames = int16Data.count / (MemoryLayout<Int16>.size * channels)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let floatData = buffer.floatChannelData else { return nil }
        // Symmetric scaling avoids slight asymmetry vs Int16.max (common for float playback).
        let scale = 1.0 / 32768.0
        int16Data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self).baseAddress!
            if channels == 1 {
                for i in 0 ..< frames {
                    floatData[0][i] = Float(Double(src[i]) * scale)
                }
            } else {
                for i in 0 ..< frames {
                    for c in 0 ..< channels {
                        floatData[c][i] = Float(Double(src[i * channels + c]) * scale)
                    }
                }
            }
        }
        return buffer
    }
}
