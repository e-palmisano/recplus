import Foundation
import AVFoundation
import Observation

/// Thin AVAudioPlayer wrapper driving the playback UI (play/pause + scrubber).
@MainActor
@Observable
final class AudioPlayerController {
    private var player: AVAudioPlayer?
    private var timer: Timer?

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    var progress: TimeInterval = 0

    func load(url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            duration = player.duration
            errorMessage = nil
        } catch {
            errorMessage = "Cannot play recording: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        progress = time
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        player = nil
        isPlaying = false
        progress = 0
        duration = 0
    }

    private func tick() {
        guard let player else { return }
        progress = player.currentTime
        if !player.isPlaying, isPlaying {
            // Reached the end.
            isPlaying = false
            timer?.invalidate()
            progress = 0
        }
    }
}
