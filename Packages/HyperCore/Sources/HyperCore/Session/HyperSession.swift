import Foundation
import Observation

/// A loader whose entries can be protected from eviction while a deck holds them.
protocol TrackPinning: Sendable {
    func pin(_ url: URL) async
    func unpin(_ url: URL) async
}

extension TrackCache: TrackPinning {}

/// The HyperMusic workflow model the SwiftUI tab binds to.
///
/// Owns the `AudioCore` (not the audio host: the app wires `core` into its `AudioHost`, and
/// calls `host.replaceCore(session.core)` after `engineSampleRateChanged(to:)`), the loader,
/// the graph navigator and the feedback database.
///
/// "What is playing now" is display/logging state derived here on the main actor: `tick()`
/// polls the engine snapshot, maps deck positions to graph phrases, and runs `CentreTracker`
/// over control-state levels. None of it ever changes audio.
@MainActor @Observable
public final class HyperSession {
    public let decks: [DeckID: DeckModel]
    /// The engine. Replaced by `engineSampleRateChanged(to:)`.
    public private(set) var core: AudioCore
    /// The dominant deck (see `CentreTracker`); nil until a deck first becomes audible.
    public private(set) var centre: DeckID?
    public var centreDeck: DeckModel? { centre.flatMap { decks[$0] } }
    /// The branch phrase loaded on the non-centre deck, waiting to be mixed in.
    public private(set) var incoming: (deck: DeckID, branch: Branch)?
    /// The transition logged at the last handover; what the rating buttons rate.
    public private(set) var lastTransition: Branch?
    /// User-facing refusal or error.
    public private(set) var message: String?

    /// 0 = full A, 1 = full B.
    public var crossfader: Float = 0.5 { didSet { send(.crossfader(crossfader)) } }
    public var curve: CrossfaderCurve = .smooth { didSet { send(.curve(curve)) } }
    /// Headphone blend: 0 = PFL only, 1 = master only.
    public var cueMix: Float = 0 { didSet { send(.cueMix(cueMix)) } }
    public var masterDB: Float = 0 { didSet { send(.master(masterDB)) } }
    public var cueDB: Float = 0 { didSet { send(.cueLevel(cueDB)) } }

    /// Branches out of the centre deck's current phrase, best first, weights adjusted by feedback.
    public var branches: [Branch] {
        guard let navigator, let phrase = centreDeck?.currentPhrase else { return [] }
        return navigator.branches(from: phrase.id, limit: Self.branchLimit) { link, fromId in
            guard let feedback else { return link.weight }
            return (try? feedback.adjustedWeight(baseWeight: link.weight, from: fromId, to: link.targetId))
                ?? link.weight
        }
    }

    static let branchLimit = 8
    /// Pitch bend while a bend button is held.
    static let bendAmount = 0.04

    @ObservationIgnored private let navigator: GraphNavigator?
    @ObservationIgnored private let loader: any TrackLoading
    @ObservationIgnored private let pinner: (any TrackPinning)?
    @ObservationIgnored private let feedback: RelationshipDatabase?
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private var tracker = CentreTracker()

    public init(navigator: GraphNavigator?, loader: any TrackLoading, feedback: RelationshipDatabase?,
                sampleRate: Double, now: @escaping () -> TimeInterval) {
        self.navigator = navigator
        self.loader = loader
        self.pinner = loader as? any TrackPinning
        self.feedback = feedback
        self.now = now
        core = AudioCore(sampleRate: sampleRate)
        decks = [.a: DeckModel(id: .a), .b: DeckModel(id: .b)]
    }

    private func deck(_ d: DeckID) -> DeckModel { decks[d]! }

    // MARK: Workflow

    /// Loads `phrase`'s song on `d` at the phrase start and plays it.
    public func start(phrase: PhraseNode, on d: DeckID = .a) async {
        message = nil
        guard await load(d, phrase: phrase) else { return }
        play(d)
    }

    /// Loads the branch's target phrase on the non-centre deck, paused at the phrase start with
    /// PFL on, and marks it `incoming`. Refused when that deck is audible on master.
    public func loadBranch(_ b: Branch) async {
        let target = branchTarget(for: b)
        guard !isAudible(target) else {
            message = refusal(target)
            return
        }
        message = nil
        guard await load(target, phrase: b.to, refuseIfAudible: true) else { return }
        setPFL(target, true)
        incoming = (target, b)
    }

    public func play(_ d: DeckID) {
        guard deck(d).track != nil else { return }
        startPlayback(d, at: nil)
    }

    public func pause(_ d: DeckID) {
        guard send(.pause(d)) else { return }
        deck(d).isPlaying = false
        deck(d).commandSentAt = core.snapshot.sampleTime
    }

