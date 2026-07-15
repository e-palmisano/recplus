import SwiftUI

/// Reads the high-frequency `AudioLevels` values inside its own body so that
/// 40Hz level updates re-render only these two capsules — the parent
/// (`RecorderView`) passes the object through without reading its properties,
/// keeping itself out of the Observation dependency set.
struct LevelMetersView: View {
    let levels: AudioLevels

    var body: some View {
        VStack(spacing: 8) {
            LevelMeterView(symbolName: "mic.fill", level: levels.mic)
            LevelMeterView(symbolName: "speaker.wave.2.fill", level: levels.system)
        }
    }
}

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
