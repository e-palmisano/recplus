import SwiftUI
import AppKit

/// Glass panel showing finalized transcript lines plus the pending (still
/// changing) tail, with autoscroll and a copy-to-clipboard button.
struct TranscriptPanel: View {
    let lines: [TranscriptLine]
    let pendingText: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text("[\(RecordingFormat.transcriptTimestamp(line.offset))] \(line.text)")
                                .font(.body)
                                .id(index)
                        }
                        if !pendingText.isEmpty {
                            Text(pendingText)
                                .font(.body.italic())
                                .foregroundStyle(.secondary)
                                .id("pending")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: lines.count) { _, newCount in
                    guard newCount > 0 else { return }
                    if pendingText.isEmpty {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    } else {
                        proxy.scrollTo("pending", anchor: .bottom)
                    }
                }
                .onChange(of: pendingText) { _, _ in
                    proxy.scrollTo("pending", anchor: .bottom)
                }
            }

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(TranscriptWriter.text(for: lines), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy transcript")
            .padding(8)
            .disabled(lines.isEmpty)
        }
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}
