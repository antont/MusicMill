import Testing
import Foundation
import AVFoundation
import CoreAudio
import Synchronization
@testable import HyperCore

/// A device list the test can change between `start` and `handleConfigurationChange`.
final class FakeDevices: DeviceProviding {
    let list: Mutex<[AudioDeviceInfo]>
    init(_ devices: [AudioDeviceInfo]) { list = Mutex(devices) }
    func set(_ devices: [AudioDeviceInfo]) { list.withLock { $0 = devices } }
    func outputDevices() -> [AudioDeviceInfo] { list.withLock { $0 } }
    func defaultOutput() -> AudioDeviceInfo? { list.withLock { $0.first } }
}

/// Stands in for the hardware: records what AudioHost asks of it and never opens a device.
final class StubHardware: Sendable {
    struct State {
        var bound: [AudioDeviceID] = []
        var startedChannels: [Int] = []
        var startedRates: [Double] = []
        var stops = 0
        var created: [[String]] = []
        var destroyed: [AudioDeviceID] = []
        var listeners = 0
        var failStartOn: Set<AudioDeviceID> = []
    }
    static let aggregateID: AudioDeviceID = 99
    let state = Mutex(State())
    let channels: @Sendable (AudioDeviceID) -> Int
    let hardwareRate: Double

    init(hardwareRate: Double = 44100, channels: @escaping @Sendable (AudioDeviceID) -> Int) {
        self.hardwareRate = hardwareRate
        self.channels = channels
    }

    var starter: EngineStarting {
        EngineStarting(
            bindDevice: { _, id in
                self.state.withLock { $0.bound.append(id) }
                return OutputFormat(channels: self.channels(id), sampleRate: self.hardwareRate)
            },
            start: { engine, node, format in
                let fail = self.state.withLock { s in s.failStartOn.contains(s.bound.last ?? 0) }
                if fail { throw AudioHostError.engineStartFailed("stub") }
                self.state.withLock {
                    $0.startedChannels.append(Int(format.channelCount))
                    $0.startedRates.append(format.sampleRate)
                }
            },
            stop: { _ in self.state.withLock { $0.stops += 1 } },
            createAggregate: { m, c in
                self.state.withLock { $0.created.append([m, c]) }
                return StubHardware.aggregateID
            },
            destroyAggregate: { id in self.state.withLock { $0.destroyed.append(id) } },
            listenDeviceList: { _ in
                self.state.withLock { $0.listeners += 1 }
                return { self.state.withLock { $0.listeners -= 1 } }
            })
    }
}

private let m = device("speakers", id: 10)
private let c = device("phones", id: 11)

private func stubFor(_ devices: [AudioDeviceInfo], hardwareRate: Double = 44100) -> StubHardware {
    StubHardware(hardwareRate: hardwareRate) { id in
        id == StubHardware.aggregateID ? 4 : devices.first { $0.id == id }?.outputChannels ?? 0
    }
}

private func dcTrack(_ value: Float, sampleRate: Double, frames: Int) -> AudioTrack {
    let s = [Float](repeating: value, count: frames)
    return AudioTrack(url: URL(fileURLWithPath: "/tmp/dc.wav"), sampleRate: sampleRate, left: s, right: s)
}

@MainActor @Suite struct AudioHostTests {
    @Test func offlineRenderProducesDeckAudio() throws {
        let core = AudioCore(sampleRate: 44100)
        let ok = core.send(.load(.a, Unmanaged.passRetained(dcTrack(0.25, sampleRate: 44100, frames: 44100)),
                                 startFrame: 0))
        #expect(ok)
        #expect(core.send(.fader(.a, 1)))
        #expect(core.send(.crossfader(0)))
        #expect(core.send(.play(.a, at: nil)))
        let out = try AudioHost.renderOffline(core: core, routing: .stereo(masterUID: "x"),
                                              deviceChannels: 2, frames: 4096)
        #expect(out.count == 2)
        #expect(out[0].count == 4096)
        #expect(out[0].last.map { abs($0) > 0.1 } == true)
        #expect(out[1].last.map { abs($0) > 0.1 } == true)
        core.drainReleasedTracks()
    }

    @Test func offlineRenderMapsCueToChannels3And4() throws {
        let core = AudioCore(sampleRate: 44100, maxFrames: 256)   // forces chunking in the block
        _ = core.send(.load(.a, Unmanaged.passRetained(dcTrack(0.25, sampleRate: 44100, frames: 44100)),
                            startFrame: 0))
        _ = core.send(.fader(.a, 0))          // nothing on master
        _ = core.send(.pfl(.a, true))         // deck A on cue
        _ = core.send(.play(.a, at: nil))
        let out = try AudioHost.renderOffline(core: core, routing: .multichannel(deviceUID: "x"),
                                              deviceChannels: 6, frames: 4096)
        #expect(out.count == 6)
        #expect(out[0].suffix(2048).allSatisfy { $0 == 0 })   // after the 10 ms fader ramp
        #expect(out[2].last.map { abs($0) > 0.1 } == true)
        #expect(out[3].last.map { abs($0) > 0.1 } == true)
        #expect(out[4].allSatisfy { $0 == 0 })
        #expect(out[5].allSatisfy { $0 == 0 })
        core.drainReleasedTracks()
    }

    @Test func configurationChangeWithMissingCueFallsBackToStereo() throws {
        let devices = FakeDevices([m, c])
        let hw = stubFor([m, c])
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: devices, engineStarting: hw.starter)
        var fallbacks: [OutputRouting] = []
        host.onRoutingFallback = { fallbacks.append($0) }

