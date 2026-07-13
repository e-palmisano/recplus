import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var session = RecordingSession()

    var body: some View {
        VStack(spacing: 20) {
            Text("AudioRecorder")
                .font(.title2)
                .bold()

            Picker("Microphone", selection: $session.selectedMicID) {
                ForEach(session.availableMics) { mic in
                    Text(mic.name).tag(Optional(mic.id))
                }
            }
            .disabled(session.isRecording)
            .frame(maxWidth: 320)

            Text(RecordingFormat.elapsedTimeString(session.elapsedSeconds))
                .font(.system(.largeTitle, design: .monospaced))
                .foregroundStyle(session.isRecording ? .red : .secondary)

            if session.isDownloadingModel {
                ProgressView(value: session.modelDownloadProgress) {
                    Text("Downloading transcription model…")
                        .font(.caption)
                }
                .frame(maxWidth: 280)
            }

            Button(session.isRecording ? "Stop Recording" : "Start Recording") {
                session.isRecording ? session.stop() : session.start()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if session.isRecording {
                TranscriptView(lines: session.transcriptLines, pendingText: session.pendingTranscriptText)
                    .frame(minHeight: 200, idealHeight: 280)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let url = session.lastRecordingURL, !session.isRecording {
                Button("Show Last Recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            }
        }
        .padding(32)
        .frame(minWidth: 380)
        .animation(.easeInOut(duration: 0.25), value: session.isRecording)
        .onAppear { session.refreshMics() }
    }
}

private struct TranscriptView: View {
    let lines: [TranscriptLine]
    let pendingText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text("[\(RecordingFormat.transcriptTimestamp(line.offset))] \(line.text)")
                            .font(.body)
                            .id(index)
                    }
                    if !pendingText.isEmpty {
                        Text(pendingText)
                            .font(.body.italic())
                            .foregroundStyle(.secondary)
                            .id("pending")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _, newCount in
                guard newCount > 0 else { return }
                if pendingText.isEmpty {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                } else {
                    proxy.scrollTo("pending", anchor: .bottom)
                }
            }
            .onChange(of: pendingText) { _, _ in
                proxy.scrollTo("pending", anchor: .bottom)
            }
        }
    }
}

#Preview {
    ContentView()
}
