import Foundation

public enum CrossfaderCurve: UInt8, Sendable {
    /// Constant power: gA = cos(x·π/2), gB = sin(x·π/2) (−3 dB each at the centre).
    case smooth
    /// Cut curve: both sides at unity across 0.05 … 0.95; each edge is a linear ramp
    /// spanning 1/20 of the travel (gA falls 1 → 0 over 0.95 … 1, gB rises 0 → 1 over 0 … 0.05).
    case sharp
}

/// The mixer's four output channels, in order master L, master R, cue L, cue R.
public struct FourChannelOut {
    public var masterL, masterR, cueL, cueR: UnsafeMutablePointer<Float>

    public init(masterL: UnsafeMutablePointer<Float>, masterR: UnsafeMutablePointer<Float>,
                cueL: UnsafeMutablePointer<Float>, cueR: UnsafeMutablePointer<Float>) {
        self.masterL = masterL
        self.masterR = masterR
        self.cueL = cueL
        self.cueR = cueR
    }
}

/// Two channel strips → crossfader → master, plus a PFL cue bus with a cue/master blend.
///
///     deck A ─ trim/EQ ─┬─ fader ─ × gA(xf) ─┐
///                       └─ × PFL A ──────────┼──────────────┐
///     deck B ─ trim/EQ ─┬─ fader ─ × gB(xf) ─┤              │
///                       └─ × PFL B ──────────┼─ cue sum ─┐  │
///                                            └─ master ──┼──┴─ lerp(cue, master, cueMix)
///                                                        │                  │
///                                 × masterGain ─ limiter ┘     × cueGain ─ limiter
///
/// PFL taps the post-EQ, pre-fader signal. The cue/master blend uses the master sum
/// *before* `masterDB`, so the headphone mix does not follow the master level.
///
/// Smoothing (10 ms linear ramps, per sample, no zipper): crossfader position, the
/// smooth↔sharp curve blend (switching curves crossfades the two gain laws instead of
/// stepping), PFL on/off gains, `cueMix`, and the master/cue linear gains. Crossfader
/// gains are recomputed every sample from the smoothed position.
///
/// Render-thread safe: value type, no allocation, no locks.
public struct Mixer {
    public var strips: (ChannelStrip, ChannelStrip)

    /// 0 = full A, 1 = full B (clamped; NaN is treated as the centre).
    public var crossfader: Float = 0.5 {
        didSet { xfade.target = crossfader.isNaN ? 0.5 : min(max(crossfader, 0), 1) }
    }

    public var curve: CrossfaderCurve = .smooth {
        didSet { curveBlend.target = curve == .sharp ? 1 : 0 }
    }

    /// Master level in dB: −∞ is silence, clamped to at most +12 dB, NaN is 0 dB.
    public var masterDB: Float = 0 { didSet { masterGain.target = Self.gain(masterDB) } }

    /// Pre-fader listen per deck (A, B).
    public var pfl: (Bool, Bool) = (false, false) {
        didSet {
            pflGain.0.target = pfl.0 ? 1 : 0
            pflGain.1.target = pfl.1 ? 1 : 0
        }
    }

    /// Cue bus blend, linear: 0 = PFL sum only, 1 = master only (clamped; NaN is 0).
    public var cueMix: Float = 0 {
        didSet { cueMixGain.target = cueMix.isNaN ? 0 : min(max(cueMix, 0), 1) }
    }

    /// Cue level in dB, same rules as `masterDB`.
    public var cueDB: Float = 0 { didSet { cueGain.target = Self.gain(cueDB) } }

    private let limiter = SoftLimiter()
    private var xfade: SmoothedValue
    private var curveBlend: SmoothedValue
    private var masterGain: SmoothedValue
    private var cueGain: SmoothedValue
    private var cueMixGain: SmoothedValue
    private var pflGain: (SmoothedValue, SmoothedValue)

    public init(sampleRate: Double) {
        strips = (ChannelStrip(sampleRate: sampleRate), ChannelStrip(sampleRate: sampleRate))
        xfade = SmoothedValue(0.5, sampleRate: sampleRate)
        curveBlend = SmoothedValue(0, sampleRate: sampleRate)
        masterGain = SmoothedValue(1, sampleRate: sampleRate)
        cueGain = SmoothedValue(1, sampleRate: sampleRate)
        cueMixGain = SmoothedValue(0, sampleRate: sampleRate)
        pflGain = (SmoothedValue(0, sampleRate: sampleRate), SmoothedValue(0, sampleRate: sampleRate))
    }

    /// Crossfader gains for position `x` (clamped to 0 … 1). The ends are exact:
    /// x = 0 gives (1, 0) and x = 1 gives (0, 1) for both curves.
    public static func crossfaderGains(_ x: Float, curve: CrossfaderCurve) -> (a: Float, b: Float) {
        let x = x.isNaN ? 0.5 : min(max(x, 0), 1)
        switch curve {
        case .smooth:
            if x == 0 { return (1, 0) }
            if x == 1 { return (0, 1) }
            let t = x * (Float.pi / 2)
            return (cosf(t), sinf(t))
        case .sharp:
            let edge: Float = 0.05
            return (x <= 1 - edge ? 1 : (1 - x) / edge,
                    x >= edge ? 1 : x / edge)
        }
    }

    /// Mixes `frames` frames of both decks into `out`.
    ///
    /// **In-place contract:** the deck buffers are overwritten with their strip's
    /// post-trim/EQ, pre-fader signal (the caller — AudioCore — owns them as scratch).
    /// Each output frame is computed from the same frame of the deck buffers, so the four
    /// output buffers must be distinct from each other; they may not alias a deck buffer
    /// unless the caller no longer needs that deck's samples.
    public mutating func mix(deckA: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>),
                             deckB: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>),
                             out: FourChannelOut,
                             frames: Int) {
        strips.0.processPreFader(left: deckA.0, right: deckA.1, frames: frames)
        strips.1.processPreFader(left: deckB.0, right: deckB.1, frames: frames)
        for i in 0..<frames {
            let aL = deckA.0[i], aR = deckA.1[i]
            let bL = deckB.0[i], bR = deckB.1[i]

            let pa = pflGain.0.next(), pb = pflGain.1.next()
            let cueL = pa * aL + pb * bL
            let cueR = pa * aR + pb * bR

            let x = xfade.next()
            let c = curveBlend.next()
            let s = Self.crossfaderGains(x, curve: .smooth)
            let h = Self.crossfaderGains(x, curve: .sharp)
            let ga = (s.a + (h.a - s.a) * c) * strips.0.nextFaderGain()
            let gb = (s.b + (h.b - s.b) * c) * strips.1.nextFaderGain()
            let mL = aL * ga + bL * gb
            let mR = aR * ga + bR * gb

            let cm = cueMixGain.next()
            let mg = masterGain.next(), cg = cueGain.next()
            out.masterL[i] = limiter.process(mL * mg)
            out.masterR[i] = limiter.process(mR * mg)
            out.cueL[i] = limiter.process((cueL + (mL - cueL) * cm) * cg)
            out.cueR[i] = limiter.process((cueR + (mR - cueR) * cm) * cg)
        }
    }

    /// dB → linear: NaN is unity, −∞ is 0, clamped to at most +12 dB.
    private static func gain(_ db: Float) -> Float {
        db.isNaN ? 1 : powf(10, min(db, 12) / 20)
    }
}
