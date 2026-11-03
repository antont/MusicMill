import Foundation

/// The real-time engine: two `DeckPlayer`s into a `Mixer`, driven by lock-free commands and
/// publishing a lock-free snapshot.
///
/// Threads:
/// - **Main thread:** `send`, `snapshot`, `drainReleasedTracks`, `init`/`deinit`.
/// - **Render thread** (the CoreAudio I/O callback): `render` only.
///
/// Track ownership: the main thread passes `Unmanaged.passRetained(track)` in `.load`. Once
/// `send` accepts the command, AudioCore owns that +1. The render thread never calls
/// `release()`: a track it replaces goes onto an internal release queue, and the main thread
/// releases it in `drainReleasedTracks()` (or `deinit`).
///
/// Render-thread state (decks, mixer, sample time, pending releases) lives in raw
/// allocations made in `init`, so `render` performs no allocation, locking or ARC traffic.
public final class AudioCore: @unchecked Sendable {
    public let sampleRate: Double
    /// Largest block processed at once; longer `render` calls are processed in chunks.
    public let maxFrames: Int

    static let commandCapacity = 256
    static let releaseCapacity = 64
    /// Replaced tracks that did not fit in the release queue wait here for the next block.
    static let pendingCapacity = 16

    private let commands = SPSCQueue<CoreCommand>(capacity: AudioCore.commandCapacity)
    private let released = SPSCQueue<Unmanaged<AudioTrack>>(capacity: AudioCore.releaseCapacity)
    private let snapshotBox = SnapshotBox(CoreSnapshot())

    // Render-thread state.
    private let decks: UnsafeMutablePointer<DeckPlayer>          // [a, b]
    private let mixer: UnsafeMutablePointer<Mixer>
    private let sampleTime: UnsafeMutablePointer<Int64>
    private let pending: UnsafeMutablePointer<Unmanaged<AudioTrack>>
    private let pendingCount: UnsafeMutablePointer<Int>
    /// Four `maxFrames` scratch channels: deck A L/R, deck B L/R.
    private let scratch: UnsafeMutablePointer<Float>

    public init(sampleRate: Double, maxFrames: Int = 4096) {
        precondition(maxFrames > 0, "maxFrames must be positive")
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        decks = .allocate(capacity: 2)
        decks.initialize(repeating: DeckPlayer(), count: 2)
        mixer = .allocate(capacity: 1)
        mixer.initialize(to: Mixer(sampleRate: sampleRate))
        sampleTime = .allocate(capacity: 1)
        sampleTime.initialize(to: 0)
        pending = .allocate(capacity: AudioCore.pendingCapacity)
        pendingCount = .allocate(capacity: 1)
        pendingCount.initialize(to: 0)
        scratch = .allocate(capacity: 4 * maxFrames)
        scratch.initialize(repeating: 0, count: 4 * maxFrames)
    }

    /// Main thread, after the render thread has stopped calling `render`. Releases every
    /// track AudioCore still owns: loaded on a deck, waiting in the release queue or the
    /// pending list, or carried by a `.load` that was sent but never rendered.
    deinit {
        for i in 0..<2 { decks[i].track?.release() }
        while let t = released.pop() { t.release() }
        for i in 0..<pendingCount.pointee { pending[i].release() }
        while let c = commands.pop() {
            if case .load(_, let t?, _) = c { t.release() }
        }
        decks.deinitialize(count: 2)
        decks.deallocate()
        mixer.deinitialize(count: 1)
        mixer.deallocate()
        sampleTime.deallocate()
        pending.deallocate()
        pendingCount.deallocate()
        scratch.deallocate()
    }

    // MARK: Main thread

    /// Queues a command for the next render block. Single producer: call from one thread
    /// (the main thread) only.
    ///
    /// Returns false when the command queue is full; the command is then dropped and, for a
    /// `.load`, ownership of the retained track stays with the caller, who must release it.
    public func send(_ c: CoreCommand) -> Bool {
        commands.push(c)
    }

    /// The state published by the last render call. Any thread; never torn.
    public var snapshot: CoreSnapshot { snapshotBox.read() }

    /// Releases the tracks the render thread has replaced. Main thread only (single consumer).
    public func drainReleasedTracks() {
        while let t = released.pop() { t.release() }
    }

    // MARK: Render thread

