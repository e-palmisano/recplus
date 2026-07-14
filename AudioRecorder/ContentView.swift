import SwiftUI

struct ContentView: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        RecorderView(session: session)
            .frame(minWidth: 420, minHeight: 360)
            .onAppear { session.refreshMics() }
    }
}

#Preview {
    ContentView(session: RecordingSession())
}
