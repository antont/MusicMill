import Foundation

/// How audible a deck is by control state: 0 when not playing, otherwise
/// `trim · fader · crossfader · eqOpenness`. EQ openness is a weighted mean of the three band
/// gains (each clamped to 0…1), so killing the low band drops the level by 50 %.
public func effectiveLevel(isPlaying: Bool, trim: Float, fader: Float, crossfaderGain: Float,
                           eqLinear: (Float, Float, Float)) -> Double {
    guard isPlaying else { return 0 }
    func clamp(_ x: Float) -> Double { Double(min(1, max(0, x))) }
    let openness = min(1, 0.5 * clamp(eqLinear.0) + 0.3 * clamp(eqLinear.1) + 0.2 * clamp(eqLinear.2))
    return Double(trim) * Double(fader) * Double(crossfaderGain) * openness
}

public struct Handover: Equatable, Sendable {
    public let from: DeckID?
    public let to: DeckID
    public init(from: DeckID?, to: DeckID) { self.from = from; self.to = to }
}

/// Picks the "centre" deck (what the UI treats as playing now) with hysteresis and a dwell time.
/// Main-actor display/logging rule only; the audio thread never consults it. Pure value type.
///
/// `centre` is nil until a deck first reaches `minLevel`; once set it never becomes nil again
/// (if everything goes quiet, the last centre stays).
public struct CentreTracker {
    public let margin: Double
    public let minLevel: Double
    public let dwell: TimeInterval
    public private(set) var centre: DeckID?
    /// First `now` at which the current takeover condition began to hold.
    private var challengeStart: TimeInterval?

    public init(margin: Double = 1.25, minLevel: Double = 0.2, dwell: TimeInterval = 1.0) {
        self.margin = margin
        self.minLevel = minLevel
        self.dwell = dwell
    }

    /// Returns a `Handover` only when the centre changes (including the first assignment).
    public mutating func update(levels: [DeckID: Double], now: TimeInterval) -> Handover? {
        guard let current = centre else {
            for deck in DeckID.allCases where (levels[deck] ?? 0) >= minLevel {
                centre = deck
                challengeStart = nil
                return Handover(from: nil, to: deck)
            }
            return nil
        }
        guard let other = DeckID.allCases.first(where: { $0 != current }) else { return nil }
        let centreLevel = levels[current] ?? 0
        let otherLevel = levels[other] ?? 0
        guard otherLevel >= max(minLevel, centreLevel * margin) else {
            challengeStart = nil
            return nil
        }
        let start = challengeStart ?? now
        challengeStart = start
        guard now - start >= dwell else { return nil }
        centre = other
        challengeStart = nil
        return Handover(from: current, to: other)
    }
}
