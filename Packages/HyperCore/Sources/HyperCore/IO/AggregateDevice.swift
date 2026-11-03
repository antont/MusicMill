import CoreAudio
import Foundation

/// A private CoreAudio aggregate of the master and cue devices, so one engine (one clock)
/// drives both. Master is first (its outputs are the aggregate's first channels) and is the
/// clock source; the cue sub-device is drift-compensated against it.
///
/// Private aggregates are visible only to this process and vanish when it exits.
enum AggregateDevice {
    static let uidPrefix = "net.beyondlabs.musicmill.aggregate."

    /// The aggregate description passed to `AudioHardwareCreateAggregateDevice`.
    static func description(masterUID: String, cueUID: String, uid: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "MusicMill Master + Cue",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: masterUID,
            kAudioAggregateDeviceClockDeviceKey: masterUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: masterUID, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: cueUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
    }

    static func isOwn(uid: String) -> Bool { uid.hasPrefix(uidPrefix) }

    static func create(masterUID: String, cueUID: String) throws -> AudioDeviceID {
        let desc = description(masterUID: masterUID, cueUID: cueUID, uid: uidPrefix + UUID().uuidString)
        var id = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw AudioHostError.aggregateCreationFailed(status)
        }
        return id
    }

    static func destroy(_ id: AudioDeviceID) {
        _ = AudioHardwareDestroyAggregateDevice(id)
    }
}
