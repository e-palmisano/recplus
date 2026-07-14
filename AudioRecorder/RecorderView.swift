import SwiftUI
import AppKit

/// Live recording detail: hero timer, level meters, live transcript.
/// The transcript persists after stop (cleared on the next start).
struct RecorderView: View {
    @ObservedObject var session: RecordingSession

    private var timerColor: Color {
        guard session.isRecording else { return .secondary }
        return session.isPaused ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(RecordingFormat.elapsedTimeString(session.elapsedSeconds))
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .foregroundStyle(timerColor)
                .contentTransition(.numericText())

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    if session.isRecording {
                        VStack(spacing: 8) {
                            LevelMeterView(symbolName: "mic.fill", level: session.micLevel)
                            LevelMeterView(symbolName: "speaker.wave.2.fill", level: session.systemLevel)
                        }
                        .padding(14)
                        .frame(maxWidth: 340)
                        .glassEffect(in: .rect(cornerRadius: 12))
                    }

                    if !session.transcriptLines.isEmpty || !session.pendingTranscriptText.isEmpty {
                        TranscriptPanel(
                            lines: session.transcriptLines,
                            pendingText: session.pendingTranscriptText
                        )
                        .frame(minHeight: 200, idealHeight: 280)
                    }
                }
            }

            if session.isDownloadingModel {
                ProgressView(value: session.modelDownloadProgress) {
                    Text("Downloading transcription model…")
                        .font(.caption)
                }
                .frame(maxWidth: 280)
            }

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if let url = session.lastRecordingURL, !session.isRecording {
                Button("Show Last Recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: session.isRecording)
        .animation(.easeInOut(duration: 0.25), value: session.transcriptLines.isEmpty)
    }
}
