import Foundation

/// Pure derivation of the floating control cluster's button states.
/// Kept free of SwiftUI concerns so it is unit-testable. The matching
/// `RecordControlCluster` view turns this value into buttons.
struct RecordControlState: Equatable, Sendable {
    enum Primary: Equatable, Sendable { case record, stop }
    enum Secondary: Equatable, Sendable { case pause, resume }

    let primary: Primary
    let primaryEnabled: Bool
    let secondary: Secondary
    let secondaryEnabled: Bool

    /// - Parameters:
    ///   - isRecording: whether a recording is currently active.
    ///   - isPaused: whether the active recording is paused. Ignored when
    ///     `isRecording` is false (prevents a stale paused flag from
    ///     flipping the idle secondary to `.resume`).
    ///   - hasMic: whether a microphone is selected — gates Record.
    static func derive(isRecording: Bool, isPaused: Bool, hasMic: Bool) -> Self {
        if isRecording {
            return .init(
                primary: .stop,
                primaryEnabled: true,
                secondary: isPaused ? .resume : .pause,
                secondaryEnabled: true
            )
        }
        return .init(
            primary: .record,
            primaryEnabled: hasMic,
            secondary: .pause,
            secondaryEnabled: false
        )
    }
}
