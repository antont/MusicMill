import Foundation

/// The two decks. Shadows the legacy app's `DeckID` inside HyperCore only; app files that
/// import both refer to this one as `HyperCore.DeckID`.
public enum DeckID: Int, CaseIterable, Sendable {
    case a = 0, b = 1
}

public enum EQBand: UInt8, Sendable {
    case low, mid, high
}

/// A control message from the main thread to the render thread, sent with `AudioCore.send`
/// and applied at the start of the next render block.
///
/// Every case is a trivial value (no ARC), so pushing and popping commands never retains
/// or releases anything on the render thread.
public enum CoreCommand: Sendable {
    /// Loads `track` (or empties the deck with `nil`), seeks to `startFrame` and pauses.
    /// The sender must pass `Unmanaged.passRetained(track)`; AudioCore owns that +1 from then
    /// on and releases it on the main thread (`drainReleasedTracks` or `deinit`).
    case load(DeckID, Unmanaged<AudioTrack>?, startFrame: Int)
    /// `nil` starts immediately; otherwise at that engine sample time (see `CoreSnapshot.sampleTime`).
    case play(DeckID, at: Int64?)
    case pause(DeckID)
    case seek(DeckID, frame: Int)
    case nudge(DeckID, frames: Int)
    /// Varispeed ratio (clamped by `DeckPlayer` to 0.9 … 1.1).
    case bend(DeckID, Double)
    case loop(DeckID, Range<Int>?)
    /// Band gain in dB.
    case eq(DeckID, EQBand, Float)
    /// Trim in dB.
    case trim(DeckID, Float)
    /// Fader position 0 … 1 (audio taper `fader²`).
    case fader(DeckID, Float)
    /// 0 = full A, 1 = full B.
    case crossfader(Float)
    case curve(CrossfaderCurve)
    case pfl(DeckID, Bool)
    /// Cue bus blend: 0 = PFL only, 1 = master only.
    case cueMix(Float)
    /// Master level in dB.
    case master(Float)
    /// Cue level in dB.
    case cueLevel(Float)
}
