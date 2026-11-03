import Testing
import Foundation
@testable import HyperCore

private let sr = 44100.0

private func sine(_ freq: Double, amplitude: Float = 0.25, count: Int) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * Double.pi * freq * Double($0) / sr)) }
}

private struct MixOutput {
    var masterL: [Float], masterR: [Float], cueL: [Float], cueR: [Float]
}

/// Runs `a` and `b` (same signal on both channels of each deck) through `mixer` in 512-frame
/// blocks. The deck buffers are copied first because `mix` processes them in place.
private func run(_ mixer: inout Mixer, a: [Float], b: [Float]) -> MixOutput {
    precondition(a.count == b.count)
    let n = a.count
    var aL = a, aR = a, bL = b, bR = b
    var out = MixOutput(masterL: .init(repeating: .nan, count: n), masterR: .init(repeating: .nan, count: n),
                        cueL: .init(repeating: .nan, count: n), cueR: .init(repeating: .nan, count: n))
    aL.withUnsafeMutableBufferPointer { aLp in aR.withUnsafeMutableBufferPointer { aRp in
    bL.withUnsafeMutableBufferPointer { bLp in bR.withUnsafeMutableBufferPointer { bRp in
    out.masterL.withUnsafeMutableBufferPointer { mL in out.masterR.withUnsafeMutableBufferPointer { mR in
    out.cueL.withUnsafeMutableBufferPointer { cL in out.cueR.withUnsafeMutableBufferPointer { cR in
        var start = 0
        while start < n {
            let frames = min(512, n - start)
            mixer.mix(deckA: (aLp.baseAddress! + start, aRp.baseAddress! + start),
                      deckB: (bLp.baseAddress! + start, bRp.baseAddress! + start),
                      out: FourChannelOut(masterL: mL.baseAddress! + start, masterR: mR.baseAddress! + start,
                                          cueL: cL.baseAddress! + start, cueR: cR.baseAddress! + start),
                      frames: frames)
            start += frames
        }
    }}}}}}}}
    return out
}

/// A mixer configured by `configure`, with its smoothed controls settled on silence.
private func settled(_ configure: (inout Mixer) -> Void) -> Mixer {
    var m = Mixer(sampleRate: sr)
    configure(&m)
    let z = [Float](repeating: 0, count: 4096)
    _ = run(&m, a: z, b: z)
    return m
}

