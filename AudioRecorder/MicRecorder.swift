import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct MicDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
}

enum MicDeviceList {
    /// All Core Audio devices that expose at least one input channel.
    static func available() -> [MicDevice] {
        guard let deviceIDs = try? AudioObjectID.readAllDevices() else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let channels = try? deviceID.readInputChannelCount(), channels > 0 else { return nil }
            guard let name = try? deviceID.readDeviceName() else { return nil }
            return MicDevice(id: deviceID, name: name)
        }
    }

    static func systemDefault() -> AudioObjectID? {
        try? AudioObjectID.readDefaultInputDevice()
    }
}

/// Records the selected microphone to a file, independent of and simultaneous
/// with any other app (or this app's own system audio tap) using the mic.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var isRecording = false
    var onBuffer: ((AVAudioPCMBuffer, AVAudioFormat) -> Void)?
    /// While true, tap callbacks drop buffers: nothing is written to the file
    /// and nothing is forwarded to onBuffer. Set from the main thread; read on
    /// the audio thread (benign single-Bool race, same pattern as `file`).
    var isPaused = false

    func start(to fileURL: URL, deviceID: AudioObjectID) throws {
        guard !isRecording else { return }

        let inputNode = engine.inputNode

        if let audioUnit = inputNode.audioUnit {
            var mutableDeviceID = deviceID
            let err = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            guard err == noErr else { throw "Failed to select microphone device: \(err)" }
        }

        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw "Selected microphone has no active input format." }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        file = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, !self.isPaused, let file = self.file else { return }
            try? file.write(from: buffer)
            self.onBuffer?(buffer, format)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}
