import Foundation
import HyperCore
import Observation

/// HyperCore's deck identifier (the app module has a legacy `DeckID` of its own).
typealias HyperDeckID = HyperCore.DeckID

/// App-lifetime owner of HyperMusic audio: the `AudioHost`, the `HyperSession` and the track
/// cache. Wires host callbacks into the session, drives `session.tick()` at 60 Hz, loads the
/// phrase graph and persists the output routing.
@MainActor @Observable
final class AppAudio {
    /// Replaced when the graph is (re)loaded.
    private(set) var session: HyperSession
    /// nil until a graph has loaded.
    private(set) var navigator: GraphNavigator?
    /// Why there is no graph (old schema, missing file, …); shown in place of the graph.
    private(set) var graphError: String?
    private(set) var isLoadingGraph = false
    /// The routing the user chose (the host may be playing a fallback; see `activeRouting`).
    private(set) var routing: OutputRouting?
    var activeRouting: OutputRouting? { host.activeRouting }
    /// The ratings/transition database; nil until started or when it could not be opened.
    private(set) var feedback: RelationshipDatabase?
    private(set) var feedbackError: String?

    @ObservationIgnored private let host: AudioHost
    @ObservationIgnored private let cache = TrackCache(loader: TrackDecoder())
    @ObservationIgnored private let routingStore = RoutingStore(defaults: .standard)
    @ObservationIgnored private var rateChanges: SerialSampleRateChanges!
    @ObservationIgnored private var installedCore: AudioCore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var branchCache: (key: String, branches: [Branch])?

    init() {
        let rate = SystemDevices().defaultOutput()?.nominalSampleRate ?? 48_000
        let empty = HyperSession(navigator: nil, loader: cache, feedback: nil,
                                 sampleRate: rate > 0 ? rate : 48_000, now: { ProcessInfo.processInfo.systemUptime })
        session = empty
        installedCore = empty.core
        host = AudioHost(core: empty.core)
        rateChanges = SerialSampleRateChanges { [weak self] rate in await self?.applySampleRate(rate) }
        host.onSampleRateChange = { [weak self] rate in self?.rateChanges.submit(rate) }
        host.onRoutingFallback = { [weak self] fallback in
            self?.session.report("Output fell back to \(Self.describe(fallback)): a chosen device is unavailable.")
        }
    }

    /// Opens the feedback database and starts audio, the 60 Hz tick and the graph load, once.
    /// Skipped inside the unit-test host so tests never open audio devices or touch
    /// `~/Documents/MusicMill`.
    func startIfNeeded() {
        guard !started, !Self.isRunningTests else { return }
        started = true
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let db = RelationshipDatabase()
        do {
            try db.open()
            feedback = db
        } catch {
            feedbackError = "Ratings and transition logging are off: \(error.localizedDescription)"
        }
        startHost(routing: routingStore.load() ?? Self.defaultRouting())
        Task { await loadGraph() }
    }

    // MARK: Graph

    /// Loads the phrase graph off the main thread and, on success, replaces the session with one
    /// that navigates it and starts deck A on a random phrase. A failure leaves an empty session
    /// and sets `graphError`.
    func loadGraph() async {
        guard !isLoadingGraph else { return }
        isLoadingGraph = true
        defer { isLoadingGraph = false }
        let url = PhraseGraph.defaultURL
        let result = await Task.detached(priority: .userInitiated) { () -> Result<GraphNavigator, Error> in
            Result { GraphNavigator(graph: try PhraseGraph.load(from: url)) }
        }.value
        switch result {
        case .failure(let error):
            navigator = nil
            graphError = error.localizedDescription
        case .success(let nav):
            graphError = nil
            navigator = nav
            branchCache = nil
            let pendingMessage = session.message      // e.g. an output error from startup
            session = HyperSession(navigator: nav, loader: cache, feedback: feedback,
                                   sampleRate: host.sampleRate, now: { ProcessInfo.processInfo.systemUptime })
            installCore()
            if let phrase = nav.randomStart() {
                await session.start(phrase: phrase, on: .a)
            }
            if let pendingMessage, session.message == nil { session.report(pendingMessage) }
        }
    }

