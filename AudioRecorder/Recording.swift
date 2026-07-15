import Foundation

/// A finished recording on disk: the mixed .m4a plus its optional transcript.
struct Recording: Identifiable, Hashable {
    let url: URL
    let date: Date
    let duration: TimeInterval
    let transcriptURL: URL?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct RecordingSidebarPresentation: Equatable {
    let title: String

    init(recording: Recording) {
        title = recording.name
    }
}