    /// Starts `d` on the centre deck's next downbeat (or phrase boundary), sample-accurately.
    /// Falls back to the phrase end when the phrase has no downbeats, and to an immediate start
    /// when there is no boundary ahead or no other deck is playing as the centre.
    public func quantizedStart(_ d: DeckID, target: QuantizeTarget = .nextDownbeat) {
        guard deck(d).track != nil else { return }
        let snap = core.snapshot
        let sr = core.sampleRate
        guard let c = centre, c != d, snap[c].isPlaying,
              let navigator, let path = deck(c).trackPath
        else { return startPlayback(d, at: nil) }

        let songNow = snap[c].position / sr
        guard let phrase = navigator.phrase(atSongTime: songNow, inTrack: path) else {
            return startPlayback(d, at: nil)
        }
        var targetTime: TimeInterval?
        if target == .nextDownbeat {
            targetTime = phrase.downbeats.lazy.map { phrase.songTime(ofPhraseRelative: $0) }.first { $0 > songNow }
        }
        if targetTime == nil, let end = phrase.endTime, end > songNow {
            targetTime = end
        }
        guard let targetTime else { return startPlayback(d, at: nil) }
        // Song seconds on the centre deck advance at its bend ratio per engine second.
        let frames = ((targetTime - songNow) / deck(c).bendRatio * sr).rounded()
        startPlayback(d, at: snap.sampleTime + Int64(frames))
    }

    public func nudge(_ d: DeckID, ms: Double) {
        send(.nudge(d, frames: Int((ms / 1000 * core.sampleRate).rounded())))
    }

    /// Pitch bend of ±4 % while `active`; back to 1 when released.
    public func bend(_ d: DeckID, active: Bool, up: Bool) {
        let ratio = active ? (up ? 1 + Self.bendAmount : 1 - Self.bendAmount) : 1
        if send(.bend(d, ratio)) { deck(d).bendRatio = ratio }
    }

    /// Loops the deck's current phrase, or ends the loop.
    public func toggleLoop(_ d: DeckID) {
        let deck = deck(d)
        if deck.loopEnabled {
            if send(.loop(d, nil)) { deck.loopEnabled = false }
            return
        }
        guard let phrase = deck.currentPhrase else {
            message = "Nothing to loop on deck \(Self.name(d))."
            return
        }
        let sr = core.sampleRate
        let lower = phrase.startFrame(sampleRate: sr)
        let end = phrase.endTime ?? ((phrase.startTime ?? 0) + phrase.duration)
        let upper = Int((end * sr).rounded())
        guard upper > lower else { return }
        if send(.loop(d, lower..<upper)) { deck.loopEnabled = true }
    }

    // MARK: Mixer

    public func setEQ(_ d: DeckID, _ band: EQBand, dB: Float) {
        guard send(.eq(d, band, dB)) else { return }
        switch band {
        case .low: deck(d).eq.low = dB
        case .mid: deck(d).eq.mid = dB
        case .high: deck(d).eq.high = dB
        }
    }

    public func setTrim(_ d: DeckID, dB: Float) {
        if send(.trim(d, dB)) { deck(d).trimDB = dB }
    }

    public func setFader(_ d: DeckID, _ v: Float) {
        if send(.fader(d, v)) { deck(d).fader = v }
    }

    public func setPFL(_ d: DeckID, _ on: Bool) {
        if send(.pfl(d, on)) { deck(d).pfl = on }
    }

    // MARK: Feedback

    public func rateLastTransition(_ rating: Int) {
        guard let t = lastTransition else {
            message = "No transition to rate yet."
            return
        }
        guard let feedback else {
            message = "Ratings are unavailable: no feedback database."
            return
        }
        do {
            try feedback.logRating(from: t.from.id, to: t.to.id, rating: rating)
            message = nil
        } catch {
            message = "Could not save rating: \(error.localizedDescription)"
        }
    }

    // MARK: Polling

    /// Call at about 60 Hz: reads the engine snapshot into the deck models, derives each deck's
    /// current phrase, runs the centre rule (logging the transition on handover) and releases
    /// tracks the engine has replaced.
    public func tick() {
        core.drainReleasedTracks()
        let snap = core.snapshot
        let sr = core.sampleRate
        for d in DeckID.allCases {
            let deck = deck(d)
            // Commands sent since the last render are not reflected in the snapshot yet.
            guard snap.sampleTime > deck.commandSentAt else { continue }
            let state = snap[d]
            if deck.isPlaying != state.isPlaying { deck.isPlaying = state.isPlaying }
            let seconds = state.position / sr
            if deck.positionSeconds != seconds { deck.positionSeconds = seconds }
            updatePhrase(deck)
        }
        let levels = Dictionary(uniqueKeysWithValues: DeckID.allCases.map { ($0, level($0)) })
        if let handover = tracker.update(levels: levels, now: now()) {
            handle(handover)
        }
    }

