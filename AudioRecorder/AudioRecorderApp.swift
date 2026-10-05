import SwiftUI
import AppKit
import Foundation

/// Owns the session so quitting can be held back: the `.m4a` is only written
/// by the mix-down after Stop, and exiting mid-encode leaves a truncated file.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = RecordingSession()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if session.isRecording {
            guard confirmStopRecording() else { return .terminateCancel }
            session.stop()
        }
        Task {
            await session.waitForPendingFinalization()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmStopRecording() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A recording is in progress."
        alert.informativeText = "Quitting stops and saves the recording first. Saving can take a few seconds."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@main
struct AudioRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var session: RecordingSession { appDelegate.session }

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