        try host.start(routing: .separate(masterUID: "speakers", cueUID: "phones"))
        #expect(host.activeRouting == .separate(masterUID: "speakers", cueUID: "phones"))
        #expect(host.currentLayout == [.masterL, .masterR, .cueL, .cueR])
        #expect(hw.state.withLock { $0.created } == [["speakers", "phones"]])
        #expect(fallbacks.isEmpty)

        devices.set([m])                         // headphones unplugged
        host.handleConfigurationChange()

        #expect(host.activeRouting == .stereo(masterUID: "speakers"))
        #expect(fallbacks == [.stereo(masterUID: "speakers")])
        #expect(host.currentLayout == [.masterL, .masterR])
        let s = hw.state.withLock { $0 }
        #expect(s.destroyed == [StubHardware.aggregateID])
        #expect(s.bound == [StubHardware.aggregateID, 10])
        #expect(s.startedChannels == [4, 2])     // master kept playing on the speakers

        // Repeated changes with the cue still missing rebuild again but do not re-announce.
        host.handleConfigurationChange()
        #expect(host.activeRouting == .stereo(masterUID: "speakers"))
        #expect(fallbacks.count == 1)

        // Headphones come back: the requested routing is restored.
        devices.set([m, c])
        host.handleConfigurationChange()
        #expect(host.activeRouting == .separate(masterUID: "speakers", cueUID: "phones"))
        #expect(fallbacks.count == 1)
        host.stop()
    }

    @Test func configurationChangeBeforeStartIsANoOp() {
        let hw = stubFor([m])
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m]), engineStarting: hw.starter)
        host.handleConfigurationChange()
        host.handleConfigurationChange()
        #expect(host.activeRouting == nil)
        #expect(hw.state.withLock { $0.bound.isEmpty && $0.startedChannels.isEmpty })
    }

    @Test func aggregateFailureFallsBackToStereoMaster() throws {
        let hw = stubFor([m, c])
        hw.state.withLock { $0.failStartOn = [StubHardware.aggregateID] }
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m, c]),
                             engineStarting: hw.starter)
        var fallbacks: [OutputRouting] = []
        host.onRoutingFallback = { fallbacks.append($0) }
        try host.start(routing: .separate(masterUID: "speakers", cueUID: "phones"))
        #expect(host.activeRouting == .stereo(masterUID: "speakers"))
        #expect(fallbacks == [.stereo(masterUID: "speakers")])
        #expect(hw.state.withLock { $0.destroyed } == [StubHardware.aggregateID])
        host.stop()
    }

    @Test func startThrowsWhenNoDeviceCanBeOpened() {
        let hw = stubFor([m])
        hw.state.withLock { $0.failStartOn = [10] }
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m]), engineStarting: hw.starter)
        #expect(throws: AudioHostError.self) { try host.start(routing: .stereo(masterUID: "speakers")) }
        #expect(host.activeRouting == nil)
        #expect(hw.state.withLock { $0.listeners } == 0)
    }

    @Test func stopTearsDownAggregateAndListeners() throws {
        let hw = stubFor([m, c])
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m, c]),
                             engineStarting: hw.starter)
        try host.start(routing: .separate(masterUID: "speakers", cueUID: "phones"))
        #expect(hw.state.withLock { $0.listeners } == 1)
        host.stop()
        let s = hw.state.withLock { $0 }
        #expect(s.listeners == 0)
        #expect(s.destroyed == [StubHardware.aggregateID])
        #expect(s.stops == 1)
        #expect(host.activeRouting == nil)
        host.stop()                               // idempotent
        #expect(hw.state.withLock { $0.stops } == 1)
    }

    @Test func releasingHostCleansUp() throws {
        let hw = stubFor([m, c])
        do {
            let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m, c]),
                                 engineStarting: hw.starter)
            try host.start(routing: .separate(masterUID: "speakers", cueUID: "phones"))
        }
        let s = hw.state.withLock { $0 }
        #expect(s.listeners == 0)
        #expect(s.destroyed == [StubHardware.aggregateID])
    }

    @Test func sampleRateMismatchIsReportedAndReplaceCoreRebuilds() throws {
        let hw = stubFor([m], hardwareRate: 48000)
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m]), engineStarting: hw.starter)
        var rates: [Double] = []
        host.onSampleRateChange = { rates.append($0) }
        try host.start(routing: .stereo(masterUID: "speakers"))
        #expect(host.sampleRate == 48000)
        #expect(rates == [48000])

        try host.replaceCore(AudioCore(sampleRate: 48000))
        #expect(rates == [48000])                 // core now matches the device
        let s = hw.state.withLock { $0 }
        #expect(s.startedRates == [44100, 48000]) // source node rebuilt at the new core's rate
        #expect(s.stops == 1)
        #expect(host.activeRouting == .stereo(masterUID: "speakers"))
        host.stop()
    }

    @Test func replaceCoreWhileStoppedDoesNotStart() throws {
        let hw = stubFor([m])
        let host = AudioHost(core: AudioCore(sampleRate: 44100), devices: FakeDevices([m]), engineStarting: hw.starter)
        try host.replaceCore(AudioCore(sampleRate: 48000))
        #expect(hw.state.withLock { $0.startedChannels.isEmpty })
        #expect(host.activeRouting == nil)
    }
}