    // MARK: Sample-rate recovery

    /// Rebuilds the engine at `sr`: a new `AudioCore` with every mixer control re-sent, loaded
    /// tracks re-decoded at `sr` and restored at the same position in seconds, with their play,
    /// loop and bend state. The caller then hands `core` to the audio host.
    public func engineSampleRateChanged(to sr: Double) async {
        guard sr > 0, sr != core.sampleRate else { return }
        let old = core
        let snap = old.snapshot

        var restores: [Restore] = []
        for d in DeckID.allCases {
            let deck = deck(d)
            guard deck.loadState != .loading else {
                // The in-flight load notices the new rate, re-decodes and loads the new core.
                clearTrack(deck)
                continue
            }
            guard let url = deck.track, let path = deck.trackPath else { continue }
            let seconds = snap.sampleTime > deck.commandSentAt ? snap[d].position / old.sampleRate
                                                               : deck.positionSeconds
            restores.append(Restore(deck: d, url: url, path: path, seconds: seconds, playing: deck.isPlaying,
                                    loop: deck.loopEnabled, bend: deck.bendRatio))
            deck.positionSeconds = seconds
            deck.commandSentAt = .max      // tick leaves the deck alone until it is reloaded
        }

        old.drainReleasedTracks()          // the old core releases the rest in its deinit
        core = AudioCore(sampleRate: sr, maxFrames: old.maxFrames)
        sendMixerState()

        await withDiscardingTaskGroup { group in
            for r in restores {
                group.addTask { await self.restore(r) }
            }
        }
    }

    private struct Restore: Sendable {
        let deck: DeckID
        let url: URL
        let path: String
        let seconds: Double
        let playing: Bool
        let loop: Bool
        let bend: Double
    }

    private func restore(_ r: Restore) async {
        let deck = deck(r.deck)
        guard await load(r.deck, url: r.url, trackPath: r.path, at: r.seconds, keepsIncoming: true) else {
            if deck.commandSentAt == .max { deck.commandSentAt = -1 }
            return
        }
        if r.loop { toggleLoop(r.deck) }
        if r.bend != 1, send(.bend(r.deck, r.bend)) { deck.bendRatio = r.bend }
        if r.playing { play(r.deck) }
    }

    private func sendMixerState() {
        for d in DeckID.allCases {
            let deck = deck(d)
            send(.eq(d, .low, deck.eq.low))
            send(.eq(d, .mid, deck.eq.mid))
            send(.eq(d, .high, deck.eq.high))
            send(.trim(d, deck.trimDB))
            send(.fader(d, deck.fader))
            send(.pfl(d, deck.pfl))
        }
        send(.crossfader(crossfader))
        send(.curve(curve))
        send(.cueMix(cueMix))
        send(.master(masterDB))
        send(.cueLevel(cueDB))
    }

    // MARK: Loading

    private func load(_ d: DeckID, phrase: PhraseNode, refuseIfAudible: Bool = false) async -> Bool {
        await load(d, url: URL(fileURLWithPath: phrase.sourceTrack), trackPath: phrase.sourceTrack,
                   at: phrase.startTime ?? 0, refuseIfAudible: refuseIfAudible)
    }

    /// Decodes `url` and loads it paused at `seconds` (song time). Latest call per deck wins:
    /// a completion whose generation is no longer current is discarded. Returns true when the
    /// `.load` reached the engine.
    private func load(_ d: DeckID, url: URL, trackPath: String, at seconds: Double,
                      refuseIfAudible: Bool = false, keepsIncoming: Bool = false) async -> Bool {
        let deck = deck(d)
        deck.loadGeneration &+= 1
        let generation = deck.loadGeneration
        if !keepsIncoming, incoming?.deck == d { incoming = nil }
        let stateBefore = deck.loadState
        deck.loadState = .loading

        await pinner?.pin(url)
        var sampleRate = core.sampleRate
        var track: AudioTrack
        do {
            track = try await loader.track(for: url, sampleRate: sampleRate)
            // The engine was rebuilt at another rate while decoding: decode again for it.
            while deck.loadGeneration == generation, core.sampleRate != sampleRate {
                sampleRate = core.sampleRate
                track = try await loader.track(for: url, sampleRate: sampleRate)
            }
        } catch {
            unpin(url)
            guard deck.loadGeneration == generation else { return false }
            deck.loadState = .failed(Self.describe(error))
            message = "Deck \(Self.name(d)) could not load \(url.lastPathComponent): \(Self.describe(error))"
            return false
        }
        guard deck.loadGeneration == generation else {
            unpin(url)
            return false
        }
        if refuseIfAudible, isAudible(d) {
            // The deck went live while decoding; loading now would cut it.
            unpin(url)
            deck.loadState = stateBefore
            message = refusal(d)
            return false
        }

        let startFrame = Int((seconds * sampleRate).rounded())
        let retained = Unmanaged.passRetained(track)
        guard core.send(.load(d, retained, startFrame: startFrame)) else {
            retained.release()
            unpin(url)
            deck.loadState = .failed("Audio engine busy")
            message = "Deck \(Self.name(d)) could not load: the audio engine is not keeping up."
            return false
        }
        // `.load` keeps the deck's previous loop and bend.
        send(.loop(d, nil))
        send(.bend(d, 1))

        if let previous = deck.pinnedURL { unpin(previous) }
        deck.pinnedURL = url
        deck.track = url
        deck.trackPath = trackPath
        deck.loadState = .ready
        deck.loopEnabled = false
        deck.bendRatio = 1
        deck.isPlaying = false
        deck.positionSeconds = Double(startFrame) / sampleRate
        deck.commandSentAt = core.snapshot.sampleTime
        updatePhrase(deck)
        return true
    }

