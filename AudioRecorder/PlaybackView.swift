import SwiftUI
import AppKit

/// Detail view for a past recording: inline player, transcript, file actions.
struct PlaybackView: View {
    let recording: Recording
    let onDelete: (Recording) -> Void

    @State private var controller = AudioPlayerController()
    @State private var transcript = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(recording.name)
                    .font(.title3)
                    .bold()
                Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)

                Slider(
                    value: Binding(
                        get: { controller.progress },
                        set: { controller.seek(to: $0) }
                    ),
                    in: 0...max(controller.duration, 0.01)
                )

                Text(RecordingFormat.elapsedTimeString(controller.progress))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(in: .capsule)
            .frame(maxWidth: 420)
            .disabled(controller.errorMessage != nil)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if !transcript.isEmpty {
                ScrollView {
                    Text(transcript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .glassEffect(in: .rect(cornerRadius: 16))
                .frame(minHeight: 160)
            }

            HStack(spacing: 16) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                }
                Button("Delete", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Move \"\(recording.name)\" to the Trash?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Move to Trash", role: .destructive) { onDelete(recording) }
        } message: {
            Text("The recording and its transcript will be moved to the Trash.")
        }
        .onAppear { load() }
        .onChange(of: recording) { _, _ in load() }
        .onDisappear { controller.stop() }
    }

    private func load() {
        controller.load(url: recording.url)
        transcript = recording.transcriptURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}
