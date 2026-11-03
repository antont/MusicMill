import Foundation

/// Stateless output-safety soft clipper for the master and cue buses.
///
/// - Bit-transparent at or below −1 dBFS (`threshold`).
/// - Above it, a tanh knee: `y = T + (C − T)·tanh((|x| − T)/(C − T))`, which meets the
///   identity with slope 1 at the threshold and approaches the ceiling asymptotically.
/// - Hard ceiling `C = 0.999`; ±∞ maps to ±ceiling and NaN to 0.
///
/// Value type, allocation-free; safe on the render thread.
public struct SoftLimiter: Sendable {
    /// −1 dBFS as a linear amplitude.
    public let threshold: Float = 0.891_250_9
    public let ceiling: Float = 0.999

    public init() {}

    @inline(__always)
    public func process(_ x: Float) -> Float {
        let a = abs(x)
        if a <= threshold { return x }
        if x.isNaN { return 0 }
        let range = ceiling - threshold
        let y = min(threshold + range * tanhf((a - threshold) / range), ceiling)
        return x < 0 ? -y : y
    }

    /// In place over `frames` samples.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { buffer[i] = process(buffer[i]) }
    }
}
