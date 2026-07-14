import SwiftUI

struct ContentView: View {
    @ObservedObject var session: RecordingSession
    @State private var store = RecordingStore()
    @State private var selectionID: Recording.ID?

    private var selectedRecording: Recording? {
        selectionID.flatMap { id in store.recordings.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            List(store.recordings, selection: $selectionID) { recording in
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    HStack(spacing: 6) {
                        Text(RecordingFormat.elapsedTimeString(recording.duration))
                        if recording.transcriptURL != nil {
                            Image(systemName: "text.quote")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .disabled(session.isRecording)
            .overlay {
                if store.recordings.isEmpty {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform",
                        description: Text("Your finished recordings will appear here.")
                    )
                }
            }
        } detail: {
            if let recording = selectedRecording {
                PlaybackView(recording: recording, onDelete: delete)
            } else {
                RecorderView(session: session)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem {
                Picker("Microphone", selection: $session.selectedMicID) {
                    ForEach(session.availableMics) { mic in
                        Text(mic.name).tag(Optional(mic.id))
                    }
                }
                .disabled(session.isRecording)
                .help("Input microphone")
            }

            ToolbarSpacer()
        }
        .onChange(of: session.isRecording) { _, isRecording in
            if isRecording { selectionID = nil }
        }
        .onChange(of: session.lastRecordingURL) { _, _ in
            store.refresh()
        }
        .onAppear {
            store.refresh()
            session.refreshMics()
        }
    }

    private func delete(_ recording: Recording) {
        do {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            if let transcriptURL = recording.transcriptURL {
                try? FileManager.default.trashItem(at: transcriptURL, resultingItemURL: nil)
            }
        } catch {
            // Leave the row in place; the file is still there.
        }
        selectionID = nil
        store.refresh()
    }
}

#Preview {
    ContentView(session: RecordingSession())
}
