import Testing
import Foundation
@testable import HyperCore

// MARK: - Test doubles

/// A `TrackLoading` whose requests either complete at once with a silent track (`autoComplete`)
/// or wait until the test calls `complete` / `fail`. Tracks are recorded weakly so tests can
/// see when the engine has released them.
final class FakeLoader: TrackLoading, @unchecked Sendable {
    struct Call: Equatable { let url: URL; let sampleRate: Double }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var pending: [(url: URL, sampleRate: Double, continuation: CheckedContinuation<AudioTrack, Error>)] = []
    private var weakTracks: [WeakTrack] = []
    private let autoComplete: Bool
    private let failing: Set<URL>
    /// Track length in seconds (silent).
    let seconds: Double

    final class WeakTrack { weak var track: AudioTrack?; init(_ t: AudioTrack) { track = t } }

    init(autoComplete: Bool = true, failing: Set<URL> = [], seconds: Double = 80) {
        self.autoComplete = autoComplete
        self.failing = failing
        self.seconds = seconds
    }

    var calls: [Call] { lock.withLock { _calls } }
    var pendingCount: Int { lock.withLock { pending.count } }
    /// Tracks this loader produced that are still alive, oldest first.
    var liveTracks: [AudioTrack] { lock.withLock { weakTracks.compactMap(\.track) } }

    func track(for url: URL, sampleRate: Double) async throws -> AudioTrack {
        lock.withLock { _calls.append(Call(url: url, sampleRate: sampleRate)) }
        if failing.contains(url) { throw TrackLoadError.fileNotFound(url) }
        if autoComplete { return make(url, sampleRate) }
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { pending.append((url, sampleRate, c)) }
        }
    }

    /// Completes the oldest pending request for `url`.
    func complete(_ url: URL) {
        let entry: (url: URL, sampleRate: Double, continuation: CheckedContinuation<AudioTrack, Error>)? =
            lock.withLock {
                guard let i = pending.firstIndex(where: { $0.url == url }) else { return nil }
                return pending.remove(at: i)
            }
        guard let entry else { Issue.record("no pending load for \(url.lastPathComponent)"); return }
        entry.continuation.resume(returning: make(entry.url, entry.sampleRate))
    }

    private func make(_ url: URL, _ sampleRate: Double) -> AudioTrack {
        let frames = Int(seconds * sampleRate)
        let silence = [Float](repeating: 0, count: frames)
        let t = AudioTrack(url: url, sampleRate: sampleRate, left: silence, right: silence)
        lock.withLock { weakTracks.append(WeakTrack(t)) }
        return t
    }
}

/// Mutable clock read by the session's injected `now` closure.
@MainActor final class TestClock {
    var t: TimeInterval = 0
}

// MARK: - Helpers

private let sr = 44100.0
private let trackA = "/fixtures/music/Track A.mp3"
private let trackB = "/fixtures/music/Track B.flac"

@MainActor
private func render(_ core: AudioCore, frames: Int) {
    var buf = [Float](repeating: 0, count: 4 * frames)
    buf.withUnsafeMutableBufferPointer { p in
        let b = p.baseAddress!
        core.render(frames: frames, out: FourChannelOut(masterL: b, masterR: b + frames,
                                                        cueL: b + 2 * frames, cueR: b + 3 * frames))
    }
}

@MainActor
private struct Rig {
    let session: HyperSession
    let loader: FakeLoader
    let clock: TestClock
    let navigator: GraphNavigator
    let db: RelationshipDatabase?

    init(loader: FakeLoader = FakeLoader(), graph: PhraseGraph? = nil, withDB: Bool = false,
         sampleRate: Double = sr) throws {
        let graph = try graph ?? PhraseGraph.load(from: fixture("graph_v2.json"))
        navigator = GraphNavigator(graph: graph)
        self.loader = loader
        let clock = TestClock()
        self.clock = clock
        if withDB {
            let db = RelationshipDatabase(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("hypersession-\(UUID().uuidString).db"))
            try db.open()
            self.db = db
        } else {
            db = nil
        }
        session = HyperSession(navigator: navigator, loader: loader, feedback: db,
                               sampleRate: sampleRate, now: { clock.t })
    }

