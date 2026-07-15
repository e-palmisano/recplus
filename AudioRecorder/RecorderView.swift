import SwiftUI
import AppKit

/// Live recording detail: hero timer, level meters, an always-visible
/// transcript panel (with state-aware placeholder), and a floating
/// glass control cluster. The transcript persists after stop and is
/// cleared on the next start.
struct RecorderView: View {
    let session: RecordingSession
    @State private var isShowingNamePrompt = false
    @State private var nameInput = ""

    private var timerColor: Color {
        guard session.isRecording else { return .secondary }
        return session.isPaused ? .orange : .red
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 20) {
                Text(RecordingFormat.elapsedTimeString(session.elapsedSeconds))
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .foregroundStyle(timerColor)
                    .contentTransition(.numericText())

                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 16) {
                        if session.isRecording {
                            LevelMetersView(levels: session.levels)
                                .padding(14)
                                .frame(maxWidth: 340)
                                .glassEffect(in: .rect(cornerRadius: 12))
                        }

                        TranscriptPanel(
                            lines: session.transcriptLines,
                            pendingText: session.pendingTranscriptText,
                            placeholder: AnyView(transcriptPlaceholder)
                        )
                        .frame(minHeight: 200, idealHeight: 280)
                    }
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
            .padding(.bottom, 72)   // clear the floating cluster
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: session.isRecording)
            .animation(.easeInOut(duration: 0.25), value: session.transcriptLines.isEmpty)

            RecordControlCluster(session: session)
                .padding(.bottom, 18)
        }
        .onChange(of: session.isRecording) { _, isRecording in
            if isRecording {
                nameInput = ""
                isShowingNamePrompt = true
            }
        }
        .alert("Name This Recording", isPresented: $isShowingNamePrompt) {
            TextField("Recording name (optional)", text: $nameInput)
            Button("Save") { session.desiredRecordingName = nameInput }
            Button("Skip", role: .cancel) { }
        } message: {
            Text("Leave blank to use the default timestamp name.")
        }
    }

    /// State-aware placeholder shown inside the always-visible transcript panel.
    @ViewBuilder private var transcriptPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: session.isRecording ? "waveform" : "record.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            if session.isRecording && session.isDownloadingModel {
                Text("Downloading transcription model…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if session.isRecording {
                Text("Listening…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Press the red button to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Live transcription will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
