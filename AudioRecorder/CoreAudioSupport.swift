import Foundation
import CoreAudio
import AudioToolbox

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isValid: Bool { self != .unknown }
}

extension AudioObjectID {
    static func readDefaultSystemOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioObjectID.unknown)
    }

    static func readDefaultInputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, defaultValue: AudioObjectID.unknown)
    }

    /// All Core Audio devices currently installed on the system.
    static func readAllDevices() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, defaultValue: AudioObjectID.unknown)
    }

    func readDeviceUID() throws -> String { try readString(kAudioDevicePropertyDeviceUID) }
    func readDeviceName() throws -> String { try readString(kAudioObjectPropertyName) }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    /// Number of input channels this device exposes, 0 if it's an output-only device.
    func readInputChannelCount() throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr, dataSize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }

        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, bufferListPointer)
        guard err == noErr else { return 0 }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Generic property access

extension AudioObjectID {
    func readArray<T>(_ selector: AudioObjectPropertySelector, defaultValue: T) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "Error reading data size for \(selector): \(err)" }

        var value = [T](repeating: defaultValue, count: Int(dataSize) / MemoryLayout<T>.size)
        err = value.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard err == noErr else { throw "Error reading array for \(selector): \(err)" }

        return value
    }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "Error reading data size for \(selector): \(err)" }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else { throw "Error reading data for \(selector): \(err)" }

        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(selector, defaultValue: "" as CFString) as String
    }
}
