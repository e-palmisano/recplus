import SwiftUI

@main
struct AudioRecorderApp: App {
    @StateObject private var session = RecordingSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
    }
}
