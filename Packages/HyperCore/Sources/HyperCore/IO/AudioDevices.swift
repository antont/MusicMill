import CoreAudio
import Foundation

public struct AudioDeviceInfo: Sendable, Hashable, Identifiable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let outputChannels: Int
    public let nominalSampleRate: Double

    public init(id: AudioDeviceID, uid: String, name: String, outputChannels: Int, nominalSampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
    }
}

public protocol DeviceProviding: Sendable {
    /// Devices with at least one output channel.
    func outputDevices() -> [AudioDeviceInfo]
    func defaultOutput() -> AudioDeviceInfo?
}

/// The system's CoreAudio output devices, excluding MusicMill's own aggregate devices.
public struct SystemDevices: DeviceProviding {
    public init() {}

    public func outputDevices() -> [AudioDeviceInfo] {
        Self.allDeviceIDs()
            .compactMap(Self.info)
            .filter { $0.outputChannels > 0 && !AggregateDevice.isOwn(uid: $0.uid) }
    }

    public func defaultOutput() -> AudioDeviceInfo? {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return Self.info(id)
    }

    // MARK: CoreAudio property access

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(system, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        // The list may have shrunk between the two calls.
        return Array(ids.prefix(Int(size) / stride))
    }

    static func info(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDeviceInfo(id: id, uid: uid,
                               name: string(id, kAudioObjectPropertyName) ?? uid,
                               outputChannels: outputChannels(id),
                               nominalSampleRate: nominalSampleRate(id))
    }

    /// A CFString property. CoreAudio returns it at +1, so it is taken as a retained value.
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Sum of the channels of all output streams. The buffer list has a variable number of
    /// buffers, so it lives in a raw allocation of the size CoreAudio reports.
    static func outputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}
