import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var session = RecordingSession()

    var body: some View {
        VStack(spacing: 20) {
            Text("Rec+")
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

            if let url = session.lastRecordingURL, !session.isRecording {
                Button("Show Last Recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            }
        }
        .padding(32)
        .frame(width: 380, height: 320)
        .onAppear { session.refreshMics() }
    }
}

#Preview {
    ContentView()
}
