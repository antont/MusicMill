import AVFoundation
import CoreAudio
import Foundation

public enum AudioHostError: Error, Equatable {
    case deviceNotFound(String)
    case aggregateCreationFailed(OSStatus)
    case setDeviceFailed(OSStatus)
    case unsupportedFormat(channels: Int)
    case engineStartFailed(String)
    /// The aggregate device came up without the cue sub-device's outputs.
    case aggregateMissingCueChannels(Int)
    case offlineRenderFailed
}

/// The output device's format as seen by the engine's output node.
struct OutputFormat: Equatable {
    var channels: Int
    var sampleRate: Double
}

/// Everything AudioHost asks of the hardware, injectable so tests never open a device.
struct EngineStarting: Sendable {
    /// Points the engine's output unit at `device` and returns its output format.
    var bindDevice: @Sendable (AVAudioEngine, AudioDeviceID) throws -> OutputFormat
    /// Attaches `node`, connects it to the output node in `format` and starts the engine.
    var start: @Sendable (AVAudioEngine, AVAudioSourceNode, AVAudioFormat) throws -> Void
    var stop: @Sendable (AVAudioEngine) -> Void
    var createAggregate: @Sendable (_ masterUID: String, _ cueUID: String) throws -> AudioDeviceID
    var destroyAggregate: @Sendable (AudioDeviceID) -> Void
    /// Calls `handler` on the main queue when the system device list changes; returns the
    /// function that unregisters it.
    var listenDeviceList: @Sendable (_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void

    static let system = EngineStarting(
        bindDevice: { engine, device in
            guard let unit = engine.outputNode.audioUnit else { throw AudioHostError.setDeviceFailed(-1) }
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                              0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioHostError.setDeviceFailed(status) }
            let f = engine.outputNode.outputFormat(forBus: 0)
            return OutputFormat(channels: Int(f.channelCount), sampleRate: f.sampleRate)
        },
        start: { engine, node, format in
            engine.attach(node)
            engine.connect(node, to: engine.outputNode, format: format)
            engine.prepare()
            do { try engine.start() } catch { throw AudioHostError.engineStartFailed("\(error)") }
        },
        stop: { $0.stop() },
        createAggregate: { try AggregateDevice.create(masterUID: $0, cueUID: $1) },
        destroyAggregate: { AggregateDevice.destroy($0) },
        listenDeviceList: { handler in
            let system = AudioObjectID(kAudioObjectSystemObject)
            let addr = SystemDevices.address(kAudioHardwarePropertyDevices)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            var a = addr
            guard AudioObjectAddPropertyListenerBlock(system, &a, DispatchQueue.main, block) == noErr else {
                return {}
            }
            nonisolated(unsafe) let registered = block
            return {
                var a = addr
                _ = AudioObjectRemovePropertyListenerBlock(system, &a, DispatchQueue.main, registered)
            }
        })
}

/// Connects an `AudioCore` to the output hardware: one `AVAudioEngine`, one
/// `AVAudioSourceNode` rendering the core and mapping its four channels onto the device per
/// `channelLayout`. For `.separate` routing the device is a private aggregate of the master
/// and cue devices.
///
/// The requested routing is kept across configuration changes: when a device disappears the
/// host falls back (for example `.separate` → `.stereo(master)`, so master keeps playing) and
/// returns to the requested routing when the device comes back.
@MainActor public final class AudioHost {
    public private(set) var activeRouting: OutputRouting?
    /// The output device's sample rate (the core's rate before the first start).
    public private(set) var sampleRate: Double
    /// Fires with the device rate when it differs from the core's; the owner recreates the
    /// core at that rate and calls `replaceCore`.
    public var onSampleRateChange: ((Double) -> Void)?
    /// Fires with the routing actually in use when it differs from the requested one.
    public var onRoutingFallback: ((OutputRouting) -> Void)?

    private(set) var core: AudioCore
    private let devices: any DeviceProviding
    private let hardware: EngineStarting
    /// The user's choice; `nil` while stopped.
    private var requestedRouting: OutputRouting?
    private var graph: LiveGraph?
    private var deviceListToken: Cancellation?
    private var configurationChangeScheduled = false

