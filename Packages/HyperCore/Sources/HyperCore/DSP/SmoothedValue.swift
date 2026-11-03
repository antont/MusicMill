/// A per-sample parameter smoother: a linear ramp from the current value to `target`
/// that completes in `rampSeconds` (rounded to whole samples, at least one).
///
/// Changing `target` mid-ramp starts a fresh ramp from the current value, so the
/// per-sample change never exceeds `|target − current| / rampSamples`.
/// Value type, allocation-free; safe on the render thread.
public struct SmoothedValue {
    public var target: Float
    public private(set) var current: Float
    private let rampSeconds: Float
    private var rampSamples: Int
    private var rampTarget: Float
    private var step: Float = 0
    private var remaining = 0

    public init(_ v: Float, rampSeconds: Float = 0.01, sampleRate: Double) {
        target = v
        current = v
        rampTarget = v
        self.rampSeconds = rampSeconds
        rampSamples = Self.samples(rampSeconds, sampleRate)
    }

    @inline(__always)
    public mutating func next() -> Float {
        if current == target { remaining = 0; rampTarget = target; return current }
        if target != rampTarget || remaining <= 0 {
            rampTarget = target
            remaining = rampSamples
            step = (target - current) / Float(rampSamples)
        }
        remaining -= 1
        current = remaining == 0 ? target : current + step
        return current
    }

    /// Recomputes the ramp length for a new sample rate and snaps to the target.
    public mutating func reset(sampleRate: Double) {
        rampSamples = Self.samples(rampSeconds, sampleRate)
        current = target
        rampTarget = target
        remaining = 0
        step = 0
    }

    private static func samples(_ seconds: Float, _ sampleRate: Double) -> Int {
        max(1, Int((Double(seconds) * sampleRate).rounded()))
    }
}
