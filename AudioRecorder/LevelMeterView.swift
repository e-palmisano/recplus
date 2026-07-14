import SwiftUI

/// A thin capsule level bar with a leading SF Symbol label. `level` is 0…1.
struct LevelMeterView: View {
    let symbolName: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.85 ? Color.red : Color.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