    /// Loads a random phrase on the deck that is not the centre (deck A before anything plays).
    /// It plays only when nothing else is playing; otherwise it is cued paused with PFL on.
    func randomStart() async {
        guard let phrase = navigator?.randomStart() else { return }
        let deck: HyperDeckID = session.centre.map { $0 == .a ? .b : .a } ?? .a
        await session.start(phrase: phrase, on: deck)
    }

    /// The phrases of `phrase`'s song, in order.
    func sequence(of phrase: PhraseNode) -> [PhraseNode] {
        navigator?.phrases(inTrack: phrase.sourceTrack) ?? []
    }

    /// The song's length as covered by the graph (its last phrase end).
    func trackDuration(of phrase: PhraseNode) -> Double? {
        sequence(of: phrase).compactMap { p in p.endTime ?? p.startTime.map { $0 + p.duration } }.max()
    }

    /// `session.branches`, cached per centre phrase (each read of the session's list queries the
    /// feedback database).
    var branches: [Branch] {
        let s = session
        guard let centre = s.centre, let phrase = s.centreDeck?.currentPhrase else { return [] }
        let key = "\(ObjectIdentifier(s))|\(centre)|\(phrase.id)|\(s.lastTransition?.id ?? "")"
        if let branchCache, branchCache.key == key { return branchCache.branches }
        let fresh = s.branches
        branchCache = (key, fresh)
        return fresh
    }

    // MARK: Output

    func setRouting(_ r: OutputRouting) {
        routingStore.save(r)
        startHost(routing: r)
    }

    private func startHost(routing r: OutputRouting) {
        routing = r
        do {
            try host.start(routing: r)
        } catch {
            session.report("Audio output could not start: \(error.localizedDescription)")
        }
    }

    private static func defaultRouting() -> OutputRouting {
        .stereo(masterUID: SystemDevices().defaultOutput()?.uid ?? "")
    }

    static func describe(_ r: OutputRouting) -> String {
        let names = Dictionary(SystemDevices().outputDevices().map { ($0.uid, $0.name) }, uniquingKeysWith: { a, _ in a })
        func name(_ uid: String) -> String { names[uid] ?? uid }
        switch r {
        case .stereo(let m): return "\(name(m)) (master only)"
        case .splitCue(let d): return "\(name(d)) (split cue)"
        case .separate(let m, let c): return "\(name(m)) + cue on \(name(c))"
        case .multichannel(let d): return "\(name(d)) (master 1/2, cue 3/4)"
        }
    }

    // MARK: Sample-rate recovery

    /// Rebuilds the session's engine at `rate` and hands the new core to the host. Runs one at a
    /// time (see `SerialSampleRateChanges`).
    private func applySampleRate(_ rate: Double) async {
        let s = session
        await s.engineSampleRateChanged(to: rate)
        guard s === session else { return }     // the graph was reloaded meanwhile
        installCore()
    }

    /// Hands `session.core` to the host unless it already has it.
    private func installCore() {
        guard session.core !== installedCore else { return }
        installedCore = session.core
        do {
            try host.replaceCore(session.core)
        } catch {
            session.report("Audio output could not restart: \(error.localizedDescription)")
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Runs sample-rate changes one at a time. A rate submitted while one runs is remembered (only
/// the latest) and applied after it returns.
@MainActor
final class SerialSampleRateChanges {
    private let apply: @MainActor (Double) async -> Void
    private var pending: Double?
    private(set) var isRunning = false

    init(apply: @escaping @MainActor (Double) async -> Void) {
        self.apply = apply
    }

    func submit(_ rate: Double) {
        pending = rate
        guard !isRunning else { return }
        isRunning = true
        Task { await drain() }
    }

    private func drain() async {
        while let rate = pending {
            pending = nil
            await apply(rate)
        }
        isRunning = false
    }
}