    private func clearTrack(_ deck: DeckModel) {
        deck.track = nil
        deck.trackPath = nil
        deck.currentPhrase = nil
        deck.isPlaying = false
        deck.loopEnabled = false
        deck.bendRatio = 1
        deck.commandSentAt = -1
    }

    private func unpin(_ url: URL) {
        guard let pinner else { return }
        Task { await pinner.unpin(url) }
    }

    // MARK: Helpers

    private func startPlayback(_ d: DeckID, at sampleTime: Int64?) {
        guard send(.play(d, at: sampleTime)) else { return }
        deck(d).isPlaying = true
        deck(d).commandSentAt = core.snapshot.sampleTime
    }

    private func updatePhrase(_ deck: DeckModel) {
        guard let navigator, let path = deck.trackPath else {
            if deck.currentPhrase != nil { deck.currentPhrase = nil }
            return
        }
        let phrase = navigator.phrase(atSongTime: deck.positionSeconds, inTrack: path)
        if phrase?.id != deck.currentPhrase?.id { deck.currentPhrase = phrase }
    }

    private func handle(_ handover: Handover) {
        centre = handover.to
        guard let pending = incoming, pending.deck == handover.to else { return }
        incoming = nil
        lastTransition = pending.branch
        do {
            try feedback?.logPlayed(from: pending.branch.from.id, to: pending.branch.to.id, source: .performance)
        } catch {
            message = "Could not log transition: \(error.localizedDescription)"
        }
    }

    /// The deck a branch loads onto: the one that is not the centre.
    private func branchTarget(for b: Branch) -> DeckID {
        if let centre { return Self.other(centre) }
        for d in DeckID.allCases where deck(d).currentPhrase?.id == b.from.id { return Self.other(d) }
        return .b
    }

    /// Effective level from control state (never measured audio).
    private func level(_ d: DeckID) -> Double {
        let deck = deck(d)
        let xf = Mixer.crossfaderGains(crossfader, curve: curve)
        let trim = deck.trimDB.isFinite ? powf(10, min(max(deck.trimDB, -12), 12) / 20) : 1
        let fader = deck.fader.isNaN ? 0 : min(max(deck.fader, 0), 1)
        return effectiveLevel(isPlaying: deck.isPlaying, trim: trim, fader: fader * fader,
                              crossfaderGain: d == .a ? xf.a : xf.b,
                              eqLinear: (IsolatorEQ.linear(deck.eq.low), IsolatorEQ.linear(deck.eq.mid),
                                         IsolatorEQ.linear(deck.eq.high)))
    }

    private func isAudible(_ d: DeckID) -> Bool { level(d) > 0 }

    private func refusal(_ d: DeckID) -> String {
        "Deck \(Self.name(d)) is live on master. Pull its fader or the crossfader away before loading."
    }

    @discardableResult
    private func send(_ c: CoreCommand) -> Bool {
        let ok = core.send(c)
        if !ok { message = "The audio engine is not keeping up; a control change was dropped." }
        return ok
    }

    private static func other(_ d: DeckID) -> DeckID { d == .a ? .b : .a }
    private static func name(_ d: DeckID) -> String { d == .a ? "A" : "B" }

    private static func describe(_ error: Error) -> String {
        switch error {
        case TrackLoadError.fileNotFound(let url): return "file not found (\(url.path))"
        case TrackLoadError.unreadable(_, let reason): return "unreadable: \(reason)"
        default: return error.localizedDescription
        }
    }
}