    public convenience init(core: AudioCore, devices: any DeviceProviding = SystemDevices()) {
        self.init(core: core, devices: devices, engineStarting: .system)
    }

    init(core: AudioCore, devices: any DeviceProviding, engineStarting: EngineStarting) {
        self.core = core
        self.devices = devices
        self.hardware = engineStarting
        self.sampleRate = core.sampleRate
    }

    /// The channel layout of the running graph (test-visible).
    var currentLayout: [OutputSource?]? { graph?.layout }

    /// Starts playing `routing`, or the closest routing that can run on the current devices
    /// (reported through `onRoutingFallback`). Throws when no device can be opened.
    public func start(routing: OutputRouting) throws {
        stop()
        // Committed before bringUp: its callbacks may call replaceCore, which must see the
        // host as started and rebuild with this routing.
        requestedRouting = routing
        do { try bringUp(routing) } catch {
            stop()
            throw error
        }
        let token = hardware.listenDeviceList { [weak self] in
            MainActor.assumeIsolated { self?.deviceListChanged() }
        }
        deviceListToken = Cancellation(token)
    }

    public func stop() {
        deviceListToken = nil
        graph?.teardown()
        graph = nil
        requestedRouting = nil
        activeRouting = nil
    }

    /// Swaps in a core (for example one recreated at a new sample rate) and, if running,
    /// rebuilds the source node for it and restarts with the requested routing.
    public func replaceCore(_ newCore: AudioCore) throws {
        graph?.teardown()
        graph = nil
        core = newCore
        guard let routing = requestedRouting else { return }
        do { try bringUp(routing) } catch {
            activeRouting = nil
            throw error
        }
    }

    /// Re-resolves the requested routing against the current devices, rebuilds the graph and
    /// restarts. Safe before `start` (no-op) and when called repeatedly. If nothing can be
    /// opened the host stays silent but keeps the requested routing, so a later device
    /// change can bring it back.
    func handleConfigurationChange() {
        guard let routing = requestedRouting else { return }
        graph?.teardown()
        graph = nil
        do { try bringUp(routing) } catch { activeRouting = nil }
    }

    // MARK: Building

    private func deviceListChanged() {
        if deviceListNeedsRebuild() { scheduleConfigurationChange() }
    }

    /// Whether the current device list calls for a rebuild (test-visible): the requested
    /// routing now resolves differently, or a device it uses was replaced. Unrelated devices
    /// coming and going (including our own aggregate, which `outputDevices` filters out) do
    /// not interrupt playback.
    func deviceListNeedsRebuild() -> Bool {
        guard let requested = requestedRouting else { return false }
        guard let graph else { return true }        // silent after a failed rebuild: retry
        let list = devices.outputDevices()
        let routing = resolve(requested, devices: list, defaultUID: devices.defaultOutput()?.uid)
        return routing != activeRouting || AudioHost.deviceIDs(of: routing, in: list) != graph.deviceIDs
    }

    /// The IDs of the devices `routing` plays on, in routing order (missing ones omitted).
    private static func deviceIDs(of routing: OutputRouting, in list: [AudioDeviceInfo]) -> [AudioDeviceID] {
        let uids: [String]
        if case let .separate(m, c) = routing { uids = [m, c] } else { uids = [routing.masterUID] }
        return uids.compactMap { uid in list.first { $0.uid == uid }?.id }
    }

