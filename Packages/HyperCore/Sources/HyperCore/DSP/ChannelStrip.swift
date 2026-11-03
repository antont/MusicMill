import Foundation

/// One mixer channel: trim → isolator EQ → fader, processed in place on the render thread.
/// The fader is applied after the EQ so a fader move scales the output directly
/// (it is not reshaped by the crossover filters).
///
/// Smoothing: trim and fader are smoothed as *linear gains* with 10 ms linear ramps.
/// The fader's audio taper is applied before smoothing — the smoothed quantity is
/// `fader²`, not `fader` — so the per-sample gain change is bounded by
/// `|Δ(fader²)| / rampSamples` (smoothing `fader` and squaring would double the
/// slope near full scale).
public struct ChannelStrip {
    public var eq: IsolatorEQ

    /// Trim in dB, clamped to −12 … +12; non-finite values are treated as 0 dB.
    public var trimDB: Float = 0 {
        didSet { trimGain.target = trimDB.isFinite ? powf(10, min(max(trimDB, -12), 12) / 20) : 1 }
    }

    /// Fader position 0 … 1 (clamped; NaN is treated as 0); gain is the audio taper `fader²`.
    public var fader: Float = 1 {
        didSet { let f = fader.isNaN ? 0 : min(max(fader, 0), 1); faderGain.target = f * f }
    }

    private var trimGain: SmoothedValue
    private var faderGain: SmoothedValue

    public init(sampleRate: Double) {
        eq = IsolatorEQ(sampleRate: sampleRate)
        trimGain = SmoothedValue(1, sampleRate: sampleRate)
        faderGain = SmoothedValue(1, sampleRate: sampleRate)
    }

    public mutating func process(left: UnsafeMutablePointer<Float>,
                                 right: UnsafeMutablePointer<Float>,
                                 frames: Int) {
        for i in 0..<frames {
            let trim = trimGain.next()
            var l = left[i] * trim
            var r = right[i] * trim
            eq.process(l: &l, r: &r)
            let f = faderGain.next()
            left[i] = l * f
            right[i] = r * f
        }
    }

    /// The *target* gains (not the current smoothed values), for the main-thread centre rule:
    /// - `trim`: linear trim gain, `10^(trimDB/20)` with trimDB clamped to ±12
    /// - `fader`: linear fader gain with the taper applied, `fader²`
    /// - `eqLinear`: linear (low, mid, high) band gains; a kill (≤ −60 dB) is 0
    public func controlGains() -> (trim: Float, fader: Float, eqLinear: (Float, Float, Float)) {
        (trimGain.target, faderGain.target, eq.linearGains)
    }
}