    func phrase(_ id: String) -> PhraseNode { navigator.phrase(id: id)! }

    /// Renders `seconds` of audio in `block`-frame calls, advancing the clock and ticking after each.
    func run(seconds: Double, block: Int = 4096) {
        let total = Int(seconds * session.core.sampleRate)
        var done = 0
        while done < total {
            let n = min(block, total - done)
            render(session.core, frames: n)
            done += n
            clock.t += Double(n) / session.core.sampleRate
            session.tick()
        }
    }
}

private let a0 = "a1b2c3d4e5f60001"
private let a1 = "a1b2c3d4e5f60002"
private let b0 = "b7e8f9a0b1c20001"
private let b1 = "b7e8f9a0b1c20002"

/// Polls (yielding to other tasks) until `condition` holds.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())
}

/// Phrase nodes with no beat data, for the quantize fallbacks.
private func node(_ id: String, track: String, index: Int, start: Double, end: Double?) -> PhraseNode {
    PhraseNode(id: id, sourceTrack: track, sourceTrackName: URL(fileURLWithPath: track).lastPathComponent,
               trackIndex: index, audioFile: "", tempo: 120, key: nil, energy: 0.5, spectralCentroid: 1000,
               segmentType: "verse", duration: (end ?? start + 10) - start, startTime: start, endTime: end,
               beats: [], downbeats: [], waveform: nil, links: [])
}

// MARK: - Tests

@MainActor
@Suite struct HyperSessionTests {

    @Test func currentPhraseFollowsPositionWithoutSkipping() async throws {
        let rig = try Rig()
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        var seen: [Int] = []
        // Track A's phrases end at 75 s; the silent fake track is 80 s long.
        let total = Int(76 * sr)
        var done = 0
        while done < total {
            render(rig.session.core, frames: 512)
            done += 512
            rig.clock.t += 512 / sr
            rig.session.tick()
            if let idx = rig.session.decks[.a]!.currentPhrase?.trackIndex, seen.last != idx { seen.append(idx) }
        }
        #expect(seen == [0, 1, 2])
    }

    @Test func latestLoadWins() async throws {
        let loader = FakeLoader(autoComplete: false)
        let rig = try Rig(loader: loader)
        let x = rig.phrase(a0), y = rig.phrase(b0)
        let first = Task { await rig.session.start(phrase: x, on: .b) }
        await waitUntil { loader.pendingCount == 1 }
        let second = Task { await rig.session.start(phrase: y, on: .b) }
        await waitUntil { loader.pendingCount == 2 }
        loader.complete(URL(fileURLWithPath: trackB))
        await second.value
        loader.complete(URL(fileURLWithPath: trackA))
        await first.value
        render(rig.session.core, frames: 512)
        rig.session.tick()
        let deck = rig.session.decks[.b]!
        #expect(deck.track == URL(fileURLWithPath: trackB))
        #expect(deck.currentPhrase?.id == b0)
        #expect(deck.loadState == .ready)
        // The engine got Y: only one track remains alive besides released ones, and it is Y.
        rig.session.tick()
        #expect(loader.liveTracks.map(\.url) == [URL(fileURLWithPath: trackB)])
    }

