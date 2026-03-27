//
//  ContentView.swift
//  OpusOGGContainer
//
//  Created by Shen, Xiaoqiang | CNTD on 2026/3/24.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model = OpusOggVoiceDemoModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Opus + Ogg + VoiceAudioKit")
                .font(.headline)
            Text(model.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(model.lastFilePath)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.tertiary)
            Text("Written: \(model.bytesWritten) bytes")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Record") {
                    model.startRecording()
                }
                .buttonStyle(.borderedProminent)

                Button("Stop") {
                    model.stopRecording()
                }
                .buttonStyle(.bordered)

                Button("Play file") {
                    model.playRecordedFile()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

#Preview {
    ContentView()
}
