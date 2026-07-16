import SwiftUI
import AppKit
import Foundation

@main
struct AudioRecorderApp: App {
    @State private var session = RecordingSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    session.releaseTranscriptionResources()
                }
        }
        .commands {
            CommandMenu("Recording") {
                Button(session.isRecording ? "Stop Recording" : "Start Recording") {
                    session.isRecording ? session.stop() : session.start()
                }
                .keyboardShortcut("r")

                Button(session.isPaused ? "Resume" : "Pause") {
                    session.togglePause()
                }
                .keyboardShortcut("p")
                .disabled(!session.isRecording)

                Divider()

                Button("Show Last Recording in Finder") {
                    if let url = session.lastRecordingURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(session.lastRecordingURL == nil)
            }
        }
    }
}
