import Observation

/// Live input level readouts, deliberately kept OUT of `RecordingSession`'s
/// `@Published` state: levels update ~40×/sec, and `ObservableObject`
/// invalidation is object-granular — every published change re-rendered the
/// whole window (sidebar, toolbar, all the Liquid Glass layers) at 40Hz,
/// which lagged and froze the UI during recording. `@Observable` tracking is
/// property-granular, so only the view that actually reads `mic`/`system`
/// (the meter capsules) re-renders.
@Observable
@MainActor
final class AudioLevels {
    var mic: Float = 0
    var system: Float = 0

    func reset() {
        mic = 0
        system = 0
    }
}
