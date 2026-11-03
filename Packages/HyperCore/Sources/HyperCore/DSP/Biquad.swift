import Foundation

/// Stereo biquad, transposed direct form II, in Double. Coefficients from the RBJ
/// Audio EQ Cookbook (bilinear transform with frequency prewarping), normalised so a0 = 1.
/// Per-channel state lives in fixed tuples, so the struct is copyable and allocation-free.
struct Biquad {
    enum Kind { case lowPass, highPass, allPass }

    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var stateL: (Double, Double) = (0, 0)
    private var stateR: (Double, Double) = (0, 0)

    /// Butterworth Q (1/√2): two cascaded sections form a Linkwitz-Riley 4th-order filter,
    /// and the all-pass equals the summed response of that LR4 pair.
    static let butterworthQ = 1.0 / 2.0.squareRoot()

    init(_ kind: Kind, frequency: Double, sampleRate: Double, q: Double = Biquad.butterworthQ) {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let (n0, n1, n2): (Double, Double, Double)
        switch kind {
        case .lowPass:  (n0, n1, n2) = ((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2)
        case .highPass: (n0, n1, n2) = ((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2)
        case .allPass:  (n0, n1, n2) = (1 - alpha, -2 * cosW, 1 + alpha)
        }
        b0 = n0 / a0; b1 = n1 / a0; b2 = n2 / a0
        a1 = -2 * cosW / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always)
    mutating func process(l: Double, r: Double) -> (Double, Double) {
        let yl = b0 * l + stateL.0
        stateL = (b1 * l - a1 * yl + stateL.1, b2 * l - a2 * yl)
        let yr = b0 * r + stateR.0
        stateR = (b1 * r - a1 * yr + stateR.1, b2 * r - a2 * yr)
        return (yl, yr)
    }
}
