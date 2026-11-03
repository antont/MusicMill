import Foundation

/// One deck's state as of the end of the last render call.
public struct DeckSnapshot: BitwiseCopyable, Sendable {
    /// Song-absolute frames at the engine sample rate.
    public var position: Double
    public var isPlaying: Bool
    /// Engine sample time of a pending scheduled start, or −1 if none.
    public var scheduledStart: Int64
    /// The loaded track's `ObjectIdentifier` bit pattern, 0 when the deck is empty.
    public var trackToken: UInt64
    /// Absolute peak, over the last render call, of this deck's post-fader signal:
    /// post-trim/EQ samples × the fader gain (`fader²`, the fader's target value), taken
    /// over both channels and before the crossfader. It is the deck's channel meter, so it
    /// moves with trim, EQ and fader but not with the crossfader or master level.
    public var peak: Float

    public init(position: Double = 0, isPlaying: Bool = false, scheduledStart: Int64 = -1,
                trackToken: UInt64 = 0, peak: Float = 0) {
        self.position = position
        self.isPlaying = isPlaying
        self.scheduledStart = scheduledStart
        self.trackToken = trackToken
        self.peak = peak
    }
}

/// Engine state published by the render thread after every render call.
public struct CoreSnapshot: BitwiseCopyable, Sendable {
    /// Engine sample time: total frames rendered so far (the start of the next block).
    public var sampleTime: Int64
    public var a: DeckSnapshot
    public var b: DeckSnapshot

    public init(sampleTime: Int64 = 0, a: DeckSnapshot = DeckSnapshot(), b: DeckSnapshot = DeckSnapshot()) {
        self.sampleTime = sampleTime
        self.a = a
        self.b = b
    }

    public subscript(deck: DeckID) -> DeckSnapshot {
        deck == .a ? a : b
    }
}