    /// Applies queued commands, renders both decks, mixes them into `out`, advances the
    /// engine sample time by `frames` and publishes a snapshot. Render thread only.
    ///
    /// Blocks longer than `maxFrames` are processed in `maxFrames` chunks; commands are
    /// applied once, before the first chunk.
    public func render(frames: Int, out: FourChannelOut) {
        flushPendingReleases()
        drainCommands()

        let aL = scratch, aR = scratch + maxFrames
        let bL = scratch + 2 * maxFrames, bR = scratch + 3 * maxFrames
        var peakA: Float = 0, peakB: Float = 0
        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            let blockStart = sampleTime.pointee
            decks[0].render(left: aL, right: aR, frames: n, blockStart: blockStart)
            decks[1].render(left: bL, right: bR, frames: n, blockStart: blockStart)
            mixer.pointee.mix(deckA: (aL, aR), deckB: (bL, bR),
                              out: FourChannelOut(masterL: out.masterL + done, masterR: out.masterR + done,
                                                  cueL: out.cueL + done, cueR: out.cueR + done),
                              frames: n)
            // After `mix`, the deck buffers hold the post-trim/EQ, pre-fader signal.
            peakA = max(peakA, Self.absPeak(aL, aR, n))
            peakB = max(peakB, Self.absPeak(bL, bR, n))
            sampleTime.pointee += Int64(n)
            done += n
        }

        let faderA = mixer.pointee.strips.0.controlGains().fader
        let faderB = mixer.pointee.strips.1.controlGains().fader
        snapshotBox.write(CoreSnapshot(sampleTime: sampleTime.pointee,
                                       a: Self.deckSnapshot(decks[0], peak: peakA * faderA),
                                       b: Self.deckSnapshot(decks[1], peak: peakB * faderB)))
    }

    /// Pops commands until the queue is empty. Stops early (leaving the rest queued for the
    /// next block) when the pending-release list is full, so a replaced track is never
    /// dropped or released here even if the main thread has stopped draining.
    private func drainCommands() {
        while pendingCount.pointee < AudioCore.pendingCapacity, let c = commands.pop() {
            apply(c)
        }
    }

    private func apply(_ c: CoreCommand) {
        switch c {
        case let .load(d, track, startFrame):
            let deck = decks + d.rawValue
            let old = deck.pointee.track
            deck.pointee.track = track
            deck.pointee.seek(toFrame: startFrame)
            deck.pointee.pause()
            if let old { retire(old) }
        case let .play(d, at): decks[d.rawValue].play(at: at)
        case let .pause(d): decks[d.rawValue].pause()
        case let .seek(d, frame): decks[d.rawValue].seek(toFrame: frame)
        case let .nudge(d, frames): decks[d.rawValue].nudge(frames: frames)
        case let .bend(d, ratio): decks[d.rawValue].bend = ratio
        case let .loop(d, range): decks[d.rawValue].loop = range
        case let .eq(d, band, db):
            withStrip(d) { strip in
                switch band {
                case .low: strip.eq.lowDB = db
                case .mid: strip.eq.midDB = db
                case .high: strip.eq.highDB = db
                }
            }
        case let .trim(d, db): withStrip(d) { $0.trimDB = db }
        case let .fader(d, v): withStrip(d) { $0.fader = v }
        case let .crossfader(x): mixer.pointee.crossfader = x
        case let .curve(curve): mixer.pointee.curve = curve
        case let .pfl(d, on):
            switch d {
            case .a: mixer.pointee.pfl.0 = on
            case .b: mixer.pointee.pfl.1 = on
            }
        case let .cueMix(v): mixer.pointee.cueMix = v
        case let .master(db): mixer.pointee.masterDB = db
        case let .cueLevel(db): mixer.pointee.cueDB = db
        }
    }

    @inline(__always)
    private func withStrip(_ d: DeckID, _ body: (inout ChannelStrip) -> Void) {
        switch d {
        case .a: body(&mixer.pointee.strips.0)
        case .b: body(&mixer.pointee.strips.1)
        }
    }

    /// Hands a replaced track to the main thread: straight onto the release queue, or into the
    /// pending list when the queue is full (or older tracks are already waiting).
    private func retire(_ t: Unmanaged<AudioTrack>) {
        if pendingCount.pointee == 0 && released.push(t) { return }
        // drainCommands guarantees room: it stops before the list is full.
        pending[pendingCount.pointee] = t
        pendingCount.pointee += 1
    }

    /// Moves pending tracks onto the release queue while it has room.
    private func flushPendingReleases() {
        var n = pendingCount.pointee
        var moved = 0
        while moved < n, released.push(pending[moved]) { moved += 1 }
        if moved > 0 {
            n -= moved
            for i in 0..<n { pending[i] = pending[i + moved] }
            pendingCount.pointee = n
        }
    }

    private static func absPeak(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                                _ n: Int) -> Float {
        var p: Float = 0
        for i in 0..<n { p = max(p, abs(l[i]), abs(r[i])) }
        return p
    }

    private static func deckSnapshot(_ d: DeckPlayer, peak: Float) -> DeckSnapshot {
        DeckSnapshot(position: d.position,
                     isPlaying: d.isPlaying,
                     scheduledStart: d.scheduledStart ?? -1,
                     trackToken: d.track.map { UInt64(UInt(bitPattern: $0.toOpaque())) } ?? 0,
                     peak: peak)
    }
}
