import Testing
import Foundation
@testable import HyperCore

private func ramp(_ n: Int) -> AudioTrack {
    let samples = (0..<n).map { Float($0) }
    return AudioTrack(url: URL(fileURLWithPath: "/tmp/ramp.wav"), sampleRate: 44100,
                      left: samples, right: samples)
}

private func renderBlock(_ p: inout DeckPlayer, frames: Int, blockStart: Int64 = 0) -> ([Float], [Float]) {
    var l = [Float](repeating: -1, count: frames)
    var r = [Float](repeating: -1, count: frames)
    l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            p.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames, blockStart: blockStart)
        }
    }
    return (l, r)
}

@Suite struct DeckPlayerTests {
    @Test func playsSamplesExactly() {
        let t = ramp(1000)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.seek(toFrame: 100)
        p.play(at: nil)
        let (l, r) = renderBlock(&p, frames: 64)
        #expect(l == (100..<164).map { Float($0) })
        #expect(r == l)
        #expect(p.position == 164)
        withExtendedLifetime(t) {}
    }

    @Test func scheduledStartIsSampleAccurate() {
        let t = ramp(1000)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.seek(toFrame: 100)
        p.play(at: 1000)
        let (l, _) = renderBlock(&p, frames: 64, blockStart: 960)
        #expect(l[0..<40].allSatisfy { $0 == 0 })
        #expect(l[40] == 100)
        #expect(l[63] == 123)
        #expect(p.scheduledStart == nil)
        withExtendedLifetime(t) {}
    }

    @Test func scheduledStartInLaterBlockKeepsSilence() {
        let t = ramp(1000)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.play(at: 1000)
        let (l, _) = renderBlock(&p, frames: 64, blockStart: 0)
        #expect(l.allSatisfy { $0 == 0 })
        #expect(p.position == 0)
        #expect(p.scheduledStart == 1000)
        withExtendedLifetime(t) {}
    }

    @Test func pauseOutputsSilenceAndHoldsPosition() {
        let t = ramp(1000)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.play(at: nil)
        _ = renderBlock(&p, frames: 32)
        p.pause()
        let (l, r) = renderBlock(&p, frames: 32)
        #expect(l.allSatisfy { $0 == 0 } && r.allSatisfy { $0 == 0 })
        #expect(p.position == 32)
        #expect(!p.isPlaying)
        withExtendedLifetime(t) {}
    }

    @Test func loopWrapsSeamlessly() {
        let t = ramp(1000)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.loop = 100..<164
        p.seek(toFrame: 150)
        p.play(at: nil)
        let (l, _) = renderBlock(&p, frames: 32)
        let expected = (150..<164).map { Float($0) } + (100..<118).map { Float($0) }
        #expect(l == expected)
        withExtendedLifetime(t) {}
    }

    @Test func bendAdvancesProportionally() {
        let t = ramp(5000)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.bend = 1.02
        p.play(at: nil)
        for _ in 0..<10 { _ = renderBlock(&p, frames: 100) }
        #expect(abs(p.position - 1020) <= 0.5)
        // Interpolating a linear ramp reproduces it.
        var q = DeckPlayer()
        q.track = Unmanaged.passUnretained(t)
        q.bend = 1.02
        q.play(at: nil)
        let (l, _) = renderBlock(&q, frames: 50)
        for k in 0..<50 { #expect(abs(l[k] - Float(Double(k) * 1.02)) < 1e-2) }
        withExtendedLifetime(t) {}
    }

    @Test func bendIsClamped() {
        var p = DeckPlayer()
        p.bend = 2
        #expect(p.bend == 1.1)
        p.bend = 0.1
        #expect(p.bend == 0.9)
    }

    @Test func stopsAtEndOfTrack() {
        let t = ramp(100)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.seek(toFrame: 90)
        p.play(at: nil)
        let (l, r) = renderBlock(&p, frames: 32)
        #expect(Array(l[0..<10]) == (90..<100).map { Float($0) })
        #expect(l[10...].allSatisfy { $0 == 0 } && r[10...].allSatisfy { $0 == 0 })
        #expect(!p.isPlaying)
        withExtendedLifetime(t) {}
    }

    @Test func seekAndNudgeClamp() {
        let t = ramp(100)
        var p = DeckPlayer()
        p.track = Unmanaged.passUnretained(t)
        p.seek(toFrame: 500)
        #expect(p.position == 100)
        p.nudge(frames: -500)
        #expect(p.position == 0)
        p.nudge(frames: 30)
        #expect(p.position == 30)
        withExtendedLifetime(t) {}
    }

    @Test func noTrackRendersSilence() {
        var p = DeckPlayer()
        p.play(at: nil)
        let (l, r) = renderBlock(&p, frames: 16)
        #expect(l.allSatisfy { $0 == 0 } && r.allSatisfy { $0 == 0 })
    }
}
