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
///
/// Runs a HAL IOProc directly on the device, like `SystemAudioTap`, instead of
/// AVAudioEngine: on macOS 27 the engine re-binds its input node to the system
/// default ~50 ms after another device is selected, and stops itself on any
/// rate/channel change (a Bluetooth headset switching profile when a call
/// starts). The IOProc keeps running through both; a format change only swaps
/// the converter feeding the file, which keeps the format it was created with.
///
/// `@unchecked Sendable`: the IOProc and the property listener run on `queue`
/// (so `deviceFormat`/`converter` need no lock); start/stop/pause run on the
/// main thread — the same benign single-value races as `SystemAudioRecorder`.
final class MicRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tiller.AudioRecorder.MicRecorder", qos: .userInteractive)
    private var deviceID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var deviceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Host time the next IOProc buffer should start at; only touched on `queue`.
    private var expectedHostTime: UInt64?
    private var didReportFailure = false
    private(set) var isRecording = false
    var onBuffer: ((AVAudioPCMBuffer, AVAudioFormat) -> Void)?
    /// While true, IOProc callbacks drop buffers: nothing is written to the
    /// file and nothing is forwarded to onBuffer. Set from the main thread;
    /// read on `queue` (benign single-Bool race, same pattern as `file`).
    var isPaused = false
    /// Called on the main thread when the mic can no longer be recorded
    /// mid-session (device disconnected, or a format that can't be converted).
    var onFailure: ((String) -> Void)?

    private static let watchedProperties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)
    ]
    /// Stored once: removing a listener needs the very block object that was added.
    private lazy var propertyListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.deviceChanged()
    }

    func start(to fileURL: URL, deviceID: AudioObjectID) throws {
        guard !isRecording else { return }

        let format = try Self.inputFormat(of: deviceID)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.deviceID = deviceID
        didReportFailure = false
        queue.sync {
            expectedHostTime = nil
            adopt(format)
        }

        do {
            try startIOProc()
        } catch {
            tearDown()
            throw error
        }
        isRecording = true
    }

    /// Moves a running recording to another microphone without closing the
    /// file: the new device's buffers go through `adopt`'s converter, and the
    /// switch gap is padded — `expectedHostTime` survives the switch because
    /// host time is one system-wide clock, not per device. If the new device
    /// won't start, recording falls back to the previous one and this throws.
    func switchDevice(to newDeviceID: AudioObjectID) throws {
        guard isRecording, newDeviceID != deviceID else { return }
        guard let newFormat = try? Self.inputFormat(of: newDeviceID) else {
            throw "The selected microphone isn't available."
        }
        let previousDeviceID = deviceID

        stopIOProc()
        deviceID = newDeviceID
        didReportFailure = false
        queue.sync { adopt(newFormat) }
        do {
            try startIOProc()
        } catch {
            stopIOProc()
            deviceID = previousDeviceID
            // The previous device is often the one that just died — if it
            // won't restart either, say so instead of recording nothing.
            do {
                let previousFormat = try Self.inputFormat(of: previousDeviceID)
                queue.sync { adopt(previousFormat) }
                try startIOProc()
            } catch {
                reportFailure("The microphone stopped. Recording continues with system audio only.")
            }
            throw error
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        tearDown()
    }

    private func startIOProc() throws {
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
            self?.write(inInputData, at: inInputTime)
        }
        guard err == noErr else { throw "Failed to open the microphone: \(err)" }
        for (selector, scope) in Self.watchedProperties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, propertyListener)
        }
        let startErr = AudioDeviceStart(deviceID, procID)
        guard startErr == noErr else {
            stopIOProc()
            throw "Failed to start the microphone: \(startErr)"
        }
    }

    private func stopIOProc() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        for (selector, scope) in Self.watchedProperties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, propertyListener)
        }
    }

    private func tearDown() {
        stopIOProc()
        // Drain any IOProc/listener work still queued before the file closes.
        queue.sync {
            deviceFormat = nil
            converter = nil
            expectedHostTime = nil
            // On `queue`, so a listener event still in flight can't read `file`
            // in `adopt()` while it's being released.
            file = nil
        }
    }

    /// Runs on `queue`.
    private func write(_ inInputData: UnsafePointer<AudioBufferList>, at inputTime: UnsafePointer<AudioTimeStamp>) {
        guard !isPaused else {
            // Paused time is dropped from both tracks on purpose — never pad it back.
            expectedHostTime = nil
            return
        }
        guard let file, let format = deviceFormat, inInputData.pointee.mNumberBuffers > 0 else { return }
        // ponytail: first input stream only — multi-stream interfaces record stream 1.
        let firstStream = AudioBufferList(mNumberBuffers: 1, mBuffers: inInputData.pointee.mBuffers)
        // A buffer from before the listener caught up with a channel change.
        guard firstStream.mBuffers.mNumberChannels == format.channelCount || !format.isInterleaved else { return }

        withUnsafePointer(to: firstStream) { bufferList in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil) else { return }
            // The device may deliver nothing while it reconfigures (~0.75 s
            // for a USB webcam changing rate): fill that with silence so the
            // mic stays aligned with the system track for the mix-down.
            if inputTime.pointee.mFlags.contains(.hostTimeValid) {
                let hostTime = inputTime.pointee.mHostTime
                let padding = Self.paddingFrames(expectedHostTime: expectedHostTime, actualHostTime: hostTime, sampleRate: file.processingFormat.sampleRate)
                Self.writeSilence(frames: padding, to: file)
                let duration = Double(buffer.frameLength) / format.sampleRate
                expectedHostTime = hostTime + AudioConvertNanosToHostTime(UInt64(duration * 1e9))
            }
            // A failed conversion drops the buffer: AVAudioFile.write accepts a
            // mismatched format silently and would store it at the wrong rate.
            let output = converter == nil ? buffer : converter.flatMap { Self.convert(buffer, with: $0) }
            if let output { try? file.write(from: output) }
            onBuffer?(buffer, format)
        }
    }

    /// Runs on `queue`. ponytail: the few buffers between a rate change and
    /// this listener firing are written as if still at the old rate (a
    /// sub-second glitch, not a drift).
    private func deviceChanged() {
        let isAlive = (try? deviceID.read(kAudioDevicePropertyDeviceIsAlive, defaultValue: UInt32(0))) ?? 0
        guard isAlive != 0 else {
            reportFailure("The microphone was disconnected. Recording continues with system audio only.")
            return
        }
        guard let format = try? Self.inputFormat(of: deviceID) else { return }
        adopt(format)
    }

    /// Runs on `queue`.
    private func adopt(_ format: AVAudioFormat) {
        guard let fileFormat = file?.processingFormat else { return }
        if Self.formatsMatch(format, fileFormat) {
            deviceFormat = format
            converter = nil
        } else if let newConverter = AVAudioConverter(from: format, to: fileFormat) {
            deviceFormat = format
            converter = newConverter
        } else {
            deviceFormat = nil
            reportFailure("The microphone switched to an unsupported format. Recording continues with system audio only.")
        }
    }

    private func reportFailure(_ message: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    /// Format the device's IOProc delivers for its first input stream.
    static func inputFormat(of deviceID: AudioObjectID) throws -> AVAudioFormat {
        let streams = try deviceID.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, defaultValue: AudioObjectID.unknown)
        guard let stream = streams.first else { throw "Selected microphone has no input stream." }
        var description = try stream.read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
        guard description.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &description) else {
            throw "Selected microphone has no active input format."
        }
        return format
    }

    /// Below this, a late timestamp is scheduling jitter, not lost audio.
    private static let gapThreshold: TimeInterval = 0.02
    /// ponytail: guards against a bogus timestamp; no real device stall
    /// mid-recording comes close to this.
    static let maxPaddingSeconds: TimeInterval = 4 * 3_600

    /// Silent frames (at `sampleRate`) for the stretch between where the
    /// previous buffer ended and where this one starts, on the device's own
    /// clock. Also re-aligns the timeline after the few buffers that arrive at
    /// a new rate before `deviceChanged()` swaps the converter.
    static func paddingFrames(expectedHostTime: UInt64?, actualHostTime: UInt64, sampleRate: Double) -> Int {
        guard let expectedHostTime, actualHostTime > expectedHostTime else { return 0 }
        let gap = Double(AudioConvertHostTimeToNanos(actualHostTime - expectedHostTime)) / 1e9
        guard gap > gapThreshold else { return 0 }
        return Int((min(gap, maxPaddingSeconds) * sampleRate).rounded())
    }

    /// Written in ≤1 s chunks so a long gap never allocates its whole length
    /// at once on the IOProc queue.
    private static func writeSilence(frames: Int, to file: AVAudioFile) {
        let chunkCapacity = AVAudioFrameCount(file.processingFormat.sampleRate)
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkCapacity) else { return }
        silence.frameLength = chunkCapacity
        for channelBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = channelBuffer.mData { memset(data, 0, Int(channelBuffer.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int(chunkCapacity)))
            guard (try? file.write(from: silence)) != nil else { return }
            remaining -= Int(silence.frameLength)
        }
    }

    /// What `AVAudioFile.write(from:)` requires; channel layout is irrelevant.
    static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    /// Streams `buffer` through `converter` without ending the stream, so the
    /// resampler keeps its state across consecutive IOProc buffers.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }

        var didProvideBuffer = false
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            if didProvideBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideBuffer = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }
}
