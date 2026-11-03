import Testing
import Foundation
@testable import HyperCore

private let sr = 44100.0

private func sine(_ freq: Double, seconds: Double = 1.0, sr: Double = sr) -> [Float] {
    let n = Int(seconds * sr)
    return (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sr)) }
}

/// RMS level in dB over the second half of the buffer (filter settling ignored).
private func rmsDB(_ x: [Float]) -> Double {
    let half = x[(x.count / 2)...]
    let ms = half.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(half.count)
    return 10 * log10(max(ms, 1e-30))
}

/// Runs `input` (same signal on both channels) through `strip` in 512-frame blocks.
/// Returns the left output; asserts the right output is identical.
private func run(_ strip: inout ChannelStrip, _ input: [Float],
                 before: ((inout ChannelStrip, Int) -> Void)? = nil) -> [Float] {
    var l = input
    var r = input
    let block = 512
    l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            var start = 0
            while start < input.count {
                before?(&strip, start)
                let n = min(block, input.count - start)
                strip.process(left: lp.baseAddress! + start, right: rp.baseAddress! + start, frames: n)
                start += n
            }
        }
    }
    #expect(l == r)
    return l
}

private func processed(_ input: [Float], configure: (inout ChannelStrip) -> Void = { _ in }) -> [Float] {
    var strip = ChannelStrip(sampleRate: sr)
    configure(&strip)
    // Let the gain targets settle before audio so only the steady state is measured.
    _ = run(&strip, [Float](repeating: 0, count: 4096))
    return run(&strip, input)
}

private func attenuationDB(_ freq: Double, configure: (inout ChannelStrip) -> Void) -> Double {
    let x = sine(freq)
    return rmsDB(x) - rmsDB(processed(x, configure: configure))
}

/// Largest allowed per-sample change for a full-scale 10 ms linear ramp at 44.1 kHz.
private let stepBound = 1.0 / (0.01 * 44100) + 1e-6

@Suite struct ChannelStripTests {
    @Test(arguments: [40.0, 200, 1000, 2500, 8000, 15000])
    func flatAtZeroDB(freq: Double) {
        let x = sine(freq)
        #expect(abs(rmsDB(processed(x)) - rmsDB(x)) < 0.1)
    }

    @Test func lowKillRemoves50Hz() {
        #expect(attenuationDB(50) { $0.eq.lowDB = -.infinity } > 40)
    }

    /// Controller ruling: an LR4 high-pass at 2500 Hz only attenuates 1 kHz by about 32 dB,
    /// so the mid kill is checked for > 30 dB at 1 kHz and > 35 dB at the band's
    /// geometric centre √(200·2500) ≈ 707 Hz.
    @Test func midKillRemoves1kHz() {
        #expect(attenuationDB(1000) { $0.eq.midDB = -.infinity } > 30)
        #expect(attenuationDB((200.0 * 2500).squareRoot()) { $0.eq.midDB = -.infinity } > 35)
    }

    @Test func highKillRemoves10kHz() {
        #expect(attenuationDB(10000) { $0.eq.highDB = -.infinity } > 40)
    }

    @Test func killDoesNotAffectOtherBands() {
        #expect(abs(attenuationDB(8000) { $0.eq.lowDB = -.infinity }) < 0.5)
    }

    @Test func killThresholdIsMinus60dB() {
        #expect(attenuationDB(10000) { $0.eq.highDB = -60 } > 40)
        let g = { (db: Float) -> Float in
            var s = ChannelStrip(sampleRate: sr); s.eq.highDB = db; return s.controlGains().eqLinear.2
        }
        #expect(g(-60) == 0)
        #expect(abs(g(-59) - powf(10, -59 / 20)) < 1e-7)
        #expect(abs(g(6) - powf(10, 6 / 20)) < 1e-6)
    }

    @Test func faderStepIsSmoothed() {
        var strip = ChannelStrip(sampleRate: sr)
        // Settle the EQ filters on DC first: the onset of DC is itself a step the
        // crossover filters ring on, which is not what this test is about.
        _ = run(&strip, [Float](repeating: 1, count: Int(sr)))
        let x = [Float](repeating: 1, count: Int(0.05 * sr))
        let out = run(&strip, x) { s, start in if start == 0 { s.fader = 0 } }
        var maxDelta: Float = abs(out[0] - 1)
        for i in 1..<out.count { maxDelta = max(maxDelta, abs(out[i] - out[i - 1])) }
        #expect(Double(maxDelta) <= stepBound)
        let after = Int(0.015 * sr)
        #expect(out[after...].allSatisfy { abs($0) < 1e-6 })
    }

