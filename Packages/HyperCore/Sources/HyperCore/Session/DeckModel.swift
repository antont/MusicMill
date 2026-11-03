import Foundation
import Observation

/// Where a deck's next sync start lands relative to the centre deck.
public enum QuantizeTarget: Sendable {
    case nextDownbeat, nextPhraseBoundary
}

/// One deck as the UI sees it. Owned and mutated by `HyperSession`: playback state comes from
/// polled engine snapshots, control state mirrors what the session last sent to the engine.
@MainActor @Observable
public final class DeckModel {
    public enum LoadState: Equatable, Sendable {
        case empty, loading, ready
        case failed(String)
    }

    public let id: DeckID

    /// The song loaded in the engine, nil when empty.
    public internal(set) var track: URL?
    /// The phrase containing `positionSeconds`, from the graph.
    public internal(set) var currentPhrase: PhraseNode?
    /// Song-absolute seconds.
    public internal(set) var positionSeconds: Double = 0
    /// True while playing or waiting for a scheduled start.
    public internal(set) var isPlaying = false
    public internal(set) var loadState: LoadState = .empty

    public internal(set) var loopEnabled = false
    public internal(set) var pfl = false
    /// Band gains in dB.
    public internal(set) var eq: (low: Float, mid: Float, high: Float) = (0, 0, 0)
    public internal(set) var trimDB: Float = 0
    /// 0 … 1.
    public internal(set) var fader: Float = 1

    // Session bookkeeping, not observed.

    /// The graph's `sourceTrack` string for `track` (the key for phrase lookups).
    @ObservationIgnored var trackPath: String?
    /// Latest-wins load counter; a completion whose generation is not current is discarded.
    @ObservationIgnored var loadGeneration: UInt64 = 0
    /// Engine sample time when the last state-changing command for this deck was sent.
    /// Snapshot playback state is only trusted once the engine has rendered past it, so a
    /// command not yet applied is not overwritten by stale snapshot values.
    /// `Int64.max` while the deck is being restored on a new core.
    @ObservationIgnored var commandSentAt: Int64 = -1
    /// Varispeed ratio in force (1 when no bend is held).
    @ObservationIgnored var bendRatio: Double = 1
    /// The url this deck holds a cache pin on.
    @ObservationIgnored var pinnedURL: URL?

    public init(id: DeckID) {
        self.id = id
    }
}

public typealias LoadState = DeckModel.LoadState
