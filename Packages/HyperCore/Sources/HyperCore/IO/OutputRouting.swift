import Foundation

/// How the core's four channels (master L/R, cue L/R) reach the hardware. Persisted by the app.
public enum OutputRouting: Codable, Hashable, Sendable {
    /// Master on channels 1/2 of one device; no cue.
    case stereo(masterUID: String)
    /// One stereo device: left = cue (mono), right = master (mono).
    case splitCue(deviceUID: String)
    /// Master on one device, cue on another, joined in a private aggregate device.
    case separate(masterUID: String, cueUID: String)
    /// One device with ≥ 4 outputs: master on 1/2, cue on 3/4.
    case multichannel(deviceUID: String)

    /// The device that carries master.
    var masterUID: String {
        switch self {
        case let .stereo(u), let .splitCue(u), let .multichannel(u): u
        case let .separate(u, _): u
        }
    }
}

/// What a hardware output channel plays.
public enum OutputSource: Hashable, Sendable {
    case masterL, masterR, cueL, cueR
    /// (cue L + cue R) / 2
    case splitCueMono
    /// (master L + master R) / 2
    case splitMasterMono
}

/// The routing that can actually run on `devices`.
///
/// - A referenced device that is missing falls back to `.stereo` on the master device if it is
///   present, else on `defaultUID` (if present), else on the first device. With no devices at all
///   the result is `.stereo(masterUID)`, which then fails to start.
/// - `.separate` with the cue device missing becomes `.stereo(master)` (Review Focus #1).
/// - `.separate` naming the same device twice becomes `.multichannel` on it (≥ 4 outputs) or `.stereo`.
/// - `.multichannel` on a device with fewer than 4 outputs becomes `.stereo` on it.
public func resolve(_ r: OutputRouting, devices: [AudioDeviceInfo], defaultUID: String? = nil) -> OutputRouting {
    func find(_ uid: String) -> AudioDeviceInfo? { devices.first { $0.uid == uid } }
    func fallback() -> OutputRouting {
        let uid = find(r.masterUID)?.uid
            ?? defaultUID.flatMap(find)?.uid
            ?? devices.first?.uid
            ?? r.masterUID
        return .stereo(masterUID: uid)
    }
    func onOneDevice(_ d: AudioDeviceInfo) -> OutputRouting {
        d.outputChannels >= 4 ? .multichannel(deviceUID: d.uid) : .stereo(masterUID: d.uid)
    }

    switch r {
    case let .stereo(u), let .splitCue(u):
        return find(u) == nil ? fallback() : r
    case let .multichannel(u):
        guard let d = find(u) else { return fallback() }
        return d.outputChannels >= 4 ? r : .stereo(masterUID: u)
    case let .separate(mu, cu):
        guard let master = find(mu) else { return fallback() }
        if mu == cu { return onOneDevice(master) }
        return find(cu) == nil ? .stereo(masterUID: mu) : r
    }
}

/// The source for each of the device's `deviceChannels` output channels; `nil` is silence.
///
/// For `.separate` the device is the aggregate: the master device's `masterChannels` outputs
/// come first, so master is on 0/1 and cue on `masterChannels`/`masterChannels + 1`.
public func channelLayout(for r: OutputRouting, deviceChannels: Int, masterChannels: Int) -> [OutputSource?] {
    var layout = [OutputSource?](repeating: nil, count: max(deviceChannels, 0))
    func put(_ s: OutputSource, at i: Int) { if i >= 0 && i < layout.count { layout[i] = s } }
    switch r {
    case .stereo:
        put(.masterL, at: 0); put(.masterR, at: 1)
    case .splitCue:
        put(.splitCueMono, at: 0); put(.splitMasterMono, at: 1)
    case .multichannel:
        put(.masterL, at: 0); put(.masterR, at: 1); put(.cueL, at: 2); put(.cueR, at: 3)
    case .separate:
        put(.masterL, at: 0); put(.masterR, at: 1)
        put(.cueL, at: masterChannels); put(.cueR, at: masterChannels + 1)
    }
    return layout
}
