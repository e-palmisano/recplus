import SwiftUI

/// Floating glass control cluster: Pause/Resume (secondary) and
/// Record/Stop (primary, red). State is derived via `RecordControlState`
/// so the logic stays testable; this view only renders + binds actions.
struct RecordControlCluster: View {
    let session: RecordingSession

    private var state: RecordControlState {
        .derive(isRecording: session.isRecording, isPaused: session.isPaused)
    }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 18) {
                secondaryButton
                primaryButton
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(in: .rect(cornerRadius: 18))
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    private var primaryButton: some View {
        Button {
            state.primary == .stop ? session.stop() : session.start()
        } label: {
            Label(
                state.primary == .stop ? "Stop" : "Record",
                systemImage: state.primary == .stop ? "stop.fill" : "record.circle.fill"
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .disabled(!state.primaryEnabled)
        .help(state.primary == .stop ? "Stop recording" : "Start recording")
    }

    private var secondaryButton: some View {
        Button {
            session.togglePause()
        } label: {
            Label(
                state.secondary == .resume ? "Resume" : "Pause",
                systemImage: state.secondary == .resume ? "play.fill" : "pause.fill"
            )
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 34, height: 34)
        }
        .disabled(!state.secondaryEnabled)
        .help(state.secondary == .resume ? "Resume recording" : "Pause recording")
    }
}
