import Foundation
import AudioToolbox
import AVFoundation
import OSLog

/// Taps the system's default output device so all audio played on the Mac can be
/// captured, while leaving normal playback completely untouched (the tap is a
/// passive listener, not a reroute — nothing stops sounding out of the speakers).
@Observable
final class SystemAudioTap {
    private let logger = Logger(subsystem: "com.tiller.AudioRecorder", category: "SystemAudioTap")

    private(set) var errorMessage: String?

    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    private var activated = false

    func activate() throws {
        guard !activated else { return }
        activated = true
        errorMessage = nil

        do {
            try prepare()
        } catch {
            activated = false
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    private func prepare() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted // keep audio playing through the speakers
        tapDescription.isPrivate = true
        tapDescription.name = "AudioRecorder System Tap"

        var newTapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard err == noErr else { throw "Failed to create system audio tap: \(err)" }
        tapID = newTapID

        let outputDeviceID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputDeviceID.readDeviceUID()
        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRecorder-SystemTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else { throw "Failed to create aggregate device: \(err)" }
        aggregateDeviceID = newAggregateID

        let aggregateNominalRate = try? aggregateDeviceID.read(kAudioDevicePropertyNominalSampleRate, defaultValue: Double(0))

        var streamDescription = try tapID.readAudioTapStreamBasicDescription()

        // The tap always declares the system mixer's nominal rate (48kHz), but the
        // aggregate device's IO cycle actually runs at whatever rate its main
        // sub-device (the real output device) is physically operating at — e.g. a
        // Bluetooth headset in HFP mode runs at 16kHz. When those differ, the
        // buffers we receive already contain audio at the aggregate's real rate,
        // just mislabeled as 48kHz, which played the system track back sped up.
        if let aggregateNominalRate, aggregateNominalRate > 0 {
            streamDescription.mSampleRate = aggregateNominalRate
        }
        tapStreamDescription = streamDescription
    }

    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else { throw "Failed to create device I/O proc: \(err)" }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start system audio tap: \(err)" }
    }

    deinit { invalidate() }
}

/// Writes the tapped system audio to a file for the duration of a recording.
final class SystemAudioRecorder {
    private let logger = Logger(subsystem: "com.tiller.AudioRecorder", category: "SystemAudioRecorder")
    private let tap = SystemAudioTap()
    private let queue = DispatchQueue(label: "com.tiller.AudioRecorder.SystemAudioRecorder", qos: .userInteractive)
    private var file: AVAudioFile?
    private(set) var isRecording = false

    func start(to fileURL: URL) throws {
        guard !isRecording else { return }

        try tap.activate()

        guard var streamDescription = tap.tapStreamDescription else {
            throw "System audio tap format not available."
        }
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw "Failed to create audio format from system tap."
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        file = audioFile

        try tap.run(on: queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            try? file.write(from: buffer)
        }

        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        file = nil
        tap.invalidate()
    }
}