private func maxAbsDiff(_ x: [Float], _ y: [Float]) -> Float {
    zip(x, y).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

private func rms(_ x: [Float]) -> Float {
    (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private let n = 8192

@Suite struct MixerTests {
    @Test func smoothCurveCentreIsMinus3dB() {
        let g = Mixer.crossfaderGains(0.5, curve: .smooth)
        #expect(abs(g.a - 0.7071) < 1e-3)
        #expect(abs(g.b - 0.7071) < 1e-3)
    }

    @Test func sharpCurveCentreIsUnity() {
        let g = Mixer.crossfaderGains(0.5, curve: .sharp)
        #expect(g.a == 1 && g.b == 1)
        // Unity across 0.05 … 0.95, linear edges spanning 1/20 of travel.
        #expect(Mixer.crossfaderGains(0.05, curve: .sharp) == (1, 1))
        #expect(Mixer.crossfaderGains(0.95, curve: .sharp) == (1, 1))
        let edgeA = Mixer.crossfaderGains(0.975, curve: .sharp)
        let edgeB = Mixer.crossfaderGains(0.025, curve: .sharp)
        #expect(abs(edgeA.a - 0.5) < 1e-5 && edgeA.b == 1)
        #expect(abs(edgeB.b - 0.5) < 1e-5 && edgeB.a == 1)
    }

    @Test(arguments: [CrossfaderCurve.smooth, .sharp])
    func crossfaderEndsSilenceOtherSide(curve: CrossfaderCurve) {
        #expect(Mixer.crossfaderGains(0, curve: curve) == (1, 0))
        #expect(Mixer.crossfaderGains(1, curve: curve) == (0, 1))
        // And through the full signal path: crossfader hard to A leaves no B on master.
        var m = settled { $0.crossfader = 0; $0.curve = curve }
        let a = sine(440, count: n)
        let out = run(&m, a: [Float](repeating: 0, count: n), b: a)
        #expect(out.masterL.allSatisfy { $0 == 0 })
        #expect(out.masterR.allSatisfy { $0 == 0 })
    }

    @Test func pflRoutesOnlyToCue() {
        let a = sine(440, count: n)
        let b = sine(1000, count: n)
        let zero = [Float](repeating: 0, count: n)
        let configure: (inout Mixer) -> Void = { $0.crossfader = 1; $0.pfl = (true, false); $0.cueMix = 0 }

        var both = settled(configure)
        let out = run(&both, a: a, b: b)
        var onlyB = settled(configure)
        let refB = run(&onlyB, a: zero, b: b)
        var onlyA = settled(configure)
        let refA = run(&onlyA, a: a, b: zero)

        // Master is exactly the B-only mix: A contributes nothing.
        #expect(maxAbsDiff(out.masterL, refB.masterL) < 1e-6)
        #expect(maxAbsDiff(out.masterR, refB.masterR) < 1e-6)
        #expect(rms(out.masterL) > 0.1)
        // Cue is exactly the A-only cue: B (not PFL'd) contributes nothing, A is audible.
        #expect(maxAbsDiff(out.cueL, refA.cueL) < 1e-6)
        #expect(maxAbsDiff(out.cueR, refA.cueR) < 1e-6)
        #expect(rms(out.cueL) > 0.1)
        #expect(refB.cueL.allSatisfy { $0 == 0 })
    }

    @Test func pflIsPreFader() {
        let a = sine(440, count: n)
        let zero = [Float](repeating: 0, count: n)
        var m = settled { $0.strips.0.fader = 0; $0.pfl = (true, false); $0.cueMix = 0 }
        let out = run(&m, a: a, b: zero)
        #expect(out.masterL.allSatisfy { $0 == 0 })
        #expect(abs(rms(out.cueL) - rms(a)) < 0.01 * rms(a))
    }

    @Test func cueMixBlendsMaster() {
        let a = sine(440, count: n)
        let b = sine(1000, count: n)
        // cueMix 1: cue is the master signal.
        var full = settled { $0.cueMix = 1 }
        let o1 = run(&full, a: a, b: b)
        #expect(maxAbsDiff(o1.cueL, o1.masterL) < 1e-6)
        #expect(maxAbsDiff(o1.cueR, o1.masterR) < 1e-6)
        // cueMix 0 with no PFL: silence.
        var none = settled { $0.cueMix = 0 }
        let o0 = run(&none, a: a, b: b)
        #expect(o0.cueL.allSatisfy { $0 == 0 })
        // cueMix 0.5 with no PFL: half the master.
        var half = settled { $0.cueMix = 0.5 }
        let oh = run(&half, a: a, b: b)
        #expect(maxAbsDiff(oh.cueL, oh.masterL.map { $0 * 0.5 }) < 1e-6)
        // cueMix 0.5 with PFL on A, crossfader to B: half A (pre-fader) + half master (B).
        var mixed = settled { $0.cueMix = 0.5; $0.pfl = (true, false); $0.crossfader = 1 }
        let om = run(&mixed, a: a, b: b)
        var cueOnly = settled { $0.cueMix = 0; $0.pfl = (true, false); $0.crossfader = 1 }
        let oc = run(&cueOnly, a: a, b: b)
        let expected = zip(oc.cueL, om.masterL).map { 0.5 * $0 + 0.5 * $1 }
        #expect(maxAbsDiff(om.cueL, expected) < 1e-6)
    }

    @Test func masterAndCueLevels() {
        let a = sine(440, count: n)
        let zero = [Float](repeating: 0, count: n)
        var ref = settled { $0.cueMix = 1 }
        let r = run(&ref, a: a, b: zero)
        var m = settled { $0.cueMix = 1; $0.masterDB = -6; $0.cueDB = -12 }
        let o = run(&m, a: a, b: zero)
        #expect(maxAbsDiff(o.masterL, r.masterL.map { $0 * powf(10, -6 / 20) }) < 1e-6)
        #expect(maxAbsDiff(o.cueL, r.cueL.map { $0 * powf(10, -12 / 20) }) < 1e-6)
    }

    /// DC on A after the EQ has settled; a crossfader or curve change must ramp, not step.
    @Test(arguments: [false, true])
    func crossfaderAndCurveChangesAreSmoothed(changeCurve: Bool) {
        var m = settled { _ in }
        let dc = [Float](repeating: 0.5, count: Int(sr)), zero = [Float](repeating: 0, count: Int(sr))
        _ = run(&m, a: dc, b: zero)
        if changeCurve { m.curve = .sharp } else { m.crossfader = 1 }
        let o = run(&m, a: [Float](dc[..<4096]), b: [Float](zero[..<4096]))
        var maxDelta: Float = 0
        for i in 1..<o.masterL.count { maxDelta = max(maxDelta, abs(o.masterL[i] - o.masterL[i - 1])) }
        #expect(maxDelta < 0.01)
        #expect(abs(o.masterL.last! - (changeCurve ? 0.5 : 0)) < 1e-5)
    }

    @Test func limiterCeiling() {
        let lim = SoftLimiter()
        var x = sine(440, amplitude: 4.0, count: n)
        x.withUnsafeMutableBufferPointer { lim.process($0.baseAddress!, frames: n) }
        #expect(x.allSatisfy { abs($0) <= 0.999 })
        #expect(x.map(abs).max()! > 0.99)
        #expect(lim.process(.infinity) <= 0.999 && lim.process(-.infinity) >= -0.999)
        #expect(lim.process(.nan) == 0)
        // Applied on the mixer outputs.
        var m = settled { $0.masterDB = 12; $0.cueDB = 12; $0.cueMix = 1 }
        let o = run(&m, a: sine(440, amplitude: 1, count: n), b: sine(1000, amplitude: 1, count: n))
        for ch in [o.masterL, o.masterR, o.cueL, o.cueR] { #expect(ch.allSatisfy { abs($0) <= 0.999 }) }
    }

    @Test func limiterTransparentForSmallSignals() {
        let lim = SoftLimiter()
        for x in sine(440, amplitude: 0.1, count: 1000) {
            #expect(abs(lim.process(x) - x) <= 0.001 * 0.1)
        }
        // Exactly transparent up to −1 dBFS.
        let t = powf(10, -1 / 20)
        #expect(lim.process(t * 0.999) == t * 0.999)
    }
}