    /// Coalesces bursts of notifications (device list + engine configuration) into one rebuild.
    private func scheduleConfigurationChange() {
        guard !configurationChangeScheduled else { return }
        configurationChangeScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            configurationChangeScheduled = false
            handleConfigurationChange()
        }
    }

    private func bringUp(_ requested: OutputRouting) throws {
        let list = devices.outputDevices()
        let defaultUID = devices.defaultOutput()?.uid
        var routing = resolve(requested, devices: list, defaultUID: defaultUID)
        let built: LiveGraph
        do {
            built = try buildGraph(routing, devices: list)
        } catch {
            // An aggregate or multichannel device that will not open: keep master playing.
            let stereo = resolve(.stereo(masterUID: routing.masterUID), devices: list, defaultUID: defaultUID)
            guard stereo != routing else { throw error }
            routing = stereo
            built = try buildGraph(routing, devices: list)
        }
        graph = built
        let previous = activeRouting
        activeRouting = routing
        sampleRate = built.hardwareRate
        if routing != requested && routing != previous { onRoutingFallback?(routing) }
        if built.hardwareRate != core.sampleRate { onSampleRateChange?(built.hardwareRate) }
    }

    private func buildGraph(_ routing: OutputRouting, devices list: [AudioDeviceInfo]) throws -> LiveGraph {
        func find(_ uid: String) throws -> AudioDeviceInfo {
            guard let d = list.first(where: { $0.uid == uid }) else { throw AudioHostError.deviceNotFound(uid) }
            return d
        }
        let master = try find(routing.masterUID)
        var aggregate: AudioDeviceID?
        var deviceIDs = [master.id]
        if case let .separate(_, cueUID) = routing {
            deviceIDs.append(try find(cueUID).id)
            aggregate = try hardware.createAggregate(master.uid, cueUID)
        }
        let engine = AVAudioEngine()
        let graph = LiveGraph(engine: engine, aggregate: aggregate, hardware: hardware)
        graph.deviceIDs = deviceIDs
        do {
            let out = try hardware.bindDevice(engine, aggregate ?? master.id)
            if aggregate != nil && out.channels < master.outputChannels + 2 {
                throw AudioHostError.aggregateMissingCueChannels(out.channels)
            }
            let layout = channelLayout(for: routing, deviceChannels: out.channels, masterChannels: master.outputChannels)
            let format = try AudioHost.renderFormat(sampleRate: core.sampleRate, channels: out.channels)
            let resources = RenderResources(core: core, layout: layout)
            // Owned by the graph before the engine can render, so every teardown path stops
            // the engine before the render block's memory is freed.
            graph.resources = resources
            try hardware.start(engine, resources.makeSourceNode(format: format), format)
            graph.layout = layout
            graph.hardwareRate = out.sampleRate
        } catch {
            graph.teardown()
            throw error
        }
        graph.observeConfigurationChanges { [weak self] in self?.scheduleConfigurationChange() }
        return graph
    }

    /// Deinterleaved float at `sampleRate` with `channels` discrete channels.
    nonisolated static func renderFormat(sampleRate: Double, channels: Int) throws -> AVAudioFormat {
        guard channels > 0 else { throw AudioHostError.unsupportedFormat(channels: channels) }
        let format: AVAudioFormat?
        if channels <= 2 {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        } else {
            let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
            format = AVAudioChannelLayout(layoutTag: tag)
                .map { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: $0) }
        }
        guard let format else { throw AudioHostError.unsupportedFormat(channels: channels) }
        return format
    }

    // MARK: Offline

    /// Renders `frames` frames of `core` through the same source node and channel layout as
    /// the live path, using the engine's offline manual rendering mode. For `.separate` the
    /// master device is assumed to have 2 outputs. Returns one array per device channel.
    public nonisolated static func renderOffline(core: AudioCore, routing: OutputRouting, deviceChannels: Int,
                                                 frames: Int) throws -> [[Float]] {
        let layout = channelLayout(for: routing, deviceChannels: deviceChannels, masterChannels: 2)
        let format = try renderFormat(sampleRate: core.sampleRate, channels: deviceChannels)
        let resources = RenderResources(core: core, layout: layout)
        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 1024
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        let node = resources.makeSourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
        try engine.start()
        defer { engine.stop() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk),
              let data = buffer.floatChannelData else { throw AudioHostError.offlineRenderFailed }
        var out = [[Float]](repeating: [], count: deviceChannels)
        for ch in 0..<deviceChannels { out[ch].reserveCapacity(frames) }
        // The source node's block holds only a raw pointer into `resources`.
        try withExtendedLifetime(resources) {
            var remaining = frames
            while remaining > 0 {
                let n = AVAudioFrameCount(min(Int(chunk), remaining))
                guard try engine.renderOffline(n, to: buffer) == .success else {
                    throw AudioHostError.offlineRenderFailed
                }
                let got = Int(buffer.frameLength)
                for ch in 0..<deviceChannels {
                    out[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: got))
                }
                remaining -= got
            }
        }
        return out
    }
}