    /// Band gains are applied after the crossover filters, so the output is linear in the
    /// high-band gain g: out = killed + g·(open − killed), where `open`/`killed` are the
    /// same 5 kHz sine run with the high band constantly at 0 dB / killed. That recovers the
    /// envelope gain g[n] the switch applies, which must ramp with no step.
    @Test func eqGainChangeHasNoStep() {
        let x = sine(5000, seconds: 1.0)
        let changeAt = 22016 // a block boundary after the filters have settled
        var s1 = ChannelStrip(sampleRate: sr), s2 = ChannelStrip(sampleRate: sr), s3 = ChannelStrip(sampleRate: sr)
        let open = run(&s1, x)
        let killed = run(&s2, x) { s, start in if start == 0 { s.eq.highDB = -.infinity } }
        let switched = run(&s3, x) { s, start in if start == changeAt { s.eq.highDB = -.infinity } }
        var prev: (n: Int, g: Double)? = nil
        var worstExcess = -Double.infinity
        var gains: [Double] = []
        for n in (changeAt - 1000)..<(changeAt + 1000) {
            let d = Double(open[n]) - Double(killed[n])
            guard abs(d) > 0.2 else { continue }   // skip near zero crossings of the band
            let g = (Double(switched[n]) - Double(killed[n])) / d
            gains.append(g)
            if let p = prev { worstExcess = max(worstExcess, abs(g - p.g) - stepBound * Double(n - p.n)) }
            prev = (n, g)
        }
        #expect(worstExcess <= 1e-5)
        #expect(abs(gains.first! - 1) < 1e-4)
        #expect(abs(gains.last!) < 1e-4)
    }

    /// Stopped decks feed exact zeros; filter state must decay to exactly 0 instead of
    /// ringing on forever in subnormals (very slow on Intel).
    @Test func biquadStateFlushesToZeroOnSilence() {
        let kinds: [(Biquad.Kind, Double)] = [(.lowPass, 200), (.highPass, 200), (.allPass, 2500),
                                               (.lowPass, 2500), (.highPass, 2500)]
        for (kind, freq) in kinds {
            var b = Biquad(kind, frequency: freq, sampleRate: sr)
            for v in sine(1000, seconds: 0.5) { _ = b.process(l: Double(v), r: -Double(v)) }
            for _ in 0..<Int(3 * sr) { _ = b.process(l: 0, r: 0) }
            #expect(b.state.l == (0, 0) && b.state.r == (0, 0), "\(kind) @\(freq) Hz")
        }
    }

    @Test func stripOutputIsExactlyZeroOnSilence() {
        var strip = ChannelStrip(sampleRate: sr)
        _ = run(&strip, sine(1000, seconds: 0.5))
        let out = run(&strip, [Float](repeating: 0, count: Int(4 * sr)))
        #expect(out[Int(3 * sr)...].allSatisfy { $0 == 0 })
    }

    @Test func nonFiniteTrimAndFaderAreSafe() {
        var strip = ChannelStrip(sampleRate: sr)
        strip.trimDB = .nan
        strip.fader = .nan
        let g = strip.controlGains()
        #expect(g.trim == 1)
        #expect(g.fader == 0)
        strip.trimDB = .infinity
        #expect(strip.controlGains().trim == 1)
    }

    @Test func smoothedValueReachesTargetWithinRamp() {
        var v = SmoothedValue(0, rampSeconds: 0.01, sampleRate: sr)
        v.target = 1
        var last: Float = 0
        for _ in 0..<441 { last = v.next() }
        #expect(last == 1)
        #expect(v.next() == 1)
        // Retargeting mid-ramp starts a fresh ramp from the current value.
        v.target = 0
        for _ in 0..<100 { _ = v.next() }
        v.target = 1
        for _ in 0..<441 { last = v.next() }
        #expect(last == 1)
    }

    @Test func controlGainsReportTargets() {
        var strip = ChannelStrip(sampleRate: sr)
        strip.trimDB = 6
        strip.fader = 0.5
        strip.eq.lowDB = -.infinity
        strip.eq.midDB = 0
        strip.eq.highDB = -6
        let g = strip.controlGains()
        #expect(abs(g.trim - powf(10, 6 / 20)) < 1e-6)
        #expect(abs(g.fader - 0.25) < 1e-7)
        #expect(g.eqLinear.0 == 0)
        #expect(g.eqLinear.1 == 1)
        #expect(abs(g.eqLinear.2 - powf(10, -6 / 20)) < 1e-6)
    }
}