    @Test func loadBranchTargetsNonCentreDeckAtPhraseStartWithPFL() async throws {
        let rig = try Rig()
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 0.5)
        #expect(rig.session.centre == .a)
        let branch = try #require(rig.session.branches.first { $0.to.id == b1 })
        #expect(rig.session.branches.count <= 8)
        await rig.session.loadBranch(branch)
        rig.run(seconds: 0.1)
        let deck = rig.session.decks[.b]!
        #expect(deck.track == URL(fileURLWithPath: trackB))
        #expect(deck.isPlaying == false)
        #expect(deck.pfl)
        #expect(deck.loadState == .ready)
        #expect(deck.currentPhrase?.id == b1)
        #expect(rig.session.core.snapshot.b.position == Double(branch.to.startFrame(sampleRate: sr)))
        #expect(abs(deck.positionSeconds - branch.to.startTime!) < 0.001)
        #expect(rig.session.incoming?.deck == .b)
        #expect(rig.session.incoming?.branch.id == branch.id)
        #expect(rig.session.message == nil)
    }

    @Test func loadBranchRefusedWhenTargetDeckIsAudible() async throws {
        let rig = try Rig()
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 0.1)
        #expect(rig.session.centre == .a)
        await rig.session.start(phrase: rig.phrase(b0), on: .b)   // B plays, crossfader centred
        rig.run(seconds: 0.1)
        #expect(rig.session.centre == .a)
        let callsBefore = rig.loader.calls.count
        let branch = try #require(rig.session.branches.first)
        await rig.session.loadBranch(branch)
        #expect(rig.session.message != nil)
        #expect(rig.session.incoming == nil)
        #expect(rig.loader.calls.count == callsBefore)
        rig.run(seconds: 0.1)
        #expect(rig.session.decks[.b]!.isPlaying)
        #expect(rig.session.decks[.b]!.currentPhrase?.id == b0)

        // Pulling B's fader down makes the load allowed again.
        rig.session.setFader(.b, 0)
        await rig.session.loadBranch(branch)
        #expect(rig.session.incoming?.deck == .b)
    }

    @Test func quantizedStartLandsOnNextDownbeat() async throws {
        let rig = try Rig()
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 1.0, block: 512)            // 87 blocks = 44544 frames ≈ 1.010 s
        let branch = try #require(rig.session.branches.first)
        await rig.session.loadBranch(branch)
        rig.session.quantizedStart(.b)
        render(rig.session.core, frames: 64)
        // A started at engine time 0 from song time 0: the next downbeat (1.875 s) is at frame 82687.5.
        let expected = Int64((1.875 * sr).rounded())
        let scheduled = rig.session.core.snapshot.b.scheduledStart
        #expect(abs(scheduled - expected) <= 1)
        #expect(rig.session.core.snapshot.b.isPlaying)

        // .nextPhraseBoundary targets the phrase end (30 s).
        let rig2 = try Rig()
        await rig2.session.start(phrase: rig2.phrase(a0), on: .a)
        rig2.run(seconds: 1.0, block: 512)
        await rig2.session.loadBranch(try #require(rig2.session.branches.first))
        rig2.session.quantizedStart(.b, target: .nextPhraseBoundary)
        render(rig2.session.core, frames: 64)
        #expect(abs(rig2.session.core.snapshot.b.scheduledStart - Int64(30 * sr)) <= 1)
    }

    @Test func quantizedStartWithoutDownbeatsFallsBack() async throws {
        let x0 = node("x0", track: "/t/X.wav", index: 0, start: 0, end: 10)
        let x1 = node("x1", track: "/t/X.wav", index: 1, start: 10, end: nil)
        let y0 = node("y0", track: "/t/Y.wav", index: 0, start: 0, end: 10)
        let graph = PhraseGraph(version: "2.0", createdAt: Date(), collectionPath: "/t", nodes: [x0, x1, y0])

        // No downbeats → next phrase boundary.
        let rig = try Rig(graph: graph)
        await rig.session.start(phrase: x0, on: .a)
        rig.run(seconds: 1.0)
        #expect(rig.session.centre == .a)
        await rig.session.start(phrase: y0, on: .b)
        rig.session.pause(.b)
        rig.session.quantizedStart(.b)
        render(rig.session.core, frames: 64)
        #expect(abs(rig.session.core.snapshot.b.scheduledStart - Int64(10 * sr)) <= 1)

        // No phrase end either → immediate start.
        let rig2 = try Rig(graph: graph)
        await rig2.session.start(phrase: x1, on: .a)
        rig2.run(seconds: 0.5)
        await rig2.session.start(phrase: y0, on: .b)
        rig2.session.pause(.b)
        rig2.session.quantizedStart(.b)
        render(rig2.session.core, frames: 64)
        #expect(rig2.session.core.snapshot.b.scheduledStart == -1)
        #expect(rig2.session.core.snapshot.b.isPlaying)
        #expect(rig2.session.core.snapshot.b.position == 64)

        // No centre playing → immediate start.
        let rig3 = try Rig(graph: graph)
        await rig3.session.start(phrase: y0, on: .b)
        rig3.session.pause(.b)
        rig3.session.quantizedStart(.b)
        render(rig3.session.core, frames: 64)
        #expect(rig3.session.core.snapshot.b.scheduledStart == -1)
        #expect(rig3.session.core.snapshot.b.isPlaying)
    }

    @Test func handoverLogsBranchedFromPhraseEvenAfterCentreAdvanced() async throws {
        let rig = try Rig(withDB: true)
        let db = try #require(rig.db)
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 29)
        let branch = try #require(rig.session.branches.first)
        #expect(branch.from.id == a0)
        await rig.session.loadBranch(branch)
        rig.run(seconds: 2)                          // A advances into A1
        #expect(rig.session.decks[.a]!.currentPhrase?.id == a1)
        rig.session.play(.b)
        rig.session.crossfader = 1                   // full B
        rig.run(seconds: 0.5)
        #expect(rig.session.centre == .a)            // still within the dwell
        #expect(rig.session.lastTransition == nil)
        rig.run(seconds: 1.0)
        #expect(rig.session.centre == .b)
        #expect(rig.session.incoming == nil)
        #expect(rig.session.lastTransition?.id == branch.id)
        let fb = try db.getFeedback(from: a0, to: branch.to.id)
        #expect(fb.performanceCount == 1)
        #expect(try db.getFeedback(from: a1, to: branch.to.id).totalCount == 0)

        // Handing back to A (not loaded from a branch) logs nothing more.
        rig.session.crossfader = 0
        rig.run(seconds: 1.5)
        #expect(rig.session.centre == .a)
        #expect(try db.getFeedback(from: a0, to: branch.to.id).performanceCount == 1)
    }

    @Test func abandonedLoadIsNotLogged() async throws {
        let rig = try Rig(withDB: true)
        let db = try #require(rig.db)
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 0.5)
        let branch = try #require(rig.session.branches.first)
        await rig.session.loadBranch(branch)
        #expect(rig.session.incoming != nil)
        // Reloading the incoming deck abandons the branch without logging.
        await rig.session.start(phrase: rig.phrase(b1), on: .b)
        #expect(rig.session.incoming == nil)
        rig.session.crossfader = 1
        rig.run(seconds: 1.5)
        #expect(rig.session.centre == .b)
        #expect(rig.session.lastTransition == nil)
        #expect(try db.getFeedback(from: a0, to: branch.to.id).totalCount == 0)
        #expect(try db.getFeedback(from: a0, to: b1).totalCount == 0)
    }

    @Test func rateLastTransitionWritesRating() async throws {
        let rig = try Rig(withDB: true)
        let db = try #require(rig.db)
        rig.session.rateLastTransition(1)
        #expect(rig.session.message != nil)          // nothing to rate yet

        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 0.5)
        let branch = try #require(rig.session.branches.first)
        await rig.session.loadBranch(branch)
        rig.session.play(.b)
        rig.session.crossfader = 1
        rig.run(seconds: 1.5)
        #expect(rig.session.lastTransition?.id == branch.id)
        rig.session.rateLastTransition(1)
        let fb = try db.getFeedback(from: a0, to: branch.to.id)
        #expect(fb.averageRating > 0)
        #expect(fb.totalCount == 2)                  // played + rated
    }

    @Test func failedLoadSetsDeckErrorAndSendsNoCommand() async throws {
        let loader = FakeLoader(failing: [URL(fileURLWithPath: trackB)])
        let rig = try Rig(loader: loader)
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        rig.run(seconds: 0.5)
        let posBefore = rig.session.core.snapshot.a.position
        let branch = try #require(rig.session.branches.first)
        await rig.session.loadBranch(branch)
        guard case .failed(let reason) = rig.session.decks[.b]!.loadState else {
            Issue.record("expected failed load state"); return
        }
        #expect(!reason.isEmpty)
        #expect(rig.session.message != nil)
        #expect(rig.session.incoming == nil)
        rig.run(seconds: 0.1)
        let snap = rig.session.core.snapshot
        #expect(snap.b.trackToken == 0)
        #expect(snap.b.isPlaying == false)
        #expect(snap.a.isPlaying)                    // the other deck keeps playing
        #expect(snap.a.position > posBefore)
        #expect(rig.session.decks[.b]!.track == nil)
    }

    @Test func sampleRateChangeRedecodesAndKeepsPositionSeconds() async throws {
        let rig = try Rig()
        let session = rig.session
        await session.start(phrase: rig.phrase(a1), on: .a)   // starts at 30 s
        session.setEQ(.a, .low, dB: -20)
        session.crossfader = 0.3
        rig.run(seconds: 2.3)
        let before = session.decks[.a]!.positionSeconds
        #expect(abs(before - 32.3) < 0.01)
        let oldCore = session.core
        await session.engineSampleRateChanged(to: 48000)
        #expect(session.core !== oldCore)
        #expect(session.core.sampleRate == 48000)
        #expect(rig.loader.calls.last == FakeLoader.Call(url: URL(fileURLWithPath: trackA), sampleRate: 48000))
        #expect(abs(session.decks[.a]!.positionSeconds - before) < 0.001)
        render(session.core, frames: 48)               // 1 ms at the new rate
        session.tick()
        let deck = session.decks[.a]!
        #expect(deck.isPlaying)
        #expect(abs(deck.positionSeconds - before) < 0.002)
        #expect(deck.currentPhrase?.id == a1)
        #expect(deck.eq.low == -20)
        #expect(session.crossfader == 0.3)
    }

    @Test func deckTrackIsPinnedInCacheUntilReplaced() async throws {
        let inner = FakeLoader(seconds: 1)
        let cache = TrackCache(loader: inner, budgetBytes: 1)    // evicts everything unpinned
        let graph = try PhraseGraph.load(from: fixture("graph_v2.json"))
        let navigator = GraphNavigator(graph: graph)
        let session = HyperSession(navigator: navigator, loader: cache, feedback: nil,
                                   sampleRate: sr, now: { 0 })
        let urlA = URL(fileURLWithPath: trackA), urlB = URL(fileURLWithPath: trackB)
        let other = URL(fileURLWithPath: "/fixtures/other.wav")
        func count(_ url: URL) -> Int { inner.calls.filter { $0.url == url }.count }

        await session.start(phrase: navigator.phrase(id: a0)!, on: .a)
        _ = try await cache.track(for: other, sampleRate: sr)     // forces an eviction pass
        _ = try await cache.track(for: urlA, sampleRate: sr)
        #expect(count(urlA) == 1)                                 // still cached: pinned

        await session.start(phrase: navigator.phrase(id: b0)!, on: .a)   // replaces A's track
        // Unpinning is asynchronous; once it lands, A is evictable and decodes again.
        var reDecoded = false
        for _ in 0..<500 {
            _ = try await cache.track(for: other, sampleRate: sr)
            _ = try await cache.track(for: urlA, sampleRate: sr)
            if count(urlA) > 1 { reDecoded = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(reDecoded)
        _ = try await cache.track(for: other, sampleRate: sr)
        _ = try await cache.track(for: urlB, sampleRate: sr)
        #expect(count(urlB) == 1)                                 // B is now the pinned one
    }

    @Test func releasedTracksAreDrainedOnTick() async throws {
        let rig = try Rig()
        await rig.session.start(phrase: rig.phrase(a0), on: .a)
        render(rig.session.core, frames: 512)
        rig.session.tick()
        #expect(rig.loader.liveTracks.count == 1)
        await rig.session.start(phrase: rig.phrase(b0), on: .a)
        render(rig.session.core, frames: 512)          // the core retires track A
        #expect(rig.loader.liveTracks.count == 2)
        rig.session.tick()
        #expect(rig.loader.liveTracks.map(\.url) == [URL(fileURLWithPath: trackB)])
    }

    @Test func reportAndClearMessage() throws {
        let rig = try Rig()
        #expect(rig.session.message == nil)
        rig.session.report("Output fell back to stereo.")
        #expect(rig.session.message == "Output fell back to stereo.")
        rig.session.clearMessage()
        #expect(rig.session.message == nil)
    }
}