/// Runs a cleanup closure once, when released.
private final class Cancellation {
    private let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

/// One running engine and what it owns. `teardown` (also run on release) stops the engine
/// before anything the render block uses is freed, then destroys the aggregate device.
private final class LiveGraph {
    let engine: AVAudioEngine
    let aggregate: AudioDeviceID?
    let hardware: EngineStarting
    var resources: RenderResources?
    /// Master (and cue) device IDs this graph plays on.
    var deviceIDs: [AudioDeviceID] = []
    var layout: [OutputSource?] = []
    var hardwareRate: Double = 0
    private var observer: NSObjectProtocol?
    private var tornDown = false

    init(engine: AVAudioEngine, aggregate: AudioDeviceID?, hardware: EngineStarting) {
        self.engine = engine
        self.aggregate = aggregate
        self.hardware = hardware
    }

    @MainActor func observeConfigurationChanges(_ handler: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hardware.stop(engine)
        if let aggregate { hardware.destroyAggregate(aggregate) }
    }

    deinit { teardown() }
}

/// What the render block reads: plain values and raw pointers only.
private struct RenderState {
    var core: Unmanaged<AudioCore>
    /// Four `maxFrames` channels: master L, master R, cue L, cue R.
    var scratch: UnsafeMutablePointer<Float>
    var maxFrames: Int
    var layout: UnsafeMutablePointer<OutputSource?>
    var channels: Int
}

/// Owns the render block's memory and keeps the core alive while the block may run. It must
/// outlive the engine's rendering: release it only after the engine has stopped.
private final class RenderResources: @unchecked Sendable {
    let core: AudioCore
    let state: UnsafeMutablePointer<RenderState>

    init(core: AudioCore, layout: [OutputSource?]) {
        self.core = core
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4 * core.maxFrames)
        scratch.initialize(repeating: 0, count: 4 * core.maxFrames)
        let map = UnsafeMutablePointer<OutputSource?>.allocate(capacity: max(layout.count, 1))
        map.initialize(from: layout, count: layout.count)
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState(core: .passUnretained(core), scratch: scratch, maxFrames: core.maxFrames,
                                         layout: map, channels: layout.count))
    }

    deinit {
        state.pointee.scratch.deallocate()
        state.pointee.layout.deinitialize(count: state.pointee.channels)
        state.pointee.layout.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let handle = StateHandle(pointer: state)
        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            isSilence.pointee = false
            renderBlock(handle.pointer, frames: Int(frameCount), into: bufferList)
            return noErr
        }
    }
}

private struct StateHandle: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<RenderState>
}

/// The render callback. Render thread: no allocation, locks, ARC or Objective-C. Renders the
/// core in `maxFrames` chunks into the scratch channels and copies each device channel from
/// its source; unmapped channels (and any beyond the layout) are zero-filled.
private func renderBlock(_ s: UnsafeMutablePointer<RenderState>, frames: Int,
                         into bufferList: UnsafeMutablePointer<AudioBufferList>) {
    let st = s.pointee
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let mL = st.scratch, mR = mL + st.maxFrames, cL = mR + st.maxFrames, cR = cL + st.maxFrames
    let out = FourChannelOut(masterL: mL, masterR: mR, cueL: cL, cueR: cR)
    var done = 0
    while done < frames {
        let n = min(st.maxFrames, frames - done)
        st.core._withUnsafeGuaranteedRef { $0.render(frames: n, out: out) }
        for ch in 0..<buffers.count {
            guard let raw = buffers[ch].mData else { continue }
            let dst = raw.assumingMemoryBound(to: Float.self) + done
            switch ch < st.channels ? st.layout[ch] : nil {
            case .masterL?: dst.update(from: mL, count: n)
            case .masterR?: dst.update(from: mR, count: n)
            case .cueL?: dst.update(from: cL, count: n)
            case .cueR?: dst.update(from: cR, count: n)
            case .splitCueMono?: for i in 0..<n { dst[i] = 0.5 * (cL[i] + cR[i]) }
            case .splitMasterMono?: for i in 0..<n { dst[i] = 0.5 * (mL[i] + mR[i]) }
            case nil: dst.update(repeating: 0, count: n)
            }
        }
        done += n
    }
}
