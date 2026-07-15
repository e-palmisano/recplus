import SwiftUI

struct ContentView: View {
    @Bindable var session: RecordingSession
    @State private var store = RecordingStore()
    @State private var selectionID: Recording.ID?
    @State private var recordingBeingRenamed: Recording?
    @State private var renameText: String = ""
    @State private var recordingPendingDelete: Recording?

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
                .contextMenu {
                    Button("Rename…") {
                        renameText = recording.name
                        recordingBeingRenamed = recording
                    }
                    Button("Delete", role: .destructive) {
                        recordingPendingDelete = recording
                    }
                }
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
            if selectedRecording != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        selectionID = nil
                    } label: {
                        Label("Back to Recorder", systemImage: "chevron.left")
                    }
                    .help("Back to Recorder")
                }
            }

            ToolbarItem {
                Picker("Microphone", selection: $session.selectedMicID) {
                    ForEach(session.availableMics) { mic in
                        Text(mic.name).tag(Optional(mic.id))
                    }
                }
                .disabled(session.isRecording)
                .help("Input microphone")
            }

            ToolbarItem {
                Picker("Language", selection: $session.selectedTranscriptionLocaleID) {
                    ForEach(session.availableTranscriptionLocales, id: \.identifier) { locale in
                        Text(RecordingSession.localeDisplayName(locale)).tag(locale.identifier)
                    }
                }
                .disabled(session.isRecording || session.availableTranscriptionLocales.isEmpty)
                .help("Transcription language")
            }

            ToolbarItem {
                Button {
                    session.downloadModel(
                        for: Locale(identifier: session.selectedTranscriptionLocaleID)
                    )
                } label: {
                    Label("Download Selected Model", systemImage: "arrow.down.circle")
                }
                .disabled(
                    session.isRecording
                        || session.isDownloadingModel
                        || session.availableTranscriptionLocales.isEmpty
                )
                .help("Download the selected transcription model")
            }

            ToolbarSpacer()
        }
        .alert(
            "Download Transcription Model",
            isPresented: Binding(
                get: { session.modelDownloadPromptLocale != nil },
                set: { if !$0 { session.modelDownloadPromptLocale = nil } }
            ),
            presenting: session.modelDownloadPromptLocale
        ) { locale in
            Button("Download") { session.downloadModel(for: locale) }
            Button("Later", role: .cancel) { session.modelDownloadPromptLocale = nil }
        } message: { locale in
            Text("Live transcription in \(RecordingSession.localeDisplayName(locale)) needs a one-time model download. If you skip it, the download will happen when you start recording.")
        }
        .alert(
            "Rename Recording",
            isPresented: Binding(
                get: { recordingBeingRenamed != nil },
                set: { if !$0 { recordingBeingRenamed = nil } }
            ),
            presenting: recordingBeingRenamed
        ) { recording in
            TextField("Name", text: $renameText)
            Button("Save") {
                try? store.rename(recording, to: renameText)
                store.refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Enter a new name for this recording.")
        }
        .alert(
            "Delete Recording?",
            isPresented: Binding(
                get: { recordingPendingDelete != nil },
                set: { if !$0 { recordingPendingDelete = nil } }
            ),
            presenting: recordingPendingDelete
        ) { recording in
            Button("Delete", role: .destructive) { delete(recording) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This moves the recording and its transcript to the Trash.")
        }
        .sheet(isPresented: Binding(
            get: { session.isDownloadingModel },
            set: { _ in }
        )) {
            VStack(spacing: 12) {
                Text("Downloading transcription model…")
                    .font(.headline)
                ProgressView(value: session.modelDownloadProgress)
                    .frame(width: 260)
                Text("\(Int(session.modelDownloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .interactiveDismissDisabled()
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
        .task {
            session.promptModelDownloadIfNeeded()
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
