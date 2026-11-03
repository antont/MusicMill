import Foundation

/// Three-band DJ isolator built from Linkwitz-Riley 4th-order (LR4) crossovers so the
/// bands sum magnitude-flat at 0 dB:
///
///     in ─┬─ LR4 LP @low ── AP @high ──────────── × low  ─┐
///         └─ LR4 HP @low ─┬─ LR4 LP @high ─────── × mid  ─┼─ out
///                         └─ LR4 HP @high ─────── × high ─┘
///
/// LP+HP of an LR4 pair is the 2nd-order Butterworth-Q all-pass at its crossover, so
/// `low` passing through that all-pass at the high crossover makes the sum
/// AP(low)·AP(high): flat magnitude, phase-only.
///
/// Band gains in dB are in `-∞ ... 6`; anything at or below −60 dB is a kill (linear 0).
/// Gains are smoothed per sample by `SmoothedValue` (10 ms linear ramps on linear gain).
public struct IsolatorEQ {
    /// Gains at or below this are a kill.
    public static let killThresholdDB: Float = -60
    public static let maxDB: Float = 6

    public var lowDB: Float = 0 { didSet { lowGain.target = Self.linear(lowDB) } }
    public var midDB: Float = 0 { didSet { midGain.target = Self.linear(midDB) } }
    public var highDB: Float = 0 { didSet { highGain.target = Self.linear(highDB) } }

    private var lowGain: SmoothedValue
    private var midGain: SmoothedValue
    private var highGain: SmoothedValue

    private var lowLP1, lowLP2, lowAP: Biquad
    private var restHP1, restHP2: Biquad
    private var midLP1, midLP2: Biquad
    private var highHP1, highHP2: Biquad

    public init(sampleRate: Double, lowCrossover: Double = 200, highCrossover: Double = 2500) {
        lowGain = SmoothedValue(1, sampleRate: sampleRate)
        midGain = SmoothedValue(1, sampleRate: sampleRate)
        highGain = SmoothedValue(1, sampleRate: sampleRate)
        lowLP1 = Biquad(.lowPass, frequency: lowCrossover, sampleRate: sampleRate)
        lowLP2 = lowLP1
        lowAP = Biquad(.allPass, frequency: highCrossover, sampleRate: sampleRate)
        restHP1 = Biquad(.highPass, frequency: lowCrossover, sampleRate: sampleRate)
        restHP2 = restHP1
        midLP1 = Biquad(.lowPass, frequency: highCrossover, sampleRate: sampleRate)
        midLP2 = midLP1
        highHP1 = Biquad(.highPass, frequency: highCrossover, sampleRate: sampleRate)
        highHP2 = highHP1
    }

    /// Linear band gain *targets* (low, mid, high), kills as 0.
    public var linearGains: (Float, Float, Float) {
        (lowGain.target, midGain.target, highGain.target)
    }

    /// dB → linear; ≤ −60 dB (including −∞) is 0, above +6 dB clamps to +6 dB.
    static func linear(_ db: Float) -> Float {
        if !(db > killThresholdDB) { return 0 }   // also maps NaN to a kill
        return powf(10, min(db, maxDB) / 20)
    }

    @inline(__always)
    public mutating func process(l: inout Float, r: inout Float) {
        let x = (Double(l), Double(r))
        var low = lowLP1.process(l: x.0, r: x.1)
        low = lowLP2.process(l: low.0, r: low.1)
        low = lowAP.process(l: low.0, r: low.1)
        var rest = restHP1.process(l: x.0, r: x.1)
        rest = restHP2.process(l: rest.0, r: rest.1)
        var mid = midLP1.process(l: rest.0, r: rest.1)
        mid = midLP2.process(l: mid.0, r: mid.1)
        var high = highHP1.process(l: rest.0, r: rest.1)
        high = highHP2.process(l: high.0, r: high.1)
        let gl = Double(lowGain.next()), gm = Double(midGain.next()), gh = Double(highGain.next())
        l = Float(gl * low.0 + gm * mid.0 + gh * high.0)
        r = Float(gl * low.1 + gm * mid.1 + gh * high.1)
    }
}
